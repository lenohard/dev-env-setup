-- pi-chat.nvim :: session controller
--
-- Owns one chat: an RPC connection + a UI + the translation from pi session
-- events into conversation-buffer operations.
--
-- Event handling (the ones that matter for the agreed scope):
--   message_update(text_delta)     -> stream the assistant answer text
--   message_update(thinking_delta) -> DROPPED (reasoning is never shown)
--   message_start/end (user)       -> insert "▌ You" separator + text
--   message_start (assistant)      -> insert "▌ pi" separator, begin streaming
--   tool_execution_*               -> never rendered, only a paragraph boundary
--   agent_settled                  -> mark ready
--   extension_ui_request           -> delegate to approve.lua
--
-- The transcript is user prompts plus assistant answer text and nothing else:
-- no thinking, no tool calls, no placeholder lines, no virtual lines, no folds.
-- Keeping everything else out of the buffer means nothing can disturb the
-- markdown parse (a table, an inline fence or tool output containing `{{{`
-- never reaches the buffer at all), so the answer always renders.

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
    _busy = false,
    _model = nil, -- { provider, id, name }
    _session_name = nil,
    _ready = false,
    _assistant_shown = false, -- whether "▌ pi" header was shown this turn
    _final_pi_line = nil, -- line of the current response's ▌ pi header
    _stats = nil, -- { cost, percent, tokens, context_window }
    _info_open = false, -- whether the floating info popup is open
    _exit_code = nil, -- set when the pi process exits
    _busy_since = nil, -- uv.now() ms when the current run started
    _last_event_at = nil, -- uv.now() ms of the last record from pi (liveness)
    _last_text_at = nil, -- uv.now() ms of the last answer text delta
    _phase = nil, -- "waiting" | "thinking" | "tool" | "answering"
    _tool_name = nil,
    _info_auto = false, -- popup was opened automatically (and may auto-close)
    _info_user_closed = false, -- user closed the popup during this run
    _tick = nil, -- uv timer driving the live status popup
  }, Session)
end

-- Role separators use a leading bar glyph + em-dash rule instead of a markdown
-- heading, so render-markdown does not paint the whole line as a big heading.
-- Highlighting (bar color + dim rule) is applied with extmarks in ui:append.
local ROLE_PREFIX = "▌ "
local function role_line(label)
  return ROLE_PREFIX .. label
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
    on_new_session = function()
      self:new_session()
    end,
    on_toggle_info = function()
      self:toggle_info()
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
    self:_refresh_stats()
    if is_initial and not self._ready then
      self._ready = true
      self:_render_intro()
    end
  end)
end

