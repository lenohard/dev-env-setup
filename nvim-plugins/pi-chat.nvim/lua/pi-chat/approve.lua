-- pi-chat.nvim :: extension UI (approval) handler
--
-- Maps pi's `extension_ui_request` records to native nvim dialogs and sends
-- back `extension_ui_response` with the matching id. Covers the three
-- interactive needs: ask tool (select/input), git safety review (select/
-- confirm), and sudo password (input, treated as secret).
--
-- Dialog methods (require a response): select, confirm, input, editor
-- Fire-and-forget (no response): notify, setStatus, setWidget, setTitle,
--                                set_editor_text
--
-- SECURITY: when a request looks like a password/secret prompt we use
-- inputsecret() so the value is never echoed, never written to any buffer,
-- and never logged.

local M = {}

local function looks_secret(req)
  local hay = ((req.title or "") .. " " .. (req.placeholder or "")):lower()
  return hay:find("password", 1, true)
    or hay:find("passphrase", 1, true)
    or hay:find("secret", 1, true)
    or hay:find("sudo", 1, true)
end

--- Handle one extension_ui_request. `rpc` is used to send the response.
--- @param rpc table   -- the Rpc handle (has :ui_response)
--- @param req table   -- the extension_ui_request record
--- @param log fun(line: string)?  -- optional sink for a short transcript note
function M.handle(rpc, req, log)
  local method = req.method
  local id = req.id

  if method == "select" then
    local options = req.options or {}
    vim.ui.select(options, {
      prompt = req.title or "Select",
    }, function(choice)
      if choice == nil then
        rpc:ui_response(id, { cancelled = true })
      else
        rpc:ui_response(id, { value = choice })
      end
    end)
    return
  end

  if method == "confirm" then
    local prompt = (req.title or "Confirm")
    if req.message and req.message ~= "" then
      prompt = prompt .. " — " .. req.message
    end
    vim.ui.select({ "Yes", "No" }, { prompt = prompt }, function(choice)
      if choice == nil then
        rpc:ui_response(id, { cancelled = true })
      else
        rpc:ui_response(id, { confirmed = choice == "Yes" })
      end
    end)
    return
  end

  if method == "input" then
    if looks_secret(req) then
      -- inputsecret() blocks and never echoes; value stays out of buffers/logs.
      local ok, value = pcall(vim.fn.inputsecret, (req.title or "Password") .. ": ")
      if not ok or value == nil then
        rpc:ui_response(id, { cancelled = true })
      else
        rpc:ui_response(id, { value = value })
      end
      -- Do NOT log the value.
      return
    end
    vim.ui.input({
      prompt = (req.title or "Input") .. ": ",
      default = "",
    }, function(value)
      if value == nil then
        rpc:ui_response(id, { cancelled = true })
      else
        rpc:ui_response(id, { value = value })
      end
    end)
    return
  end

  if method == "editor" then
    -- Open a scratch buffer with the prefill, let the user edit, submit on
    -- :w / close. Simplest robust approach: prompt via input for a single line
    -- when short, otherwise a floating scratch. Keep it minimal: use a prompt
    -- scratch buffer.
    M._editor_dialog(rpc, id, req.title or "Edit", req.prefill or "")
    return
  end

  -- Fire-and-forget methods: display or ignore, no response.
  if method == "notify" then
    local msg = req.message or ""
    -- Suppress noisy session-start chrome (git-extension dirty-repo warning,
    -- live-status counters) that just clutters the chat.
    local noisy = msg:find("Dirty repo", 1, true)
      or msg:find("uncommitted change", 1, true)
    if noisy then
      return
    end
    local level = ({
      info = vim.log.levels.INFO,
      warning = vim.log.levels.WARN,
      error = vim.log.levels.ERROR,
    })[req.notifyType or "info"] or vim.log.levels.INFO
    vim.notify("[pi] " .. msg, level)
    if log and msg ~= "" then
      log("ℹ " .. msg)
    end
    return
  end

  if method == "setTitle" and req.title then
    pcall(function()
      vim.o.titlestring = req.title
    end)
    return
  end

  -- setStatus / setWidget / set_editor_text: no-op for now (could surface in
  -- the winbar later). Silently ignore — they expect no response.
end

--- Minimal multi-line editor dialog backed by a floating scratch buffer.
function M._editor_dialog(rpc, id, title, prefill)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(prefill, "\n", { plain = true }))

  local width = math.floor(vim.o.columns * 0.6)
  local height = math.floor(vim.o.lines * 0.4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. "  (:w submit · :q cancel) ",
  })

  local done = false
  local function finish(cancelled)
    if done then
      return
    end
    done = true
    local value
    if not cancelled then
      value = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if cancelled then
      rpc:ui_response(id, { cancelled = true })
    else
      rpc:ui_response(id, { value = value })
    end
  end

  vim.keymap.set("n", "<C-s>", function()
    finish(false)
  end, { buffer = buf, silent = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      finish(false)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinClosed", "BufWipeout" }, {
    buffer = buf,
    once = true,
    callback = function()
      finish(true)
    end,
  })
end

return M
