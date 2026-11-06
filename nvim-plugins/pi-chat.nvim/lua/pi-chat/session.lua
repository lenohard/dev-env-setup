-- pi-chat.nvim :: session controller
--
-- Owns one chat: an RPC connection + a UI + the translation from pi session
-- events into conversation-buffer operations.
--
-- Event handling (the five that matter for the agreed scope):
--   message_update(text_delta)  -> stream assistant text
--   message_start/end (user)    -> insert "## You" heading + text
--   message_start (assistant)   -> insert "## pi" heading, begin streaming
--   tool_execution_start        -> insert collapsed "## 🔧 tool" fold header
--   tool_execution_end          -> fill the fold with the full result
--   agent_settled               -> mark ready
--   extension_ui_request        -> delegate to approve.lua
--
-- Tool blocks are wrapped in Vim fold markers ({{{N / }}}) so they collapse by
-- default (foldlevel=0).

local rpc_mod = require("pi-chat.rpc")
local ui_mod = require("pi-chat.ui")
local approve = require("pi-chat.approve")

local M = {}

local Session = {}
Session.__index = Session

--- @param config table
function M.new(config)
  return setmetatable({
    config = config,
    rpc = nil,
    ui = nil,
    _assistant_streaming = false, -- currently appending assistant deltas
    _last_role = nil,
    _tools = {}, -- toolCallId -> { header_line = int }
    _busy = false,
    _model = nil, -- { provider, id, name }
    _session_name = nil,
    _ready = false,
  }, Session)
end

local function tool_summary(name, args)
  args = args or {}
  if name == "bash" and args.command then
    return "bash: " .. args.command
  end
  if name == "read" and (args.path or args.file_path) then
    return "read: " .. (args.path or args.file_path)
  end
  if (name == "edit" or name == "write") and (args.path or args.file_path) then
    return name .. ": " .. (args.path or args.file_path)
  end
  if name == "grep" and args.pattern then
    return "grep: " .. args.pattern
  end
  -- Fallback: show the first short-ish string arg.
  for _, key in ipairs({ "query", "command", "path", "pattern", "message" }) do
    if type(args[key]) == "string" then
      return name .. ": " .. args[key]
    end
  end
  return name
end

-- Role separators use a leading bar glyph + em-dash rule instead of a markdown
-- heading, so render-markdown does not paint the whole line as a big heading.
-- Highlighting (bar color + dim rule) is applied with extmarks in ui:append.
local ROLE_PREFIX = "▌ "
local function role_line(label)
  return ROLE_PREFIX .. label
end