--- Build the fresh-session intro lines: just the title and the current model.
--- @param model table|nil { provider, id, name }
function M.intro_lines(model)
  local lines = { "# pi-chat", "" }
  local label = model and (model.name or model.provider .. "/" .. model.id)
  if label and label ~= "" then
    lines[#lines + 1] = "model: `" .. label .. "`"
  end
  lines[#lines + 1] = ""
  return lines
end

--- Render the fresh-session intro (used on first ready + after new_session).
function Session:_render_intro()
  if not (self.ui and self.ui:is_valid()) then
    return
  end
  self.ui:clear()
  self._intro_cleared = false
  self.ui:append(M.intro_lines(self._model))
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
      self._exit_code = code
      if self._info_open then
        self:refresh_info()
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
  self._last_event_at = vim.uv.now()
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
    -- Only assistant answer text reaches the buffer. thinking_delta (and every
    -- other delta type) is dropped here, before it can touch the markdown.
    if ev and ev.type == "text_delta" and ev.delta then
      self._phase = "answering"
      self._last_text_at = vim.uv.now()
      self:_auto_close_info() -- the answer itself is the progress indicator now
      self:_ensure_assistant()
      self.ui:append_stream(ev.delta)
    elseif ev and ev.type == "thinking_delta" then
      -- Never rendered; only feeds the live status popup.
      self._phase = "thinking"
    end
    return
  end

  if t == "message_end" then
    local msg = rec.message
    local role = msg and msg.role
    -- User prompts are echoed locally in submit(); pi's own user message_end
    -- would duplicate them, so we ignore it here.
    if role == "assistant" then
      self:_end_segment()
    end
    return
  end

  -- Tool calls are never rendered. A tool run still means the answer is split
  -- into separate paragraphs (text -> tool -> more text), so end the current
  -- text segment and let the next delta open a fresh one.
  if t == "tool_execution_start" or t == "tool_execution_end" then
    if t == "tool_execution_start" then
      self._phase = "tool"
      self._tool_name = rec.toolName
    else
      self._phase = "waiting"
    end
    self:_end_segment()
    return
  end

  if t == "turn_start" then
    self:_set_busy(true)
    return
  end

  if t == "agent_settled" then
    self:_set_busy(false)
    -- Jump the reader to the start of the final pi response (not the bottom),
    -- so a long answer is read from its beginning.
    self:_jump_to_final_output()
    self:_refresh_stats()
    return
  end

  if t == "compaction_start" then
    self.ui:append({ "", "_compacting context…_", "" })
    return
  end

  if t == "session_info_changed" then
    self._session_name = rec.name
    if self._info_open then
      self:refresh_info()
    end
    return
  end
end

function Session:_set_busy(busy)
  local was_busy = self._busy
  self._busy = busy
  if busy and not was_busy then
    self._busy_since = vim.uv.now()
    self._last_event_at = self._busy_since
    self._last_text_at = nil
    self._phase = "waiting"
    self._tool_name = nil
    self:_start_tick()
  elseif not busy then
    self._phase = nil
    self:_stop_tick()
    self:_auto_close_info()
  end
  if self.ui and self.ui.set_busy then
    self.ui:set_busy(busy)
  end
  if self._info_open then
    self:refresh_info()
  end
end

--- While a run is active, re-render the status popup 4x/second (spinner,
--- elapsed time, seconds since the last event from pi). If no answer text has
--- arrived for 1.5s the popup is (re)opened automatically.
function Session:_start_tick()
  if self._tick then
    return
  end
  local timer = vim.uv.new_timer()
  self._tick = timer
  timer:start(
    250,
    250,
    vim.schedule_wrap(function()
      if not (self._busy and self.ui and self.ui:is_valid()) then
        self:_stop_tick()
        return
      end
      local quiet = not self._last_text_at or (vim.uv.now() - self._last_text_at) > 1500
      if quiet and not self._info_open and not self._info_user_closed then
        self:_auto_open_info()
      elseif self._info_open then
        self:refresh_info()
      end
    end)
  )
end

function Session:_stop_tick()
  local timer = self._tick
  self._tick = nil
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end
end

--- Show the status popup on its own (not toggled by the user).
function Session:_auto_open_info()
  if self._info_open or not (self.ui and self.ui:is_valid()) then
    return
  end
  self._info_open = true
  self._info_auto = true
  self.ui:open_info(self:_info_lines())
end

--- Close the status popup only if it was opened automatically.
function Session:_auto_close_info()
  if self._info_open and self._info_auto then
    if self.ui then
      self.ui:close_info()
    end
    self._info_open = false
    self._info_auto = false
  end
end

--- Move the conversation window so the final pi response starts near the top,
--- letting the reader start a long answer from its beginning. Positions the
--- recorded header line at the top of the window (zt) without changing focus.
function Session:_jump_to_final_output()
  local line = self._final_pi_line
  if not line then
    return
  end
  if not (self.ui and self.ui.conv_win and vim.api.nvim_win_is_valid(self.ui.conv_win)) then
    return
  end
  local last = vim.api.nvim_buf_line_count(self.ui.conv_buf)
  line = math.min(line, last)
  vim.api.nvim_win_call(self.ui.conv_win, function()
    pcall(vim.api.nvim_win_set_cursor, self.ui.conv_win, { line, 0 })
    vim.cmd("normal! zt")
  end)
end

--- Pull token/cost stats from pi; cache them and refresh the info popup if open.
function Session:_refresh_stats()
  if not self.rpc or self.rpc:is_closed() then
    return
  end
  self.rpc:send({ type = "get_session_stats" }, function(resp)
    if not (resp and resp.success and resp.data) then
      return
    end
    local d = resp.data
    local cu = d.contextUsage
    local function num(v)
      if v == nil or v == vim.NIL then
        return nil
      end
      return v
    end
    self._stats = {
      cost = num(d.cost),
      percent = cu and num(cu.percent) or nil,
      tokens = cu and num(cu.tokens) or nil,
      context_window = cu and num(cu.contextWindow) or nil,
    }
    if self._info_open then
      self:refresh_info()
    end
  end)
end

--- Build the info-popup lines from the current cached state.
function Session:_info_lines()
  local model = self._model and (self._model.name or (self._model.provider .. "/" .. self._model.id))
    or "?"
  local status
  if self._exit_code ~= nil then
    status = "exited (" .. tostring(self._exit_code) .. ")"
  elseif self._busy then
    local now = vim.uv.now()
    local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
    local spin = frames[math.floor(now / 100) % #frames + 1]
    local secs = math.floor((now - (self._busy_since or now)) / 1000)
    status = string.format("%s running %02d:%02d", spin, math.floor(secs / 60), secs % 60)
  else
    status = "ready"
  end
  local s = self._stats or {}
  local ctx
  if s.percent ~= nil then
    ctx = string.format("%.0f%%", s.percent)
    if s.tokens and s.context_window then
      ctx = ctx .. string.format(" (%d/%d)", s.tokens, s.context_window)
    end
  elseif s.tokens and s.context_window then
    ctx = string.format("%d/%d", s.tokens, s.context_window)
  else
    ctx = "—"
  end
  local cost = s.cost ~= nil and string.format("$%.4f", s.cost) or "—"
  local lines = {
    "  pi-chat  ",
    "",
    "  status   " .. status,
  }
  if self._busy and self._exit_code == nil then
    local phase = ({
      waiting = "waiting for model…",
      thinking = "thinking…",
      tool = "running tool" .. (self._tool_name and (": " .. self._tool_name) or "…"),
      answering = "writing answer…",
    })[self._phase or "waiting"]
    local idle = math.floor((vim.uv.now() - (self._last_event_at or vim.uv.now())) / 1000)
    local live = idle < 1 and "just now" or (idle .. "s ago")
    if idle >= 30 then
      live = live .. "  ⚠ no response"
    end
    lines[#lines + 1] = "  doing    " .. phase
    lines[#lines + 1] = "  last pi  " .. live
  end
  vim.list_extend(lines, {
    "  session  " .. (self._session_name or "new session"),
    "  model    " .. model,
    "  context  " .. ctx,
    "  cost     " .. cost,
  })
  return lines
end

--- Toggle the floating info popup (status / session / model / context / cost).
function Session:toggle_info()
  if not (self.ui and self.ui:is_valid()) then
    return
  end
  self._info_auto = false -- a manual toggle takes ownership of the popup
  if self._info_open then
    self.ui:close_info()
    self._info_open = false
    self._info_user_closed = true -- don't re-open it again during this run
    return
  end
  self._info_open = true
  self._info_user_closed = false
  self.ui:open_info(self:_info_lines())
  -- Refresh stats so the popup reflects the latest numbers.
  self:_refresh_stats()
end

--- Re-render the info popup contents in place (no-op if it is closed).
function Session:refresh_info()
  if not (self._info_open and self.ui and self.ui:is_valid()) then
    return
  end
  self.ui:update_info(self:_info_lines())
end

function Session:_begin_assistant()
  -- One "▌ pi" header per assistant response, even across interleaved tool
  -- calls. _assistant_shown is reset on user submit.
  if not self._assistant_shown then
    self.ui:append_role(role_line("pi"))
    self._assistant_shown = true
    -- The role line sits 2 lines above the end (blank / role / rule / blank).
    self._final_pi_line = math.max(1, vim.api.nvim_buf_line_count(self.ui.conv_buf) - 2)
  else
    -- A later text segment of the same turn (after a tool call). Keep exactly
    -- one blank line between segments, no matter how many empty assistant
    -- messages (thinking-only) arrived in between.
    local n = vim.api.nvim_buf_line_count(self.ui.conv_buf)
    local last = vim.api.nvim_buf_get_lines(self.ui.conv_buf, n - 1, n, false)[1] or ""
    if last ~= "" then
      self.ui:append({ "", "" })
    end
  end
  self._last_role = "assistant"
  self._assistant_streaming = true
end

function Session:_ensure_assistant()
  -- Open a new assistant segment whenever we are not already streaming one
  -- (e.g. after a tool boundary).
  if not self._assistant_streaming or self._last_role ~= "assistant" then
    self:_begin_assistant()
  end
end

--- End the current assistant text segment (message end / tool boundary).
--- Adds nothing to the buffer: the separator is emitted lazily by
--- _begin_assistant only when the next segment has text, so a turn full of
--- thinking-only messages cannot leave a pile of blank lines behind.
function Session:_end_segment()
  self._assistant_streaming = false
  self._last_role = "segment_end"
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
  -- New user turn: allow one fresh "▌ pi" header for the upcoming response.
  self._assistant_shown = false
  self._final_pi_line = nil

  if self._busy then
    self.rpc:steer(text, images)
  else
    -- Show "running" at once instead of waiting for pi's turn_start event.
    self._info_user_closed = false
    self:_set_busy(true)
    self:_auto_open_info()
    self.rpc:prompt(text, images, function(resp)
      if resp and resp.success == false then
        self:_set_busy(false)
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
  self:_stop_tick()
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
      if self._info_open then
        self:refresh_info()
      end
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

--- Reset all per-turn / conversation rendering state (shared by new_session
--- and history rebuild).
function Session:_reset_conv_state()
  self._last_role = nil
  self._assistant_streaming = false
  self._assistant_shown = false
  self._final_pi_line = nil
end

--- Start a fresh session (discard the current conversation). pi keeps the old
--- session file on disk; this just swaps the live session to a new empty one.
function Session:new_session()
  if not self.rpc or self.rpc:is_closed() then
    return
  end
  self.rpc:send({ type = "new_session" }, function(resp)
    if not (resp and resp.success) then
      vim.notify("pi-chat: new_session failed", vim.log.levels.WARN)
      return
    end
    if resp.data and resp.data.cancelled then
      return
    end
    self:_reset_conv_state()
    self._session_name = nil
    if self.ui and self.ui:is_valid() then
      self:_render_intro()
    end
    -- Pull the new session's state (name/model/stats) and reflect it.
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
    local prev_role = nil
    for _, msg in ipairs(msgs) do
      prev_role = self:_render_history_message(msg, prev_role)
    end
    if renderable == 0 then
      self.ui:append({ "_(empty session)_" })
    end
    self.ui:scroll_to_end()
  end)
end

--- Render one persisted message (user/assistant) during history rebuild.
--- Consecutive assistant messages of one turn (pi splits them at tool calls)
--- share ONE "▌ pi" header; tool calls and thinking are not rendered at all.
--- @param prev_role string|nil  role rendered before this message
--- @return string|nil  role rendered for this message
function Session:_render_history_message(msg, prev_role)
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
    if t == "" then
      return prev_role
    end
    self.ui:append_role(role_line("You"))
    self.ui:append(vim.split(t, "\n", { plain = true }))
    return "user"
  end

  if role ~= "assistant" then
    return prev_role
  end

  local t = text_of(msg.content)
  if t == "" then
    return prev_role
  end
  if prev_role == "assistant" then
    -- Same turn, already under a "▌ pi" header: just a paragraph break.
    self.ui:append({ "" })
  else
    self.ui:append_role(role_line("pi"))
  end
  self.ui:append(vim.split(t, "\n", { plain = true }))
  return "assistant"
end

return M
