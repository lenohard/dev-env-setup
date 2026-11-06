-- pi-chat.nvim :: RPC transport
--
-- Spawns `pi --mode rpc` and speaks the JSONL protocol over stdin/stdout.
-- Responsibilities (kept deliberately dumb — no UI, no session semantics):
--   * strict LF-delimited JSONL framing (never split on U+2028/U+2029)
--   * write commands, correlate `response` records by id
--   * dispatch every decoded record to a single `on_record` sink
--
-- The caller (session.lua) owns all interpretation of events.

local M = {}

local Rpc = {}
Rpc.__index = Rpc

local uv = vim.uv or vim.loop

--- Create and start an RPC connection.
--- @param opts table { cmd: string[], cwd?: string, on_record: fun(rec: table), on_exit?: fun(code, signal), on_stderr?: fun(line) }
--- @return table|nil rpc, string|nil err
function M.start(opts)
  assert(type(opts.on_record) == "function", "on_record is required")

  local self = setmetatable({
    on_record = opts.on_record,
    on_exit = opts.on_exit,
    on_stderr = opts.on_stderr,
    _stdout_buf = "",
    _stderr_buf = "",
    _next_id = 0,
    _pending = {}, -- id -> callback(response_record)
    _closed = false,
  }, Rpc)

  local cmd = opts.cmd
  local ok, proc = pcall(vim.system, cmd, {
    cwd = opts.cwd,
    text = true,
    stdin = true,
    stdout = vim.schedule_wrap(function(err, data)
      if err or self._closed then
        return
      end
      self:_feed_stdout(data)
    end),
    stderr = vim.schedule_wrap(function(err, data)
      if err or self._closed then
        return
      end
      self:_feed_stderr(data)
    end),
  }, vim.schedule_wrap(function(result)
    self._closed = true
    -- Flush any trailing record without a newline.
    if self._stdout_buf ~= "" then
      self:_consume_line(self._stdout_buf)
      self._stdout_buf = ""
    end
    if self.on_exit then
      self.on_exit(result.code, result.signal)
    end
  end))

  if not ok then
    return nil, tostring(proc)
  end

  self._proc = proc
  return self
end

--- Split on LF only. Strip an optional trailing CR. Dispatch each complete line.
function Rpc:_feed_stdout(chunk)
  if not chunk or chunk == "" then
    return
  end
  self._stdout_buf = self._stdout_buf .. chunk
  while true do
    local nl = self._stdout_buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = self._stdout_buf:sub(1, nl - 1)
    self._stdout_buf = self._stdout_buf:sub(nl + 1)
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end
    if line ~= "" then
      self:_consume_line(line)
    end
  end
end

function Rpc:_feed_stderr(chunk)
  if not chunk or chunk == "" then
    return
  end
  self._stderr_buf = self._stderr_buf .. chunk
  while true do
    local nl = self._stderr_buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = self._stderr_buf:sub(1, nl - 1)
    self._stderr_buf = self._stderr_buf:sub(nl + 1)
    if line ~= "" and self.on_stderr then
      self.on_stderr(line)
    end
  end
end

function Rpc:_consume_line(line)
  local ok, rec = pcall(vim.json.decode, line)
  if not ok or type(rec) ~= "table" then
    return
  end
  -- Correlate command responses first; still forward them to the sink.
  if rec.type == "response" and rec.id and self._pending[rec.id] then
    local cb = self._pending[rec.id]
    self._pending[rec.id] = nil
    pcall(cb, rec)
  end
  pcall(self.on_record, rec)
end

--- Write a raw command object (an `id` is assigned automatically unless present).
--- @param cmd table
--- @param cb? fun(response: table)  -- called when the matching `response` arrives
--- @return string id
function Rpc:send(cmd, cb)
  if self._closed or not self._proc then
    if cb then
      pcall(cb, { type = "response", success = false, error = "rpc closed" })
    end
    return ""
  end
  if not cmd.id then
    self._next_id = self._next_id + 1
    cmd.id = "c" .. self._next_id
  end
  if cb then
    self._pending[cmd.id] = cb
  end
  local payload = vim.json.encode(cmd) .. "\n"
  pcall(function()
    self._proc:write(payload)
  end)
  return cmd.id
end

--- Convenience: send a user prompt.
function Rpc:prompt(message, images, cb)
  local cmd = { type = "prompt", message = message }
  if images and #images > 0 then
    cmd.images = images
  end
  return self:send(cmd, cb)
end

--- Convenience: steer a running agent.
function Rpc:steer(message, images, cb)
  local cmd = { type = "steer", message = message }
  if images and #images > 0 then
    cmd.images = images
  end
  return self:send(cmd, cb)
end

--- Convenience: abort current work.
function Rpc:abort(cb)
  return self:send({ type = "abort" }, cb)
end

--- Reply to an extension_ui_request. `payload` holds value/confirmed/cancelled.
function Rpc:ui_response(id, payload)
  local msg = vim.tbl_extend("force", { type = "extension_ui_response", id = id }, payload or {})
  -- ui responses carry the request id, not a fresh command id.
  if self._closed or not self._proc then
    return
  end
  pcall(function()
    self._proc:write(vim.json.encode(msg) .. "\n")
  end)
end

function Rpc:is_closed()
  return self._closed
end

function Rpc:shutdown()
  if self._closed or not self._proc then
    return
  end
  -- Closing stdin lets pi exit cleanly; fall back to SIGTERM.
  local state = self._proc._state
  local stdin = state and state.stdin
  if stdin then
    pcall(function()
      stdin:close()
    end)
  end
  local proc = self._proc
  -- Give it a beat to exit on its own, then force.
  vim.defer_fn(function()
    if proc and not proc:is_closing() then
      pcall(function()
        proc:kill(15)
      end)
    end
  end, 500)
end

return M
