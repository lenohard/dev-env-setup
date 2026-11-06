-- pi-chat.nvim :: session listing
--
-- pi has no RPC "list sessions" command, so we scan the sessions directory
-- directly. Session files are JSONL named `<timestamp>_<id>.jsonl`, grouped
-- into per-cwd subdirectories. For each file we extract a display name (the
-- session name if set, else the first user message) and sort by mtime.

local M = {}

local SESSIONS_ROOT = vim.fn.expand("~/.pi/agent/sessions")

--- Read the first ~40 lines of a JSONL session and derive a preview.
--- @return string|nil name, string|nil first_user
local function preview(path)
  local f = io.open(path, "r")
  if not f then
    return nil, nil
  end
  local name, first_user
  local count = 0
  for line in f:lines() do
    count = count + 1
    if count > 60 then
      break
    end
    local ok, rec = pcall(vim.json.decode, line)
    if ok and type(rec) == "table" then
      -- session_info_changed / header name
      if rec.name and type(rec.name) == "string" and rec.name ~= "" then
        name = rec.name
      end
      if rec.type == "session_info_changed" and rec.name then
        name = rec.name
      end
      -- first user message
      if not first_user then
        local m = rec.message or rec
        if m and m.role == "user" then
          local c = m.content
          if type(c) == "string" then
            first_user = c
          elseif type(c) == "table" then
            for _, part in ipairs(c) do
              if type(part) == "table" and part.type == "text" and part.text then
                first_user = part.text
                break
              end
            end
          end
        end
      end
    end
  end
  f:close()
  return name, first_user
end

local function rel_time(mtime)
  local diff = os.time() - mtime
  if diff < 60 then
    return diff .. "s ago"
  elseif diff < 3600 then
    return math.floor(diff / 60) .. "m ago"
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. "h ago"
  else
    return math.floor(diff / 86400) .. "d ago"
  end
end

--- List recent sessions.
--- @param limit? integer   default 50
--- @return table[]  each { path, name, preview, mtime, display }
function M.list(limit)
  limit = limit or 50
  local files = vim.fn.globpath(SESSIONS_ROOT, "**/*.jsonl", true, true)
  local items = {}
  for _, path in ipairs(files) do
    local st = vim.uv.fs_stat(path)
    if st then
      items[#items + 1] = { path = path, mtime = st.mtime.sec }
    end
  end
  table.sort(items, function(a, b)
    return a.mtime > b.mtime
  end)
  if #items > limit then
    items = vim.list_slice(items, 1, limit)
  end

  for _, it in ipairs(items) do
    local name, first = preview(it.path)
    it.name = name
    it.preview = first
    local label = name or (first and first:gsub("%s+", " "):sub(1, 50)) or "(empty)"
    label = label:gsub("\n", " ")
    it.display = string.format("%-52s  %s", label:sub(1, 52), rel_time(it.mtime))
  end
  return items
end

return M
