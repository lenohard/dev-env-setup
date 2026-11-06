-- pi-chat.nvim :: image support
--
-- Two directions, both zero-dependency beyond macOS `pngpaste` + `base64`:
--   * paste  : grab a clipboard image -> base64 -> pi `images` payload
--   * display: save a tool-result image to a temp PNG, offer to `open` it
--
-- We deliberately do NOT render images inline (that needs a terminal graphics
-- protocol and breaks under tmux). `open` uses Preview.app, which is crisp and
-- works everywhere (tmux, ghostty, neovide).

local M = {}

local CACHE_DIR = vim.fn.stdpath("cache") .. "/pi-chat-images"

local function ensure_cache_dir()
  vim.fn.mkdir(CACHE_DIR, "p")
end

--- Grab the current clipboard image into a temp PNG.
--- Tries pngpaste first; falls back to osascript reading «class PNGf» directly
--- (pngpaste 0.2.x hits CGImageDestinationFinalize failures on recent macOS).
--- @return string|nil path, string|nil err
function M.clipboard_to_png()
  ensure_cache_dir()
  local path = string.format("%s/paste-%s.png", CACHE_DIR, os.time())

  -- Attempt 1: pngpaste (handles more source formats when it works).
  if vim.fn.executable("pngpaste") == 1 then
    vim.fn.system({ "pngpaste", path })
    if vim.v.shell_error == 0 and vim.fn.filereadable(path) == 1 and vim.fn.getfsize(path) > 0 then
      return path, nil
    end
  end

  -- Attempt 2 (macOS fallback): read the PNG flavor straight from the pasteboard
  -- via osascript. Works even when pngpaste's CGImageDestination fails.
  if vim.fn.has("mac") == 1 then
    local script = table.concat({
      "set pngData to the clipboard as «class PNGf»",
      string.format("set fp to open for access POSIX file %q with write permission", path),
      "set eof fp to 0",
      "write pngData to fp",
      "close access fp",
    }, "\n")
    vim.fn.system({ "osascript", "-e", script })
    if vim.v.shell_error == 0 and vim.fn.filereadable(path) == 1 and vim.fn.getfsize(path) > 0 then
      return path, nil
    end
  end

  return nil, "no image in clipboard"
end

--- Read a PNG file into a base64 string (no newlines).
--- @return string|nil b64, string|nil err
function M.file_to_base64(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "file not readable: " .. path
  end
  -- `base64 -i <file>` on macOS; strip newlines for a clean payload.
  local out = vim.fn.system({ "base64", "-i", path })
  if vim.v.shell_error ~= 0 then
    return nil, "base64 failed"
  end
  return (out:gsub("%s", "")), nil
end

--- Build a pi ImageContent object from a clipboard image.
--- @return table|nil image  { type="image", data=<b64>, mimeType="image/png", _path=<path> }
--- @return string|nil err
function M.clipboard_image_content()
  local path, err = M.clipboard_to_png()
  if not path then
    return nil, err
  end
  local b64, berr = M.file_to_base64(path)
  if not b64 then
    return nil, berr
  end
  return { type = "image", data = b64, mimeType = "image/png", _path = path }, nil
end

--- Write base64 image data from a tool result to a temp PNG.
--- @param data string  base64
--- @param mime string|nil  e.g. "image/png"
--- @return string|nil path
function M.save_result_image(data, mime)
  ensure_cache_dir()
  local ext = "png"
  if mime then
    local m = mime:match("image/(%w+)")
    if m then
      ext = m == "jpeg" and "jpg" or m
    end
  end
  local path = string.format("%s/result-%s.%s", CACHE_DIR, os.time() .. "-" .. math.random(1000, 9999), ext)
  local decoded
  local ok = pcall(function()
    decoded = vim.base64.decode(data)
  end)
  if not ok or not decoded then
    return nil
  end
  local f = io.open(path, "wb")
  if not f then
    return nil
  end
  f:write(decoded)
  f:close()
  return path
end

--- Open an image file with the system default viewer (macOS `open`).
function M.open_external(path)
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("pi-chat: image not found: " .. path, vim.log.levels.WARN)
    return
  end
  local opener = vim.fn.has("mac") == 1 and "open" or "xdg-open"
  vim.fn.jobstart({ opener, path }, { detach = true })
end

return M
