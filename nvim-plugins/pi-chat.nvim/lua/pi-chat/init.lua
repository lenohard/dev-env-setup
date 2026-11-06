-- pi-chat.nvim :: public API
--
-- A thin Neovim client for the pi coding agent over its RPC mode.
-- Opens a right-side split chat: stream output, collapsible tool blocks,
-- heading navigation, and native approval dialogs (ask / sudo / git review).

local session_mod = require("pi-chat.session")

local M = {}

M.config = {
  pi_bin = "pi",
  no_session = false, -- keep sessions by default so history persists
  model = nil,
  provider = nil,
  extra_args = nil, -- extra args appended to `pi --mode rpc`
  cwd = nil, -- defaults to vim.fn.getcwd()
  width = nil, -- defaults to 40% of columns
}

--- @type table|nil  the single active session
local active = nil

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

--- Internal accessor for the active session (used by tests and advanced use).
function M._active()
  return active
end

--- Open (or focus) the chat.
function M.open()
  if active and active.ui and active.ui:is_valid() then
    active.ui:focus_input()
    return
  end
  active = session_mod.new(M.config)
  active:open()
end

--- Open and immediately send a prompt.
function M.ask(text)
  M.open()
  if text and text ~= "" then
    vim.schedule(function()
      active:submit(text)
    end)
  end
end

--- Send the current visual selection as a prompt (with a question).
function M.ask_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local lines = vim.api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)
  local selection = table.concat(lines, "\n")
  vim.ui.input({ prompt = "Ask pi about selection: " }, function(q)
    if not q or q == "" then
      return
    end
    local ft = vim.bo.filetype
    local prompt = q .. "\n\n```" .. ft .. "\n" .. selection .. "\n```"
    M.ask(prompt)
  end)
end

function M.close()
  if active then
    active:close()
    active = nil
  end
end

function M.toggle()
  if active and active.ui and active.ui:is_valid() then
    M.close()
  else
    M.open()
  end
end

function M.is_open()
  return active ~= nil and active.ui ~= nil and active.ui:is_valid()
end

--- Pop up the scoped-model picker and switch the active session's model.
function M.pick_model()
  if not M.is_open() then
    M.open()
  end
  if not (active and active.rpc) then
    vim.notify("pi-chat: agent not connected", vim.log.levels.WARN)
    return
  end
  local models = require("pi-chat.models")
  local pickers = require("pi-chat.pickers")
  active.rpc:send({ type = "get_available_models" }, function(resp)
    if not (resp and resp.success and resp.data) then
      vim.notify("pi-chat: could not list models", vim.log.levels.WARN)
      return
    end
    local scoped = models.filter_scoped(resp.data.models or {})
    if #scoped == 0 then
      scoped = resp.data.models or {}
    end
    local cur = active:current_model()
    local entries = {}
    for _, m in ipairs(scoped) do
      local full = (m.provider or "") .. "/" .. (m.id or "")
      local mark = (cur and cur.provider == m.provider and cur.id == m.id) and "● " or "  "
      entries[#entries + 1] = {
        display = mark .. (m.name or full),
        value = { provider = m.provider, id = m.id },
      }
    end
    pickers.pick("pi models", entries, function(v)
      active:set_model(v.provider, v.id)
    end)
  end)
end

--- Pop up the session picker; switch the active session to the chosen one.
function M.pick_session()
  if not M.is_open() then
    M.open()
  end
  local sessions = require("pi-chat.sessions")
  local pickers = require("pi-chat.pickers")
  local items = sessions.list(50)
  local entries = {}
  for _, it in ipairs(items) do
    entries[#entries + 1] = { display = it.display, value = it.path }
  end
  pickers.pick("pi sessions", entries, function(path)
    if active then
      active:switch_session(path)
    end
  end)
end

--- Continue the most recent session (by mtime).
function M.continue()
  if not M.is_open() then
    M.open()
  end
  local sessions = require("pi-chat.sessions")
  local items = sessions.list(1)
  if #items == 0 then
    vim.notify("pi-chat: no sessions found", vim.log.levels.INFO)
    return
  end
  if active then
    active:switch_session(items[1].path)
  end
end

--- Start a fresh session, discarding the current conversation view.
function M.new_session()
  if not M.is_open() then
    -- Opening already starts a fresh session; nothing more to do.
    M.open()
    return
  end
  if active then
    active:new_session()
  end
end

--- Toggle the floating info popup (status / session / model / context / cost).
function M.toggle_info()
  if not M.is_open() then
    M.open()
    return
  end
  if active then
    active:toggle_info()
  end
end

return M
