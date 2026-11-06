-- pi-chat.nvim :: scoped-model resolution
--
-- pi's RPC `get_available_models` returns the full catalog (hundreds of
-- models). The user's scoped set is configured in settings.json as
-- `enabledModels` (provider/id patterns, same format as --models). We filter
-- the catalog by those patterns so the picker only shows the scoped models.

local M = {}

--- Read `enabledModels` patterns from pi settings.json.
--- @return string[] patterns  (empty = no scoping -> show all)
function M.scoped_patterns()
  local path = vim.fn.expand("~/.pi/agent/settings.json")
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  if not ok or type(data) ~= "table" then
    return {}
  end
  local pats = data.enabledModels
  if type(pats) ~= "table" then
    return {}
  end
  return pats
end

--- Translate a pi/--models glob pattern into a Lua pattern (case-insensitive).
local function glob_to_lua(glob)
  local p = glob:lower():gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%1")
  p = p:gsub("%*", ".*"):gsub("%?", ".")
  return "^" .. p .. "$"
end

--- Does `provider/id` match a pattern? Exact first, then glob.
local function matches(full, pattern)
  if full == pattern then
    return true
  end
  local lp = glob_to_lua(pattern)
  return full:lower():match(lp) ~= nil
end

--- Filter a catalog (array of Model objects) by scoped patterns.
--- @param models table[]  each has provider, id, name
--- @return table[]  scoped subset (or the whole catalog if no patterns)
function M.filter_scoped(models)
  local patterns = M.scoped_patterns()
  if #patterns == 0 then
    return models
  end
  local out = {}
  for _, m in ipairs(models) do
    local full = (m.provider or "") .. "/" .. (m.id or "")
    for _, p in ipairs(patterns) do
      if matches(full, p) then
        out[#out + 1] = m
        break
      end
    end
  end
  return out
end

return M
