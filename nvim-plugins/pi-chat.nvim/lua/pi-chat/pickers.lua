-- pi-chat.nvim :: pickers
--
-- Pop-up selectors for models and sessions. Uses telescope when available
-- (fuzzy search over long lists), falls back to vim.ui.select otherwise.

local M = {}

local function has_telescope()
  return pcall(require, "telescope")
end

--- Generic telescope picker over a list of { display, value } entries.
local function telescope_pick(title, entries, on_choice)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = title,
      finder = finders.new_table({
        results = entries,
        entry_maker = function(e)
          return { value = e.value, display = e.display, ordinal = e.display }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local sel = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if sel then
            on_choice(sel.value)
          end
        end)
        -- One-press exit: <Esc> (both modes) and <C-c> close immediately,
        -- instead of telescope's default two-step insert->normal->close.
        local close = function()
          actions.close(prompt_bufnr)
        end
        map("i", "<Esc>", close)
        map("n", "<Esc>", close)
        map("i", "<C-c>", close)
        map("n", "q", close)
        return true
      end,
    })
    :find()
end

--- Show a picker; prefers telescope, else vim.ui.select.
--- @param title string
--- @param entries table[]  list of { display = string, value = any }
--- @param on_choice fun(value: any)
function M.pick(title, entries, on_choice)
  if #entries == 0 then
    vim.notify("pi-chat: nothing to pick", vim.log.levels.WARN)
    return
  end
  if has_telescope() then
    telescope_pick(title, entries, on_choice)
  else
    vim.ui.select(entries, {
      prompt = title,
      format_item = function(e)
        return e.display
      end,
    }, function(choice)
      if choice then
        on_choice(choice.value)
      end
    end)
  end
end

return M