local function result_to_lines(result)
  local out = {}
  local content = result and result.content
  if type(content) == "table" then
    for _, part in ipairs(content) do
      if type(part) == "table" and part.type == "text" and part.text then
        for _, l in ipairs(vim.split(part.text, "\n", { plain = true })) do
          out[#out + 1] = l
        end
      elseif type(part) == "table" and part.type == "image" and part.data then
        -- Save image parts to a temp file; show a path + open hint instead of
        -- rendering inline (no terminal graphics / tmux pitfalls).
        local imgs = require("pi-chat.images")
        local p = imgs.save_result_image(part.data, part.mimeType)
        if p then
          out[#out + 1] = "🖼 image → " .. p .. "  (cursor here + <leader>po to open)"
        else
          out[#out + 1] = "🖼 (image: could not save)"
        end
      end
    end
  end
  if #out == 0 then
    out = { "(no text output)" }
  end
  return out
end

function Session:open()
  self.ui = ui_mod.open({
    width = self.config.width,
    on_submit = function(text)
      self:submit(text)
    end,
    on_abort = function()
      self:abort()
    end,
    on_quit = function()
      self:close()
    end,
    on_pick_model = function()
      require("pi-chat").pick_model()
    end,
    on_pick_session = function()
      require("pi-chat").pick_session()
    end,
    on_paste_image = function()
      self:paste_image()
    end,
    on_open_image = function()
      self:open_image_under_cursor()
    end,
  })
  self:_connect()
  self.ui:append({ "# pi-chat", "", "_starting agent…_", "" })
  -- Query live state as soon as we connect so the intro flips to "ready" and
  -- the model shows up, without waiting for the user to type.
  self:_refresh_state(true)
end

--- Ask pi for current model / session name and reflect it in the UI.
--- @param is_initial boolean  when true, replace the "starting…" intro
function Session:_refresh_state(is_initial)
  if not self.rpc then
    return
  end
  self.rpc:send({ type = "get_state" }, function(resp)
    if not (resp and resp.success and resp.data) then
      return
    end
    local d = resp.data
    if d.model then
      self._model = { provider = d.model.provider, id = d.model.id, name = d.model.name }
    end
    self._session_name = d.sessionName
    self:_update_winbar()
    if is_initial and not self._ready then
      self._ready = true
      if self.ui and self.ui:is_valid() then
        self.ui:clear()
        self._intro_cleared = false
        local name = self._session_name or "new session"
        self.ui:append({
          "# pi-chat",
          "",
          "_ready — " .. name .. "_",
          "",
          "Type below and press `<CR>` to ask. `<Tab>` switches panes,",
          "`za` toggles a tool block, `]]`/`[[` jump between messages.",
          "",
        })
      end
    end
  end)
end

function Session:_update_winbar()
  if not (self.ui and self.ui:is_valid()) then
    return
  end
  local model = self._model and (self._model.name or (self._model.provider .. "/" .. self._model.id))
    or "?"
  local status = self._busy and "running…" or "ready"
  self.ui:set_conv_winbar(status, model, self._session_name)
end

function Session:_connect()
  local cmd = { self.config.pi_bin or "pi", "--mode", "rpc" }
  if self.config.no_session then
    table.insert(cmd, "--no-session")
  end
  if self.config.model then
    vim.list_extend(cmd, { "--model", self.config.model })
  end
  if self.config.provider then
    vim.list_extend(cmd, { "--provider", self.config.provider })
  end
  if self.config.extra_args then
    vim.list_extend(cmd, self.config.extra_args)
  end

  local rpc, err = rpc_mod.start({
    cmd = cmd,
    cwd = self.config.cwd or vim.fn.getcwd(),
    on_record = function(rec)
      self:_on_record(rec)
    end,
    on_stderr = function(line)
      -- pi logs diagnostics to stderr; surface only if it looks like an error.
      if line:lower():find("error") then
        vim.notify("[pi stderr] " .. line, vim.log.levels.WARN)
      end
    end,
    on_exit = function(code, _signal)
      if self.ui then
        self.ui:set_conv_winbar("exited (" .. tostring(code) .. ")", self._model and (self._model.name or self._model.id) or "?")
      end
    end,
  })
  if not rpc then
    vim.notify("pi-chat: failed to start pi: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  self.rpc = rpc
end

function Session:_on_record(rec)
  local t = rec.type
  if t == "extension_ui_request" then
    -- Status/notify records are transient UI chrome (live-status, reminder
    -- counters); surface them via vim.notify only, never in the transcript.
    approve.handle(self.rpc, rec, nil)
    return
  end

  if t == "message_start" then
    local role = rec.message and rec.message.role
    if role == "assistant" then
      self:_begin_assistant()
    end
    -- user message echo handled on message_end to get final content
    return
  end

  if t == "message_update" then
    local ev = rec.assistantMessageEvent
    if ev and ev.type == "text_delta" and ev.delta then
      self:_ensure_assistant()
      self.ui:append_stream(ev.delta)
    end
    -- thinking_delta intentionally ignored (keep the transcript clean)
    return
  end

  if t == "message_end" then
    local msg = rec.message
    local role = msg and msg.role
    -- User prompts are echoed locally in submit(); pi's own user message_end
    -- would duplicate them, so we ignore it here.
    if role == "assistant" then
      self._assistant_streaming = false
    end
    return
  end

  if t == "tool_execution_start" then
    self:_tool_start(rec)
    return
  end

  if t == "tool_execution_end" then
    self:_tool_end(rec)
    return
  end

  if t == "turn_start" then
    self:_set_busy(true)
    return
  end

  if t == "agent_settled" then
    self:_set_busy(false)
    return
  end

  if t == "compaction_start" then
    self.ui:append({ "", "_compacting context…_", "" })
    return
  end

  if t == "session_info_changed" then
    self._session_name = rec.name
    self:_update_winbar()
    return
  end
end

function Session:_set_busy(busy)
  self._busy = busy
  self:_update_winbar()
end

function Session:_begin_assistant()
  if self._last_role ~= "assistant" then
    self.ui:append_role(role_line("pi"))
    self._last_role = "assistant"
  end
  self._assistant_streaming = true
end

function Session:_ensure_assistant()
  if not self._assistant_streaming or self._last_role ~= "assistant" then
    self:_begin_assistant()
  end
end

function Session:_tool_start(rec)
  local summary = tool_summary(rec.toolName, rec.args)
  -- Fold marker in the header line; closing marker written at tool_end. Use a
  -- non-heading bar prefix so render-markdown leaves it alone.
  local header = role_line("🔧 " .. summary)
  self.ui:append({ "", header .. " {{{1", "  _running…_" })
  local line_count = vim.api.nvim_buf_line_count(self.ui.conv_buf)
  self._tools[rec.toolCallId] = {
    body_start = line_count, -- 1-based line of the "_running…_" placeholder
  }
  self._last_role = "tool"
end

function Session:_tool_end(rec)
  local entry = self._tools[rec.toolCallId]
  local lines = result_to_lines(rec.result)
  local status = rec.isError and "✗ error" or "✓ done"
  local dur = rec.durationMs and (" · " .. rec.durationMs .. "ms") or ""

  local body = { "  " .. status .. dur, "```" }
  vim.list_extend(body, lines)
  body[#body + 1] = "```"
  body[#body + 1] = "}}}"

  if entry and entry.body_start then
    -- Replace the "_running…_" placeholder line with the real body.
    local buf = self.ui.conv_buf
    local idx = entry.body_start - 1 -- to 0-based
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, idx, idx + 1, false, body)
    vim.bo[buf].modifiable = false
    self.ui:scroll_to_end()
  else
    self.ui:append(body)
  end
  self._tools[rec.toolCallId] = nil
end

function Session:submit(text)
  if not self.rpc or self.rpc:is_closed() then
    vim.notify("pi-chat: agent not connected", vim.log.levels.WARN)
    return
  end
  -- Detach any pending pasted images and strip the internal _path field before
  -- sending (pi only wants type/data/mimeType).
  local images = nil
  if self._pending_images and #self._pending_images > 0 then
    images = {}
    for _, img in ipairs(self._pending_images) do
      images[#images + 1] = { type = img.type, data = img.data, mimeType = img.mimeType }
    end
    self._pending_images = {}
  end

  -- Echo immediately so the user sees their prompt even before pi mirrors it.
  if not self._intro_cleared then
    self.ui:clear()
    self._intro_cleared = true
  end
  self.ui:append_role(role_line("You"))
  self.ui:append(vim.split(text, "\n", { plain = true }))
  if images then
    self.ui:append({ "_(" .. #images .. " image(s) attached)_" })
  end
  self._last_role = "user"

  if self._busy then
    self.rpc:steer(text, images)
  else
    self.rpc:prompt(text, images, function(resp)
      if resp and resp.success == false then
        vim.notify("pi-chat: prompt rejected: " .. tostring(resp.error), vim.log.levels.ERROR)
      end
    end)
  end
end

--- Grab a clipboard image and queue it for the next submit.
function Session:paste_image()
  local images = require("pi-chat.images")
  local img, err = images.clipboard_image_content()
  if not img then
    vim.notify("pi-chat: " .. (err or "no image"), vim.log.levels.WARN)
    return
  end
  self._pending_images = self._pending_images or {}
  self._pending_images[#self._pending_images + 1] = img
  vim.notify(
    string.format("pi-chat: image attached (%d pending) — send a message to include it", #self._pending_images),
    vim.log.levels.INFO
  )
end

--- Open the image whose path appears on the current conversation line.
function Session:open_image_under_cursor()
  local line = vim.api.nvim_get_current_line()
  -- Lines look like: "🖼 image → /path/to/x.png  (cursor here ...)"
  local path = line:match("→%s+(%S+%.%w+)")
  if not path then
    vim.notify("pi-chat: no image path on this line", vim.log.levels.INFO)
    return
  end
  require("pi-chat.images").open_external(path)
end

function Session:abort()
  if self.rpc and not self.rpc:is_closed() then
    self.rpc:abort()
    self.ui:append({ "", "_aborted._", "" })
    self:_set_busy(false)
  end
end

function Session:close()
  if self.rpc then
    self.rpc:shutdown()
    self.rpc = nil
  end
  if self.ui then
    self.ui:close()
    self.ui = nil
  end
end

--- Switch the running agent to another model. provider+id from a Model object.
function Session:set_model(provider, id)
  if not self.rpc or self.rpc:is_closed() then
    return
  end
  self.rpc:send({ type = "set_model", provider = provider, modelId = id }, function(resp)
    if resp and resp.success and resp.data then
      self._model = { provider = resp.data.provider, id = resp.data.id, name = resp.data.name }
      self:_update_winbar()
      vim.notify("pi-chat: model → " .. (self._model.name or id), vim.log.levels.INFO)
    else
      vim.notify("pi-chat: set_model failed", vim.log.levels.WARN)
    end
  end)
end

function Session:current_model()
  return self._model
end

--- Switch to an existing session file and rebuild the conversation from history.
function Session:switch_session(session_path)
  if not self.rpc or self.rpc:is_closed() then
    return
  end
  self.rpc:send({ type = "switch_session", sessionPath = session_path }, function(resp)
    if not (resp and resp.success) then
      vim.notify("pi-chat: switch_session failed", vim.log.levels.WARN)
      return
    end
    if resp.data and resp.data.cancelled then
      return
    end
    -- The switch settles asynchronously: get_messages right after the response
    -- can still return the OLD (empty) session. Poll until history appears.
    self:_rebuild_from_history()
    self:_refresh_state(false)
  end)
end

--- Fetch full message history and re-render the conversation buffer.
--- Retries with backoff because switch_session settles asynchronously and an
--- immediate get_messages can return an empty/stale list.
--- @param attempt? integer  internal retry counter
function Session:_rebuild_from_history(attempt)
  if not self.rpc or self.rpc:is_closed() then
    return
  end
  attempt = attempt or 1
  local MAX_ATTEMPTS = 8
  self.rpc:send({ type = "get_messages" }, function(resp)
    if not (resp and resp.success and resp.data) then
      return
    end
    local msgs = resp.data.messages or {}
    -- Count renderable (user/assistant) messages; a freshly-switched session
    -- that hasn't settled yet typically returns 0 or only a system message.
    local renderable = 0
    for _, m in ipairs(msgs) do
      if m.role == "user" or m.role == "assistant" then
        renderable = renderable + 1
      end
    end
    if renderable == 0 and attempt < MAX_ATTEMPTS then
      -- Not settled yet (or genuinely empty). Retry with linear backoff.
      vim.defer_fn(function()
        self:_rebuild_from_history(attempt + 1)
      end, 120 * attempt)
      return
    end
    if not (self.ui and self.ui:is_valid()) then
      return
    end
    self.ui:clear()
    self._intro_cleared = true
    self._last_role = nil
    self._assistant_streaming = false
    for _, msg in ipairs(msgs) do
      self:_render_history_message(msg)
    end
    if renderable == 0 then
      self.ui:append({ "_(empty session)_" })
    end
    self.ui:scroll_to_end()
  end)
end

--- Render one persisted message (user/assistant/tool) during history rebuild.
function Session:_render_history_message(msg)
  local role = msg.role
  local function text_of(content)
    if type(content) == "string" then
      return content
    end
    local out = {}
    if type(content) == "table" then
      for _, part in ipairs(content) do
        if type(part) == "table" and part.type == "text" and part.text then
          out[#out + 1] = part.text
        end
      end
    end
    return table.concat(out, "")
  end

  if role == "user" then
    local t = text_of(msg.content)
    if t ~= "" then
      self.ui:append_role(role_line("You"))
      self.ui:append(vim.split(t, "\n", { plain = true }))
    end
  elseif role == "assistant" then
    -- Assistant content may interleave text parts and tool calls.
    local content = msg.content
    if type(content) == "table" then
      local text_parts = {}
      for _, part in ipairs(content) do
        if type(part) == "table" then
          if part.type == "text" and part.text then
            text_parts[#text_parts + 1] = part.text
          elseif part.type == "toolCall" or part.type == "tool_call" then
            local name = part.name or part.toolName or "tool"
            local args = part.args or part.input or {}
            local summary = tool_summary(name, args)
            self.ui:append({ "", role_line("🔧 " .. summary) .. " {{{1", "  _(from history)_", "}}}" })
          end
        end
      end
      local joined = table.concat(text_parts, "")
      if joined ~= "" then
        self.ui:append_role(role_line("pi"))
        self.ui:append(vim.split(joined, "\n", { plain = true }))
      end
    end
  end
end

return M
