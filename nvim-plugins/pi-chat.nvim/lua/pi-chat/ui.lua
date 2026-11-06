-- pi-chat.nvim :: UI layer
--
-- Right-side vertical split:
--   top    = conversation buffer (markdown, read-only, folded tool blocks)
--   bottom = input buffer (type here, <CR>/<C-s> to send)
--
-- The conversation buffer is plain markdown text. Structure comes from
-- `## ` headings (one per message / tool block) so `]]`/`[[` and
-- render-markdown.nvim work natively. Tool blocks are wrapped in fold markers
-- ({{{ / }}}) so they collapse by default.

local M = {}

local ns = vim.api.nvim_create_namespace("pi_chat")

-- Persistent winbar hint (always visible so the user never has to remember keys).
local CONV_WINBAR = "pi ❯ conversation"

-- Highlight groups for role separators. Linked to common groups so they adapt
-- to the active colorscheme (bar = accent/function, rule = comment/dim).
local function ensure_highlights()
  if vim.fn.hlexists("PiChatRole") == 1 then
    return
  end
  vim.api.nvim_set_hl(0, "PiChatRole", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "PiChatRule", { link = "Comment", default = true })
end

--- @class PiChatUI
--- @field conv_buf integer
--- @field conv_win integer
--- @field input_buf integer
--- @field input_win integer
--- @field on_submit fun(text: string)
--- @field on_abort fun()
--- @field on_quit fun()
local UI = {}
UI.__index = UI

local function buf_set_lines(buf, start, stop, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, start, stop, false, lines)
  vim.bo[buf].modifiable = false
end

local function append_lines(buf, lines)
  local n = vim.api.nvim_buf_line_count(buf)
  -- If the buffer is just a single empty line, replace it.
  if n == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then
    buf_set_lines(buf, 0, 1, lines)
  else
    buf_set_lines(buf, n, n, lines)
  end
end

--- Create the split and return a UI handle.
--- @param opts table { width?: integer, on_submit, on_abort, on_quit, on_pick_model?, on_pick_session? }
function M.open(opts)
  ensure_highlights()
  local self = setmetatable({
    on_submit = opts.on_submit,
    on_abort = opts.on_abort,
    on_quit = opts.on_quit,
    on_pick_model = opts.on_pick_model,
    on_pick_session = opts.on_pick_session,
    on_paste_image = opts.on_paste_image,
    on_open_image = opts.on_open_image,
  }, UI)

  local width = opts.width or math.max(60, math.floor(vim.o.columns * 0.4))

  -- Conversation buffer (scratch). Uses a dedicated `pichat` filetype so the
  -- render-markdown override applies only here, never to real markdown files.
  self.conv_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.conv_buf].buftype = "nofile"
  vim.bo[self.conv_buf].bufhidden = "hide"
  vim.bo[self.conv_buf].swapfile = false
  vim.bo[self.conv_buf].filetype = "pichat"
  vim.bo[self.conv_buf].modifiable = false
  vim.api.nvim_buf_set_name(self.conv_buf, "pi-chat")

  -- Input buffer (scratch). Plain filetype — no markdown rendering while typing.
  self.input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.input_buf].buftype = "nofile"
  vim.bo[self.input_buf].bufhidden = "hide"
  vim.bo[self.input_buf].swapfile = false
  vim.bo[self.input_buf].filetype = "pichat-input"
  vim.api.nvim_buf_set_name(self.input_buf, "pi-chat://input")

  -- Layout: a dedicated full-screen tab. Conversation fills the tab; a small
  -- input split sits at the bottom. Starts at 2 lines and auto-grows up to 4.
  --
  -- `tabnew` opens an empty [No Name] scratch buffer in the new tab; we swap in
  -- conv_buf and then wipe that leftover buffer so it never shows in the
  -- buffer list or tabline.
  vim.cmd("tabnew")
  self.tabpage = vim.api.nvim_get_current_tabpage()
  local leftover = vim.api.nvim_get_current_buf()
  self.conv_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.conv_win, self.conv_buf)
  self:_set_conv_win_opts()
  if leftover ~= self.conv_buf
    and vim.api.nvim_buf_is_valid(leftover)
    and vim.api.nvim_buf_get_name(leftover) == ""
    and vim.bo[leftover].buftype == ""
  then
    pcall(vim.api.nvim_buf_delete, leftover, { force = true })
  end
  -- Fixed tab title (read by common tablines; also drives the default label).
  pcall(vim.api.nvim_tabpage_set_var, self.tabpage, "pichat", true)

  vim.cmd("belowright 1split")
  self.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.input_win, self.input_buf)
  vim.wo[self.input_win].number = false
  vim.wo[self.input_win].relativenumber = false
  vim.wo[self.input_win].winfixheight = true
  vim.api.nvim_win_set_height(self.input_win, 2)
  self:_setup_input_autogrow()

  self:_set_keymaps()
  self:_setup_statusline()
  self:focus_input()
  return self
