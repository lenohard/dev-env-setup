-- pi-chat.nvim :: inline editing (co-editing) engine
--
-- Sends the current buffer (plus metadata) to a ONE-SHOT `pi -p` run and
-- inserts the model's answer straight into the buffer. The model must answer
-- with a single delimited block:
--
--     <<<PI_EDIT>>>
--     ...content to insert...
--     <<<PI_END>>>
--
-- Everything outside the block is dropped, so a chatty model can never dump
-- prose into the file. The inserted range is marked with an extmark
-- (PiChatEdit highlight) so it is visible as AI-written while it is fresh;
-- no marker text is added to the file itself.
--
-- The one-shot run is a separate `pi -p` process (not the chat session): it
-- has no tools, no extensions and no session file, so it cannot touch the
-- project and cannot pollute the chat transcript.

local M = {}

M.config = {
  model = nil, -- model for the one-shot run (nil = the chat session's model)
  provider = nil,
  extra_args = nil,
  timeout_ms = 120000,
  max_context_bytes = 60000, -- above this only a window around the cursor is sent
  window_lines = 200, -- window size on each side of the cursor
  comment_answers = true, -- prefix answers with the filetype's comment string
}

local START = "<<<PI_EDIT>>>"
local FINISH = "<<<PI_END>>>"
local CURSOR = "<<<PI_CURSOR>>>"

local ns = vim.api.nvim_create_namespace("pi-chat-edit")

-- Highlight of the freshly inserted range (removed by undo / reload).
vim.api.nvim_set_hl(0, "PiChatEdit", { link = "DiffAdd", default = true })

local busy = false

--- Is an edit request in flight?
function M.is_busy()
  return busy
end

--- Merge user options into the edit config.
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

--------------------------------------------------------------------------
-- context
--------------------------------------------------------------------------

--- Lines that legitimately start at column 0 even inside an indented block.
local function is_dedent_line(line)
  return line:match("^[ \t]*(end|else|elseif|elif|except|finally|case|default)([^%w]|$)") ~= nil
    or line:match("^[ \t]*[%}%)]") ~= nil
end

--- Does this line open a block (so the next line is indented one level more)?
local function opens_block(line)
  local t = line:gsub("%s+$", "")
  if t:match("[%w%)]%s*then$") or t:match("[%w%)]%s*do$") or t:match("{}$") then
    return true
  end
  if t:match("function%s+[%w_]+%s*%b()") or t:match("^%s*def%s") or t:match("^%s*class%s") then
    return true
  end
  return false
end

--- Indentation to use for text inserted on a blank line: the indentation of
--- the next non-blank line, or - when that line closes a block - the
--- indentation of the previous line (plus one level if it opens a block).
--- @param lines table
--- @param row integer  1-based line number of the blank line
--- @return string
local function infer_indent(lines, row)
  local step
  local prev
  for _, l in ipairs(lines) do
    if l and l:match("%S") then
      local ind = #(l:match("^[ \t]*") or "")
      if prev and ind > prev then
        local d = ind - prev
        if not step or d < step then
          step = d
        end
      end
      prev = ind
    end
  end
  step = step or 2
  for i = row + 1, #lines do
    local l = lines[i]
    if l and l:match("%S") then
      if not is_dedent_line(l) then
        return l:match("^[ \t]*") or ""
      end
      break
    end
  end
  for i = row - 1, 1, -1 do
    local l = lines[i]
    if l and l:match("%S") then
      local ind = l:match("^[ \t]*") or ""
      if opens_block(l) then
        ind = ind .. string.rep(" ", step)
      end
      return ind
    end
  end
  return ""
end

--- Collect the buffer content (with a cursor marker) plus metadata.
--- @param bufnr integer
--- @return table { text, meta }
local function collect_context(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local win = vim.fn.bufwinid(bufnr)
  local row, col = 1, 0
  if win > 0 then
    local c = vim.api.nvim_win_get_cursor(win)
    row, col = c[1], c[2]
  end

  local marked = {}
  for i, l in ipairs(lines) do
    marked[i] = l
  end
  local cur = marked[row] or ""
  marked[row] = cur:sub(1, col) .. CURSOR .. cur:sub(col + 1)
  local base_indent = cur:match("^[ \t]*") or ""
  if base_indent == "" and cur:match("^%s*$") then
    -- Blank line: infer the indentation of the block it sits in.
    base_indent = infer_indent(lines, row)
  end

  local text = table.concat(marked, "\n")
  local meta = {
    path = vim.api.nvim_buf_get_name(bufnr),
    filetype = vim.bo[bufnr].filetype,
    cursor_line = row,
    cursor_col = col,
    line_count = #lines,
    base_indent = base_indent,
    truncated = false,
  }

  -- Very large files: send a window around the cursor instead of the whole
  -- buffer, and say so in the prompt.
  if #text > M.config.max_context_bytes then
    local first = math.max(1, row - M.config.window_lines)
    local last = math.min(#lines, row + M.config.window_lines)
    local win_lines = {}
    for i = first, last do
      win_lines[#win_lines + 1] = marked[i]
    end
    text = table.concat(win_lines, "\n")
    meta.truncated = true
    meta.window = { first = first, last = last }
  end

  return { text = text, meta = meta }
end

--------------------------------------------------------------------------
-- prompt
--------------------------------------------------------------------------

local RULES = table.concat({
  "You are an inline editing assistant embedded in a code editor.",
  "You never chat. You never explain. You never greet.",
  "",
  "MANDATORY output format:",
  START,
  "<content to insert>",
  FINISH,
  "",
  "Rules:",
  "1. Output exactly one block, delimited by the two markers above.",
  "2. Nothing outside the block: no preamble, no \"Sure\", no closing remarks.",
  "3. The content is inserted verbatim into the file, so it must be complete",
  "   and paste-ready: no markdown code fences, no \"here is the code\".",
  "4. Keep the file's language, style and absolute indentation exactly.",
}, "\n")

--- Build the prompt for one of the two modes.
--- @param mode string  "continue" | "ask"
--- @param question string|nil
--- @param ctx table
--- @return string
local function build_prompt(mode, question, ctx)
  local meta = ctx.meta
  local parts = {
    RULES,
    "",
    "---",
    "file: " .. (meta.path ~= "" and meta.path or "(unnamed buffer)"),
    "filetype: " .. (meta.filetype ~= "" and meta.filetype or "(none)"),
    string.format("cursor: line %d, column %d (of %d lines)", meta.cursor_line, meta.cursor_col + 1, meta.line_count),
  }
  if meta.truncated then
    parts[#parts + 1] = string.format(
      "note: the file is long; only lines %d-%d around the cursor are shown.",
      meta.window.first,
      meta.window.last
    )
  end
  parts[#parts + 1] = ""
  parts[#parts + 1] = "--- FILE (cursor marked with " .. CURSOR .. ") ---"
  parts[#parts + 1] = ctx.text
  parts[#parts + 1] = "--- END FILE ---"
  parts[#parts + 1] = ""

  if mode == "continue" then
    parts[#parts + 1] =
      "Task: continue the file from the cursor marker. Output only the text to insert at the cursor position.\n"
      .. "- do not repeat the text before the marker;\n"
      .. "- keep the same indentation as the surrounding code;\n"
      .. "- the editor decides where the text goes, so do not add leading or trailing blank lines."
  else
    parts[#parts + 1] = "Question: " .. (question or "")
    parts[#parts + 1] = ""
    parts[#parts + 1] =
      "Task: answer the question above about the file. The answer is inserted into the file as a comment block, so output only "
      .. "the answer content: no markdown fences, no \"Answer:\" prefix, no restating the question. If the answer needs code, "
      .. "output the code."
  end

  return table.concat(parts, "\n")
end

--------------------------------------------------------------------------
-- model call
--------------------------------------------------------------------------

--- Run the one-shot `pi -p` call. The prompt goes in through stdin so a big
--- buffer never hits the argv size limit.
--- @param prompt string
--- @param cb fun(res: table)
local function run_model(prompt, cb)
  local cfg = require("pi-chat").config
  local cmd = {
    cfg.pi_bin or "pi",
    "-p",
    "--no-tools",
    "--no-extensions",
    "--no-skills",
    "--no-session",
  }
  local model = M.config.model or cfg.model
  local provider = M.config.provider or cfg.provider
  if model then
    vim.list_extend(cmd, { "--model", model })
  end
  if provider then
    vim.list_extend(cmd, { "--provider", provider })
  end
  if M.config.extra_args then
    vim.list_extend(cmd, M.config.extra_args)
  end

  local ok, err = pcall(function()
    vim.system(cmd, {
      stdin = prompt,
      text = true,
      cwd = cfg.cwd or vim.fn.getcwd(),
      timeout = M.config.timeout_ms,
    }, vim.schedule_wrap(cb))
  end)
  if not ok then
    vim.schedule(function()
      cb({ code = 127, stdout = "", stderr = tostring(err) })
    end)
  end
end

--------------------------------------------------------------------------
-- output parsing
--------------------------------------------------------------------------

--- Remove a wrapping markdown fence (```lang ... ```), keeping every other
--- line (a leading newline is meaningful: it means "insert on a new line").
local function strip_fences(body)
  local lines = vim.split(body, "\n", { plain = true })
  local first_i, last_i
  for i, l in ipairs(lines) do
    if l:match("%S") then
      first_i = i
      break
    end
  end
  for i = #lines, 1, -1 do
    if lines[i]:match("%S") then
      last_i = i
      break
    end
  end
  if first_i and lines[first_i]:match("^%s*```") then
    table.remove(lines, first_i)
  end
  if last_i and last_i ~= first_i and lines[last_i]:match("^%s*```%s*$") then
    table.remove(lines, last_i)
  end
  return table.concat(lines, "\n")
end

--- Pull the insertable content out of the model's answer.
--- @param text string
--- @return string|nil content, string|nil error, boolean incomplete
local function extract_block(text)
  if not text or text:match("^%s*$") then
    return nil, "模型没有返回内容"
  end
  local s = text:find(START, 1, true)
  if not s then
    return nil, "输出里没有 " .. START .. " 标记"
  end
  local e = text:find(FINISH, s + #START, true)
  local body
  local incomplete = false
  if e then
    body = text:sub(s + #START, e - 1)
  else
    body = text:sub(s + #START)
    incomplete = true
  end
  body = strip_fences(body)
  if body:match("^%s*$") then
    return nil, "模型返回的块是空的"
  end
  return body, nil, incomplete
end
--------------------------------------------------------------------------
-- insertion
--------------------------------------------------------------------------

--- Comment leader of the buffer's filetype ("-- ", "// ", "# " ...), or nil.
local function comment_leader(bufnr)
  if not M.config.comment_answers then
    return nil
  end
  local ft = vim.bo[bufnr].filetype
  if ft == "" or ft == "markdown" or ft == "text" or ft == "txt" or ft == "gitcommit" then
    return nil
  end
  local cs = vim.bo[bufnr].commentstring
  if not cs or cs == "" then
    return nil
  end
  local leader = cs:gsub("%%s%s*$", "")
  leader = leader:gsub("%%s$", "")
  if leader == "" then
    return nil
  end
  return leader
end

--- Highlight the inserted range.
local function highlight(bufnr, srow, scol, erow, ecol)
  vim.api.nvim_buf_set_extmark(bufnr, ns, srow, scol, {
    end_row = erow,
    end_col = ecol,
    hl_group = "PiChatEdit",
    hl_eol = true,
    right_gravity = false,
  })
end

--- Characters after which a line is clearly unfinished, so the answer belongs
--- on the SAME line (inline completion) instead of on a new one.
local INLINE_TAIL = {
  ["("] = true,
  ["["] = true,
  ["{"] = true,
  [","] = true,
  ["="] = true,
  ["+"] = true,
  ["-"] = true,
  ["*"] = true,
  ["/"] = true,
  ["%"] = true,
  ["."] = true,
  [":"] = true,
  ["<"] = true,
  [">"] = true,
  ["&"] = true,
  ["|"] = true,
  ["!"] = true,
  ["?"] = true,
}

--- Does the text before the cursor ask for an inline continuation?
--- @param prefix string
--- @return boolean
local function wants_inline(prefix)
  local t = prefix:gsub("%s+$", "")
  if t == "" then
    return true -- nothing meaningful before the cursor
  end
  return INLINE_TAIL[t:sub(-1)] == true
end

--- Shift the whole block so its first line matches the indentation of the
--- line the cursor is on. Models regularly drop the leading indentation; a
--- closing line (end, }, ...) is left alone.
--- @param content string
--- @param base_indent string
--- @return string
local function reindent(content, base_indent)
  if base_indent == "" then
    return content
  end
  local lines = vim.split(content, "\n", { plain = true })
  local fi
  for i, l in ipairs(lines) do
    if l:match("%S") then
      fi = i
      break
    end
  end
  if not fi then
    return content
  end
  local first = lines[fi]
  if (first:match("^[ \t]*") or "") ~= "" then
    return content -- the model already indented it
  end
  if is_dedent_line(first) then
    return content
  end
  for i, l in ipairs(lines) do
    if l:match("%S") then
      lines[i] = base_indent .. l
    end
  end
  return table.concat(lines, "\n")
end

--- Insert the model's text at the cursor.
--- @param bufnr integer
--- @param row integer  cursor line (1-based)
--- @param col integer  cursor column (0-based byte offset)
--- @param text string  the text to insert (already trimmed / re-indented)
--- @param mode string  "fill" (the line is blank) | "inline" | "below"
--- @return integer number of lines touched
local function insert_content(bufnr, row, col, text, mode)
  local r0 = row - 1
  local cur = vim.api.nvim_buf_get_lines(bufnr, r0, r0 + 1, false)[1] or ""
  local parts = vim.split(text, "\n", { plain = true })

  if mode == "fill" or mode == "below" then
    -- "fill": the current line is blank, the text takes its place.
    -- "below": the text goes on new lines under the current one.
    local at = mode == "fill" and r0 or (r0 + 1)
    vim.api.nvim_buf_set_lines(bufnr, at, at + (mode == "fill" and 1 or 0), false, parts)
    highlight(bufnr, at, 0, at + #parts - 1, #parts[#parts])
    return #parts
  end

  -- Inline: the first line continues the current one, the rest are new lines
  -- and whatever was after the cursor moves to a line of its own.
  local prefix = cur:sub(1, col)
  local suffix = cur:sub(col + 1)
  local new_lines
  if #parts == 1 then
    new_lines = { prefix .. parts[1] .. suffix }
  else
    new_lines = { prefix .. parts[1] }
    for i = 2, #parts - 1 do
      new_lines[#new_lines + 1] = parts[i]
    end
    new_lines[#new_lines + 1] = parts[#parts] .. suffix
  end
  vim.api.nvim_buf_set_lines(bufnr, r0, r0 + 1, false, new_lines)
  local last = new_lines[#new_lines]
  highlight(bufnr, r0, col, r0 + #new_lines - 1, #last)
  return #new_lines
end
--------------------------------------------------------------------------
-- public entry points
--------------------------------------------------------------------------

--- Shared driver for both modes.
--- @param mode string  "continue" | "ask"
--- @param question string|nil
local function run(mode, question)
  if busy then
    vim.notify("pi-chat: 上一次编辑请求还在进行中", vim.log.levels.WARN)
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    vim.notify("pi-chat: 当前 buffer 不能编辑", vim.log.levels.WARN)
    return
  end

  local ok, ctx = pcall(collect_context, bufnr)
  if not ok then
    vim.notify("pi-chat: 收集上下文失败: " .. tostring(ctx), vim.log.levels.ERROR)
    return
  end
  local ok2, prompt = pcall(build_prompt, mode, question, ctx)
  if not ok2 then
    vim.notify("pi-chat: 构造 prompt 失败: " .. tostring(prompt), vim.log.levels.ERROR)
    return
  end
  busy = true
  vim.notify("pi-chat: 正在生成…", vim.log.levels.INFO)

  run_model(prompt, function(res)
    busy = false
    if res.code ~= 0 then
      local err = (res.stderr or ""):gsub("%s+$", "")
      vim.notify("pi-chat: 模型调用失败 (" .. tostring(res.code) .. ") " .. err, vim.log.levels.ERROR)
      return
    end
    local content, err, incomplete = extract_block(res.stdout)
    if vim.env.PI_CHAT_EDIT_DEBUG then
      vim.notify("[pi-chat edit] raw: " .. vim.inspect(res.stdout), vim.log.levels.INFO)
    end
    if not content then
      vim.notify("pi-chat: " .. tostring(err) .. "（未插入任何内容）", vim.log.levels.ERROR)
      return
    end

    -- The buffer may have changed while the model was thinking.
    if not vim.api.nvim_buf_is_valid(bufnr) then
      vim.notify("pi-chat: buffer 已关闭，未插入", vim.log.levels.WARN)
      return
    end
    local win = vim.fn.bufwinid(bufnr)
    local row, col = ctx.meta.cursor_line, ctx.meta.cursor_col
    if win > 0 then
      local c = vim.api.nvim_win_get_cursor(win)
      row, col = c[1], c[2]
    end

    local n
    if mode == "continue" then
      -- Trim, then let the plugin decide where the text goes: it fills a
      -- blank line, continues an unfinished line inline, or goes below the
      -- current line.
      local text = content:gsub("%s+$", "")
      if text == "" then
        vim.notify("pi-chat: 模型返回的块是空的", vim.log.levels.ERROR)
        return
      end
      text = text:gsub("^\n", "")
      local cur_line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
      local prefix = cur_line:sub(1, col)
      local suffix = cur_line:sub(col + 1)
      local place
      if cur_line:match("^%s*$") then
        place = "fill" -- the current line is blank: the text fills it
      elseif wants_inline(prefix) and not (prefix:match("^%s*$") and suffix:gsub("%s+$", "") ~= "") then
        place = "inline" -- the line is unfinished: continue on the same line
      else
        place = "below" -- the text goes on new lines under the current one
      end
      if place ~= "inline" then
        text = reindent(text, ctx.meta.base_indent or "")
      end
      n = insert_content(bufnr, row, col, text, place)
    else
      local lines = vim.split(content, "\n", { plain = true })
      while #lines > 0 and lines[1]:match("^%s*$") do
        table.remove(lines, 1)
      end
      while #lines > 0 and lines[#lines]:match("^%s*$") do
        table.remove(lines, #lines)
      end
      local leader = comment_leader(bufnr)
      if leader then
        local pat = "^%s*" .. vim.pesc(leader)
        for i, l in ipairs(lines) do
          if l:match("^%s*$") then
            lines[i] = ""
          elseif l:match(pat) then
            lines[i] = l -- the model already wrote it as a comment
          else
            lines[i] = leader .. l
          end
        end
      end
      n = insert_block(bufnr, row, lines)
    end
    if win > 0 then
      pcall(vim.api.nvim_win_set_cursor, win, { row, col })
    end
    vim.notify(string.format("pi-chat: 已插入 %d 行", n), vim.log.levels.INFO)
    if incomplete then
      vim.notify("pi-chat: 模型没有输出结束标记 " .. FINISH .. "，已按剩余内容插入", vim.log.levels.WARN)
    end
  end)
end

--- Continue the file at the cursor (no question needed).
function M.continue()
  run("continue", nil)
end

--- Ask a question about the buffer and insert the answer.
function M.ask()
  vim.ui.input({ prompt = "pi 问题: " }, function(q)
    if not q or q == "" then
      return
    end
    run("ask", q)
  end)
end

return M
