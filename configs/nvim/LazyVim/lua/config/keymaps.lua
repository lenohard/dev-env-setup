-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
local Util = require("lazyvim.util")

local function map(mode, lhs, rhs, opts)
  local keys = require("lazy.core.handler").handlers.keys
  ---@cast keys LazyKeysHandler
  -- do not create the keymap if a lazy keys handler exists
  if not keys.active[keys.parse({ lhs, mode = mode }).id] then
    opts = opts or {}
    opts.silent = opts.silent ~= false
    if opts.remap and not vim.g.vscode then
      opts.remap = nil
    end
    vim.keymap.set(mode, lhs, rhs, opts)
  end
end

-- use jk or kj to exit insert mode
map({ "i", "s" }, "jk", "<esc>", { desc = "jk to escape insert mode" })
map({ "i", "s" }, "kj", "<esc>", { desc = "kj to escape insert mode" })

-- use <leader>x o save and exit
map({ "n", "v" }, ",x", ":wqa<cr>", { desc = "save and exit" })
-- use <leader>X to force save and exit
map({ "n", "v" }, ",X", ":wqa!<cr>", { desc = "force save and exit" })

-- use ,h to switch to the previous buffer
map({ "n", "v" }, ",h", ":bp<cr>", { desc = "switch to previous buffer" })
-- use ,l to switch to the next buffer
map({ "n", "v" }, ",l", ":bn<cr>", { desc = "switch to next buffer" })

-- use ctrl-n to toggle neo-tree
map({ "n", "v" }, "<c-n>", ":Neotree toggle<cr>", { desc = "toggle neo-tree" })

-- use <leader>fo to telescope find old files
map({ "n", "v" }, "<leader>fo", ":Telescope oldfiles<cr>", { desc = "find old files" })

-- use 0 to move cursor to the first non-blank character of the line
map({ "n", "v" }, "0", "^", { desc = "move cursor to the first non-blank character of the line" })

-- use <c-e> to execute cmd EslintFixAll
map({ "n", "v" }, "<c-e>", ":EslintFixAll<cr>", { desc = "execute cmd EslintFixAll" })

-- use ,bb to execute cmd :Bdelete
map({ "n", "v" }, ",bb", ":Bdelete<cr>", { desc = "delete current buffer" })

-- The function that performs the action
function insert_blank_line_above()
  -- Store the current line number
  local cur_line = vim.fn.line(".")

  -- Insert a new blank line above the current line
  vim.api.nvim_buf_set_lines(0, cur_line - 1, cur_line - 1, false, { "" })
  -- move the cursor to the new blank line
  vim.fn.cursor(cur_line - 1, 0)
end

-- the function that performs the action
function insert_blank_line_below()
  -- Store the current line number
  local cur_line = vim.fn.line(".")

  -- Insert a new blank line below the current line
  vim.api.nvim_buf_set_lines(0, cur_line, cur_line, false, { "" })
  -- move the cursor to the new blank line
  vim.fn.cursor(cur_line + 1, 0)
end

-- Map the function to '[+Space'
map({ "n", "v" }, "[<Space>", ":lua insert_blank_line_above()<cr>", { desc = "insert blank line above" })
map({ "n", "v" }, "]<Space>", ":lua insert_blank_line_below()<cr>", { desc = "insert blank line below" })

-- map <leader>fc to copy the path of the current file to the clipboard and show a message
map(
  { "n", "v" },
  "<leader>fc",
  ":let @*=expand('%:p') | echo 'Copied ' . expand('%:p') . ' to clipboard'<cr>",
  { desc = "copy the path of the current file to the clipboard" }
)

-- map <leader>fd to copy the relative path of the current file to the clipboard and show a message
map(
  { "n", "v" },
  "<leader>fd",
  ":let @*=expand('%') | echo 'Copied ' . expand('%') . ' to clipboard'<cr>",
  { desc = "copy the relative path of the current file to the clipboard" }
)