end

-- Per-window statusline for pi-chat buffers only. Reads a buffer-local stats
-- table (set via UI:set_stats) so the global lualine is untouched elsewhere.
function _G.PiChatStatusline()
  local b = vim.b.pichat_stats
  if not b then
    return "  pi-chat"
  end
  local parts = { "  pi-chat" }
  if b.percent ~= nil then
    parts[#parts + 1] = string.format("ctx %.0f%%%%", b.percent)
  elseif b.tokens and b.context_window then
    parts[#parts + 1] = string.format("ctx %d/%d", b.tokens, b.context_window)
  end
  if b.cost ~= nil then
    parts[#parts + 1] = string.format("$%.4f", b.cost)
  end
  return "  " .. table.concat(parts, "  │  ")
end

function UI:_setup_statusline()
  local sl = "%!v:lua.PiChatStatusline()"
  for _, win in ipairs({ self.conv_win, self.input_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.wo[win].statusline = sl
    end
  end
end

--- Update the pi-chat stats shown in the per-window statusline.
--- @param stats table { percent?, tokens?, context_window?, cost? }
function UI:set_stats(stats)
  for _, buf in ipairs({ self.conv_buf, self.input_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.b[buf].pichat_stats = stats
    end
  end
  -- Force a redraw of the statusline.
  if vim.api.nvim_get_mode().mode ~= "c" then
    pcall(vim.cmd, "redrawstatus")
  end
end

--- Auto-resize the input window between 2 and 4 lines as content changes.
function UI:_setup_input_autogrow()
  local MIN, MAX = 2, 4
  local function resize()
    if not (self.input_win and vim.api.nvim_win_is_valid(self.input_win)) then
      return
    end
    local n = vim.api.nvim_buf_line_count(self.input_buf)
    local h = math.max(MIN, math.min(MAX, n))
    pcall(vim.api.nvim_win_set_height, self.input_win, h)
  end
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    buffer = self.input_buf,
    callback = resize,
  })
  resize()
end

function UI:_set_conv_win_opts()
  local w = self.conv_win
  vim.wo[w].number = false
  vim.wo[w].relativenumber = false
  vim.wo[w].wrap = true
  vim.wo[w].linebreak = true
  vim.wo[w].foldmethod = "marker"
  vim.wo[w].foldlevel = 0 -- tool blocks start collapsed
  vim.wo[w].foldcolumn = "0" -- no fold gutter; use za/zR/zM instead
  vim.wo[w].signcolumn = "no"
  vim.wo[w].winbar = CONV_WINBAR
end

function UI:_set_keymaps()
  local function map(buf, mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  -- Input: submit.
  local submit = function()
    local lines = vim.api.nvim_buf_get_lines(self.input_buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    if text == "" then
      return
    end
    vim.api.nvim_buf_set_lines(self.input_buf, 0, -1, false, { "" })
    if self.on_submit then
      self.on_submit(text)
    end
  end
  map(self.input_buf, "n", "<CR>", submit)
  map(self.input_buf, "i", "<C-s>", submit)
  map(self.input_buf, "n", "<C-s>", submit)

  -- Abort / quit, bound in both buffers.
  for _, buf in ipairs({ self.conv_buf, self.input_buf }) do
    map(buf, { "n", "i" }, "<C-c>", function()
      if self.on_abort then
        self.on_abort()
      end
    end)
    map(buf, "n", "q", function()
      if self.on_quit then
        self.on_quit()
      end
    end)
    -- Toggle focus between input and conversation, in both normal and insert
    -- mode (the input buffer is usually in insert mode while typing).
    map(buf, { "n", "i" }, "<Tab>", function()
      self:toggle_focus()
    end)
  end

  -- Conversation: jump between role separators (▌ You / ▌ pi / ▌ 🔧).
  map(self.conv_buf, "n", "]]", function()
    vim.fn.search("^\u{258c} ", "W")
  end)
  map(self.conv_buf, "n", "[[", function()
    vim.fn.search("^\u{258c} ", "bW")
  end)

  -- Model / session pickers, bound in both buffers for convenience.
  local leader = vim.g.mapleader or "\\"
  for _, buf in ipairs({ self.conv_buf, self.input_buf }) do
    map(buf, { "n", "i" }, "<leader>pm", function()
      if self.on_pick_model then
        self.on_pick_model()
      end
    end)
    map(buf, { "n", "i" }, "<leader>ps", function()
      if self.on_pick_session then
        self.on_pick_session()
      end
    end)
    map(buf, { "n", "i" }, "<leader>pn", function()
      if self.on_new_session then
        self.on_new_session()
      end
    end)
  end

  -- Input: attach a clipboard image (queued for the next submit).
  map(self.input_buf, { "n", "i" }, "<C-v>", function()
    if self.on_paste_image then
      self.on_paste_image()
    end
  end)
  map(self.input_buf, { "n", "i" }, "<leader>pp", function()
    if self.on_paste_image then
      self.on_paste_image()
    end
  end)

  -- Conversation: open the image on the current line with the system viewer.
  map(self.conv_buf, "n", "<leader>po", function()
    if self.on_open_image then
      self.on_open_image()
    end
  end)
end

function UI:is_valid()
  return self.conv_buf
    and vim.api.nvim_buf_is_valid(self.conv_buf)
    and self.conv_win
    and vim.api.nvim_win_is_valid(self.conv_win)
end

function UI:focus_input()
  if self.input_win and vim.api.nvim_win_is_valid(self.input_win) then
    vim.api.nvim_set_current_win(self.input_win)
    vim.cmd("startinsert")
  end
end

function UI:toggle_focus()
  local cur = vim.api.nvim_get_current_win()
  if cur == self.input_win and vim.api.nvim_win_is_valid(self.conv_win) then
    vim.api.nvim_set_current_win(self.conv_win)
  elseif vim.api.nvim_win_is_valid(self.input_win) then
    self:focus_input()
  end
end

--- Scroll conversation to the bottom (follow streaming output) unless the user
--- has scrolled up and is not at the last line.
function UI:scroll_to_end()
  if not (self.conv_win and vim.api.nvim_win_is_valid(self.conv_win)) then
    return
  end
  local n = vim.api.nvim_buf_line_count(self.conv_buf)
  -- Only autoscroll when the conversation window isn't the focused one, or the
  -- cursor is already near the end (so we don't yank the user's view away).
  pcall(vim.api.nvim_win_set_cursor, self.conv_win, { n, 0 })
end

--- Clear the whole conversation buffer back to a single empty line.
function UI:clear()
  if not self:is_valid() then
    return
  end
  buf_set_lines(self.conv_buf, 0, -1, { "" })
end

--- Append complete lines to the conversation buffer.
function UI:append(lines)
  if not self:is_valid() then
    return
  end
  append_lines(self.conv_buf, lines)
  self:scroll_to_end()
end

--- Append a role separator: a blank line, the bar-prefixed role line, and a
--- dim horizontal rule. Highlights the bar (accent) and dims the rule via
--- extmarks, so render-markdown never sees a heading.
function UI:append_role(role_text)
  if not self:is_valid() then
    return
  end
  local width = 0
  if self.conv_win and vim.api.nvim_win_is_valid(self.conv_win) then
    width = math.max(12, (vim.api.nvim_win_get_width(self.conv_win) or 40) - 2)
  end
  local rule = string.rep("\u{2500}", math.min(width, 48))
  append_lines(self.conv_buf, { "", role_text, rule, "" })

  local n = vim.api.nvim_buf_line_count(self.conv_buf)
  -- role line is n-2 (1-based) -> 0-based n-3 ; rule line is n-1 -> 0-based n-2
  local role_idx = n - 3
  local rule_idx = n - 2
  pcall(vim.api.nvim_buf_set_extmark, self.conv_buf, ns, role_idx, 0, {
    end_col = #role_text,
    hl_group = "PiChatRole",
  })
  pcall(vim.api.nvim_buf_set_extmark, self.conv_buf, ns, rule_idx, 0, {
    end_row = rule_idx + 1,
    end_col = 0,
    hl_group = "PiChatRule",
  })
  self:scroll_to_end()
end

--- Append streamed text to the LAST line of the conversation buffer, splitting
--- on embedded newlines. Used for token-by-token assistant output.
function UI:append_stream(text)
  if not self:is_valid() or text == "" then
    return
  end
  local buf = self.conv_buf
  local last_idx = vim.api.nvim_buf_line_count(buf) - 1
  local last_line = vim.api.nvim_buf_get_lines(buf, last_idx, last_idx + 1, false)[1] or ""
  local parts = vim.split(last_line .. text, "\n", { plain = true })
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, last_idx, last_idx + 1, false, parts)
  vim.bo[buf].modifiable = false
  self:scroll_to_end()
end

--- Update the conversation winbar with session name, model, run status, and
--- the persistent key hint for jumping / switching models.
function UI:set_conv_winbar(status, model, session_name)
  if self.conv_win and vim.api.nvim_win_is_valid(self.conv_win) then
    local dot = status == "running…" and "●" or "○"
    local name = session_name and (" " .. session_name .. "  │  ") or ""
    vim.wo[self.conv_win].winbar = string.format(
      "pi ❯ %s %s  │  %s%s  │  <leader>pn new · <leader>pm model · <leader>ps sessions",
      dot,
      status,
      name,
      model or "?"
    )
  end
end

function UI:close()
  for _, win in ipairs({ self.input_win, self.conv_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  -- Closing both windows disposes the dedicated tab. Nothing else to do.
  for _, buf in ipairs({ self.input_buf, self.conv_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

return M
