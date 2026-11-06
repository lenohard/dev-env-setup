-- Path: .hammerspoon/init.lua
-- load spoons
-- Load Hammerspoon extensions

local deleteAppModule = require("delete_app")
local utils = require("utils")
-- local launchApplications = require("launchApplications") -- or Webpages
-- local switchApplications = require("switchApplications")

cutFilePath = os.getenv("HOME") .. "/.config"

hs.loadSpoon("SpoonInstall")
spoon.SpoonInstall.use_syncinstall = true

-------- alert style --------
hs.alert.defaultStyle.strokeColor = { white = 1, alpha = 0 }
hs.alert.defaultStyle.fillColor = { white = 0.05, alpha = 0.75 }
hs.alert.defaultStyle.textColor = { white = 1 }
hs.alert.defaultStyle.radius = 10
hs.alert.defaultStyle.textFont = "Helvetica"
-- border
hs.alert.defaultStyle.strokeWidth = 1
hs.alert.defaultStyle.strokeColor = { white = 1, alpha = 0.5 }
hs.alert.defaultStyle.atScreenEdge = 0
-------- alert style end --------

-- -------- bind ctrl+option+g for tab1 in Brave --------
-- hs.hotkey.bind({ "ctrl", "option" }, "g", function()
-- 	-- if it's alrady in the foreground, just switch to tab 1
-- 	if hs.application.frontmostApplication():name() == "Brave Browser" then
-- 		hs.eventtap.keyStroke({ "cmd" }, "1")
-- 		return
-- 	else
-- 		hs.application.launchOrFocus("Brave Browser")
-- 		-- and switch to the first tab
-- 		hs.eventtap.keyStroke({ "cmd" }, "1")
-- 	end
-- end)
-- -------- bind ctrl+option+g for tab1 in safari end --------

local function bind_toggle_application_hotkey(modifier, key, app_name)
	hs.hotkey.bind(modifier, key, function()
		utils.toggle_application(app_name)
		moveCursorToFocusedApp()

		-- Check if there is more than one monitor
		local screens = hs.screen.allScreens()
		if #screens > 1 then
			-- Show a message
			hs.alert.show(app_name)
		end
	end)
end

-- bind_toggle_application_hotkey({"option", "ctrl"},"o", "Firefox")
bind_toggle_application_hotkey({ "option", "ctrl" }, "r", "company.thebrowser.Browser")
-- firefox Browser
-- bind_toggle_application_hotkey({"option", "ctrl"},"x", "firefox")
-- bind_toggle_application_hotkey({"option", "ctrl"},"g", "com.apple.Safari.WebApp.CFD1BDC5-D061-4FCD-9D2D-82D7A861C19F")
-- activity monitor
-- bind_toggle_application_hotkey({ "option", "ctrl" }, "n", "com.apple.ActivityMonitor")
bind_toggle_application_hotkey({ "option", "ctrl" }, "t", "telegram")
bind_toggle_application_hotkey({ "option", "ctrl" }, "m", "com.swinsian.Swinsian")
bind_toggle_application_hotkey({"option", "ctrl"},"b", "dev.bb.desktop")
-- preview
bind_toggle_application_hotkey({ "option", "ctrl" }, "p", "com.apple.Preview")
-- finder
bind_toggle_application_hotkey({ "option", "ctrl" }, "f", "com.binarynights.ForkLift")

bind_toggle_application_hotkey({ "option", "ctrl" }, "j", "com.lobehub.lobehub-desktop")
-- macvim
-- bind_toggle_application_hotkey({"option", "ctrl"},"v", "org.vim.MacVim")
-- wechat
bind_toggle_application_hotkey({ "option", "ctrl" }, "w", "com.tencent.xinWeChat")
-- vscode
bind_toggle_application_hotkey({ "option", "ctrl" }, "o", "com.microsoft.VSCode")
bind_toggle_application_hotkey({ "option", "ctrl" }, "e", "com.google.antigravity")

-- signal
-- bind_toggle_application_hotkey({"option", "ctrl"},";", "com.yida.chatgpt.next.web")
-- bind_toggle_application_hotkey({ "option", "ctrl" }, "l", "co.podzim.BoltGPT")
-- matlab
-- bind_toggle_application_hotkey({"option", "ctrl"},"a", "com.mathworks.matlab")
------- bind hotkey to toggle applications end -------
bind_toggle_application_hotkey({ "option", "ctrl" }, "c", "com.apple.ScreenContinuity")
-- bind to 小米办公
bind_toggle_application_hotkey({ "option", "ctrl" }, "x", "com.electron.lark")
-- bind Xcode
bind_toggle_application_hotkey({ "ctrl" }, "'", "com.mitchellh.ghostty")
bind_toggle_application_hotkey({"option", "ctrl"},"b", "dev.bb.desktop")
bind_toggle_application_hotkey({ "option", "ctrl" }, "g", "com.openai.codex")
-- bind_toggle_application_hotkey({ "option", "ctrl" }, "h", "com.kangfenmao.CherryStudio")
bind_toggle_application_hotkey({ "option", "ctrl" }, "h", "com.wefonk.deepchat")
bind_toggle_application_hotkey({ "option", "ctrl" }, "k", "com.bilingify.readest")
-- bind spacemacs
bind_toggle_application_hotkey({ "option", "ctrl" }, "s", "org.gnu.Emacs")
-- bind apifox
bind_toggle_application_hotkey({ "option", "ctrl" }, "q", "com.postmanlabs.mac")
bind_toggle_application_hotkey({ "option", "ctrl" }, "y", "com.pranapps.ByteHackerNews")
-- iterm2
-- bind_toggle_application_hotkey({ "ctrl" }, "'", "com.googlecode.iterm2")
-- Notion
bind_toggle_application_hotkey({ "ctrl" }, ".", "md.obsidian")

bind_toggle_application_hotkey({ "option", "ctrl" }, "a", "imagetasks.iStatistica-Pro")
-- Warp terminal
bind_toggle_application_hotkey({ "option", "ctrl" }, "z", "dev.warp.Warp-Stable")
bind_toggle_application_hotkey({ "option", "ctrl" }, "v", "dev.commandline.waveterm")
bind_toggle_application_hotkey({ "option", "ctrl" }, "d", "com.lenohard.corner")

-- Define a function to create the hotkey binding
function createToggleShortcut(shortcutModifiers, shortcutKey, firstAppBundleId, secondAppBundleId)
	hs.hotkey.bind(shortcutModifiers, shortcutKey, function()
		local app = hs.application.frontmostApplication()
		local bundleId = app:bundleID()
		-- log the bundleId
		print(bundleId)
		if bundleId == firstAppBundleId then
			utils.toggle_application(secondAppBundleId)
			print("switch to " .. secondAppBundleId)
		elseif bundleId == secondAppBundleId then
			utils.toggle_application(firstAppBundleId)
			print("switch to " .. firstAppBundleId)
		else
			utils.toggle_application(secondAppBundleId)
		end
	end)
end

hs.hotkey.bind({ "ctrl", "cmd" }, "s", function()
	hs.osascript.applescript([[
        tell application "System Settings"
            activate
            delay 0.5
            do shell script "open x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        end tell
    ]])
end)

hs.hotkey.bind({ "cmd", "alt", "ctrl" }, "W", function()
	hs.alert.show("Hammerspoon, at your service.")
end)

-- quick delete a application
hs.hotkey.bind({ "cmd", "alt", "ctrl" }, "D", function()
	deleteAppModule.appChooser:choices(deleteAppModule.appList())
	deleteAppModule.appChooser:show()
end)

-- reload config manually
hs.hotkey.bind({ "cmd", "alt", "ctrl" }, "R", function()
	hs.reload()
end)

-- open hammerspoon console, binding to cmd+alt+ctrl+h
hs.hotkey.bind({ "cmd", "alt", "ctrl" }, "0", function()
    hs.toggleConsole()
end)

-- Show the bundle ID of the frontmost application
hs.hotkey.bind({ "cmd", "alt", "ctrl" }, "B", function()
    local app = hs.application.frontmostApplication()
    if app then
        local bid = app:bundleID() or "Unknown bundle ID"
        hs.pasteboard.setContents(bid)
        hs.alert.show("Bundle ID copied: " .. bid)
    else
        hs.alert.show("No frontmost application")
    end
end)

-- Define a global variable to hold the watcher object.
configWatcher = nil

-- Define a function to reload the configuration.
function reloadConfig()
	hs.reload()
end

-- -- Watch the ~/.hammerspoon/ directory and ~/.hammerspoon/init.lua file for changes.
configWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", reloadConfig):start()
hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/init.lua", reloadConfig):start()

hs.alert.show("Config loaded")

-- hs.hotkey.bind({ "alt", "ctrl" }, "space", function()
-- 	utils.newWindow()
-- end)

-- -- weixin mini program has a issue that sometimes it can't fully show unless refocus
-- hs.hotkey.bind({ "alt", "ctrl" }, "/", function()
-- 	utils.refocus()
-- end)

-- bind cmd+option+. to  get the current selection text  in the frontmost application and print
function getSelectedText()
	currentClipboard = hs.pasteboard.getContents()
	-- Copy the selected text to the system clipboard.
	hs.eventtap.keyStroke({ "cmd" }, "c", 0)
	hs.timer.waitUntil(function()
		return hs.pasteboard.getContents() ~= currentClipboard
	end, function()
		-- Get the selected text from the system clipboard.
		local selectedText = hs.pasteboard.getContents()
		-- insert Uppercase Case of the selected text
		insertText(string.upper(selectedText))
	end, 0.1)
end

-- insert some text into the frontmost application
function insertText(text)
	print("insert text: " .. text)
	-- Copy the selected text to the system clipboard.
	hs.pasteboard.setContents(text)
	hs.eventtap.keyStroke({ "cmd" }, "v", 0)
end

-- Bind "cmd+option+." to copySelectedText function.
hs.hotkey.bind({ "cmd", "alt" }, ".", getSelectedText)

-- Bind alt+cmd+ctrl c to clean the trash bin
-- using applescript to empty trash bin
hs.hotkey.bind({ "alt", "cmd", "ctrl" }, "c", function()
	-- Compute the files count
	local count, count_err = hs.execute("osascript -e 'tell application \"Finder\" to get count of items in trash'")
	if count_err then
		-- Empty the trash
		hs.execute("osascript -e 'tell application \"Finder\" to empty trash'")

		-- Compute the freed space after emptying the trash
		local space_after, _ =
			hs.execute("osascript -e 'tell application \"Finder\" to get the free space of the (startup disk)'")
		space_after = tonumber(space_after)

		local space_gb = space_after / 1024 / 1024 / 1024

		-- Remove the newline character from the count
		count = count:gsub("\n", "")

		-- Show the notification
		hs.alert.show(count .. " files cleaned, remaning free space " .. string.format("%.2f", space_gb) .. " GB ")
	else
		-- Show an error notification if there's an issue with the script
		hs.alert.show("Error: Unable to clean the trash")
	end
end)

-- copy the path of the file selected in Finder
hs.hotkey.bind({ "alt", "cmd", "ctrl" }, "p", function()
	local app = hs.application.frontmostApplication()
	local bundleId = app and app:bundleID() or ""
	if bundleId ~= "com.apple.finder" then
		print("not in Finder")
		return
	end

	local ok, path = hs.osascript.applescript([[
tell application "Finder"
	set sel to selection
	if sel is {} then return ""

	set paths to {}
	repeat with i in sel
		set end of paths to POSIX path of (i as alias)
	end repeat

	set oldDelims to AppleScript's text item delimiters
	set AppleScript's text item delimiters to ","
	set outText to paths as text
	set AppleScript's text item delimiters to oldDelims
	return outText
end tell
]])

	if not ok then
		hs.alert.show("Error: Unable to get selection paths")
		return
	end

	path = tostring(path or ""):gsub("\n", "")
	if path == "" then
		print("No file selected")
		return
	end
	hs.pasteboard.setContents(path)
	hs.alert.show("Path copied")
end)

-- -- use ctrl+8 to connect bluetooth device with name "black crown"
-- hs.hotkey.bind({ "ctrl" }, "8", function()
--   hs.execute("/opt/hombrew/bin/SwitchAudioSource -s 'black crown'")
-- end)

function openWithEbookViewer()
	local file = utils.getSelectedFile()
	-- print the file path in the console
	print(file)
	if file ~= "" then
		-- open file using ebook-viewer

		os.execute("/Applications/calibre.app/Contents/MacOS/ebook-viewer '" .. file .. "' &")
	end
end

hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "e", openWithEbookViewer)

function lookupSelectionAndSave()
	local script = [[
    set theText to do shell script "osascript /Users/senaca/local/GetSelectedText.scpt"
    if theText is not "" then
        do shell script "open dict://" & quoted form of theText
		do shell script "/Users/senaca/local/save.sh " & quoted form of theText
    end if
    ]]
	hs.osascript.applescript(script)
end

-- hs.hotkey.bind({ "ctrl" }, "g", lookupSelectionAndSave)

function copyAndStripNewlines()
	-- AppleScript to get the selected text
	local script = [[
    set theText to do shell script "osascript /Users/senaca/local/GetSelectedText.scpt"
    if theText is not "" then
        return theText
    end if
    ]]

	-- Execute AppleScript and capture output
	local success, selectedText = hs.osascript.applescript(script)

	if success then
		selectedText = selectedText:gsub("\r\n", " "):gsub("\n", " "):gsub("\r", " "):gsub("- ", "")
		hs.pasteboard.setContents(selectedText)
		hs.alert.show("newlines removed")
	else
		print("AppleScript did not execute successfully.")
	end
end

function copyAndStripBlankLines()
	-- AppleScript to get the selected text
	local script = [[
	set theText to do shell script "osascript /Users/senaca/local/GetSelectedText.scpt"
	if theText is not "" then
		return theText
	end if
	]]

	-- Execute AppleScript and capture output
	local success, selectedText = hs.osascript.applescript(script)

	if success then
		selectedText = selectedText:gsub("\r\n", "\n\n"):gsub("\n\n\n", "\n\n")
		hs.pasteboard.setContents(selectedText)
		hs.alert.show("blank lines removed")
	else
		print("AppleScript did not execute successfully.")
	end
end

hs.hotkey.bind({ "ctrl", "cmd" }, "c", copyAndStripNewlines)
hs.hotkey.bind({ "ctrl", "cmd" }, "b", copyAndStripBlankLines)

--  using shift+ctrl+T to download twitter video
hs.hotkey.bind({ "shift", "ctrl" }, "T", function()
	local pasteboardContent = hs.pasteboard.getContents()

	-- Check if the clipboard content is a Twitter URL.
	if string.match(pasteboardContent, "https?://twitter%.com/.+/status/%d+") then
		local downloadPath = "~/everything/videos"
		-- use date+time as the file name
		local filename = os.date("%Y-%m-%d_%H-%M-%S") .. ".mp4"
		local videoPath = downloadPath .. "/" .. filename

		-- Use YT-DLP to download the video.
		local command = "/usr/local/bin/yt-dlp --output "
			.. videoPath
			.. " --format bestvideo+bestaudio "
			.. pasteboardContent
		local handle = io.popen(command)
		local result = handle:read("*a")
		local _, _, exitcode = handle:close()

		if exitcode == 0 then
			-- Show a notification.
			local notification = hs.notify
				.new({
					title = "Video Downloaded",
					informativeText = "The Twitter video has been downloaded.",
					actionButtonTitle = "Open",
					hasActionButton = true,
					autoWithdraw = false,
					withdrawAfter = 0,
				})
				:send()

			-- Open the video in Finder when the notification is clicked.
			notification:withdraw()
			notification:setCallback(function(actionType)
				if actionType == hs.notify.activationTypes.actionButtonClicked then
					hs.execute("open " .. downloadPath)
				end
			end)
			notification:send()
		else
			hs.notify.show("Error", "Failed to download the Twitter video.", "")
		end
	else
		hs.notify.show("Error", "The clipboard does not contain a valid Twitter URL.", "")
	end
end)

function gpt_bind(hotkey, tag)
	hs.hotkey.bind({ "shift", "cmd" }, hotkey, function()
		-- Copy the selected text to the clipboard
		hs.eventtap.keyStroke({ "cmd" }, "c")

		-- Small delay to ensure the clipboard has been updated
		hs.timer.doAfter(0.1, function()
			local clipboardContents = hs.pasteboard.getContents()
			print(clipboardContents)

			-- Check if the clipboard is not empty
			if clipboardContents then
				-- Pass the clipboard contents to the Python script
				local scriptPath = "/Users/senaca/code/macOS-alert/gpt.py"
				local command = string.format("%s --tag %s --input '%s'", scriptPath, tag, clipboardContents)
				local output, status, type, rc = hs.execute(command, true)
				hs.pasteboard.setContents(output)
			end
		end)
	end)
end

-- gpt_bind("t", "translate")
-- gpt_bind("c", "correct")
-- gpt_bind("d", "command")

-- hs.hotkey.bind({ "ctrl" }, "7", function()
-- 	-- Check if any media player is active
-- 	local playerState = hs.audiodevice.defaultOutputDevice():currentOutputDataSource()
-- 	if playerState and playerState:matchedMetadata().kMDItemContentType == "com.apple.coreaudio-format" then
-- 		-- If a player is active, send the play/pause command
-- 		hs.eventtap.event.newSystemKeyEvent("PLAY", true):post()
-- 		hs.eventtap.event.newSystemKeyEvent("PLAY", false):post()
-- 	else
-- 		-- If no player is active, control the Music app
-- 		local musicApp = hs.application.find("com.apple.Music")
-- 		if musicApp then
-- 			hs.osascript.applescript('tell application "Music" to playpause')
-- 		else
-- 			utils.toggle_application("com.apple.Music")
-- 		end
-- 	end
-- end)

-- hs.hotkey.bind({ "ctrl" }, "\\", function()
-- 	local musicApp = hs.application.find("com.apple.Music")
-- 	if musicApp then
-- 		hs.osascript.applescript('tell application "Music" to next track')
-- 	else
-- 		-- Send system-wide next track key
-- 		hs.eventtap.event.newSystemKeyEvent("NEXT", true):post()
-- 		hs.eventtap.event.newSystemKeyEvent("NEXT", false):post()
-- 	end
-- end)

-- hs.hotkey.bind({ "ctrl" }, "/", function()
-- 	local musicApp = hs.application.find("com.apple.Music")
-- 	if musicApp then
-- 		hs.osascript.applescript('tell application "Music" to previous track')
-- 	else
-- 		-- Send system-wide previous track key
-- 		hs.eventtap.event.newSystemKeyEvent("PREVIOUS", true):post()
-- 		hs.eventtap.event.newSystemKeyEvent("PREVIOUS", false):post()
-- 	end
-- end)

hs.hotkey.bind({ "ctrl" }, "-", function()
	-- run: /opt/homebrew/bin/SwitchAudioSource -s 'MacBook Pro扬声器'
	hs.execute("/opt/homebrew/bin/SwitchAudioSource -s 'MacBook Pro扬声器'")
	hs.alert("MacBook Internal Speaker Switched")
end)

local function convertPath(macPath)
	local parts = hs.fnutils.split(macPath, ":")
	if #parts > 0 then
		parts[1] = "" -- Remove the "Macintosh HD" part
		return "/" .. table.concat(parts, "/")
	else
		return macPath
	end
end

hs.hotkey.bind({ "option", "cmd" }, "H", function()
	local image = hs.pasteboard.readImage()
	if image then
		local applescript = [[
            tell application "Finder"
				activate
                set theDialog to choose file name with prompt "Select where to save the image"
            end tell
        ]]

		local status, result = hs.osascript.applescript(applescript)
		if status then
			local unixFilePath = convertPath(result)
			local saved = image:saveToFile(unixFilePath)
			if saved then
				hs.alert.show("Image saved: " .. unixFilePath)
			else
				hs.alert.show("Failed to save image")
			end
		else
			hs.alert.show("Dialog cancelled or error occurred")
		end
	else
		hs.alert.show("No image in clipboard")
	end
end)

-- -- Function to check if the clipboard content is an SVG tag and save it as an SVG file
-- function saveClipboardAsSVG()
-- 	-- Get the clipboard content
-- 	local clipboardContent = hs.pasteboard.getContents()

-- 	-- Check if the clipboard content contains an SVG tag
-- 	if clipboardContent and clipboardContent:match("<svg") and clipboardContent:match("</svg>") then
-- 		-- Open a file save dialog to select the save path
-- 		local savePath =
-- 			hs.dialog.chooseFileOrFolder("Select save location", "~/Desktop", false, true, false, { "public.folder" })

-- 		if savePath then
-- 			-- Get the selected folder path
-- 			local folderPath = savePath["1"]
-- 			-- Define the file name
-- 			local fileName = "clipboard_image.svg"
-- 			-- Full path to save the file
-- 			local fullPath = folderPath .. "/" .. fileName

-- 			-- Write the SVG content to the file
-- 			local file = io.open(fullPath, "w")
-- 			if file then
-- 				file:write(clipboardContent)
-- 				file:close()
-- 				-- Notify the user
-- 				hs.notify.new({ title = "Hammerspoon", informativeText = "SVG file saved to " .. fullPath }):send()
-- 			else
-- 				hs.notify.new({ title = "Hammerspoon", informativeText = "Failed to save SVG file" }):send()
-- 			end
-- 		end
-- 	else
-- 		hs.notify
-- 			.new({ title = "Hammerspoon", informativeText = "Clipboard does not contain valid SVG content" })
-- 			:send()
-- 	end
-- end

-- hs.hotkey.bind({ "cmd", "option" }, "h", saveClipboardAsSVG)

-- format json string in pretty format
hs.hotkey.bind({ "ctrl", "cmd" }, "j", function()
	-- Copy selected text first
	local currentClipboard = hs.pasteboard.getContents()
	hs.eventtap.keyStroke({ "cmd" }, "c")
	-- Wait a bit for clipboard to update
	hs.timer.doAfter(0.1, function()
		local selectedText = hs.pasteboard.getContents()
		local json_data, err = hs.json.decode(selectedText)
		if not json_data then
			hs.alert.show("Not a valid JSON string: " .. (err or "unknown error"))
			-- Restore original clipboard if decoding failed
			hs.pasteboard.setContents(currentClipboard)
			return
		end
		local formatted_json = hs.json.encode_pretty(json_data)
		hs.pasteboard.setContents(formatted_json)
		hs.eventtap.keyStroke({ "cmd" }, "v")
		hs.alert.show("Formatted JSON")
		-- Restore original clipboard after pasting
		hs.timer.doAfter(0.1, function() hs.pasteboard.setContents(currentClipboard) end)
	end)
end)

-- Function to count characters in selected text
function countSelectedText()
	-- Get the current clipboard contents to restore later
	local currentClipboard = hs.pasteboard.getContents()
	
	-- Copy the selected text to clipboard
	hs.eventtap.keyStroke({ "cmd" }, "c")
	
	-- Wait a bit for clipboard to update
	hs.timer.doAfter(0.1, function()
		-- Get the selected text from clipboard
		local selectedText = hs.pasteboard.getContents()
		
		if selectedText then
			-- Count characters (including spaces)
			local charCount = string.len(selectedText)
			
			-- Count characters (excluding spaces)
			local noSpaceText = selectedText:gsub("%s+", "")
			local noSpaceCount = string.len(noSpaceText)
			
			-- Count words
			local wordCount = 0
			if selectedText ~= "" then
				wordCount = select(2, selectedText:gsub("%S+", ""))
			end
			
			-- Show the counts in an alert
			hs.alert.show("Characters: " .. charCount .. " | No spaces: " .. noSpaceCount .. " | Words: " .. wordCount)
		else
			hs.alert.show("No text selected")
		end
		
		-- Restore original clipboard contents
		if currentClipboard then
			hs.pasteboard.setContents(currentClipboard)
		end
	end)
end

-- Bind alt+cmd+c to count selected text
hs.hotkey.bind({ "alt", "cmd" }, "c", countSelectedText)

function moveCursorToFocusedApp()
	local focusedApp = hs.application.frontmostApplication()
	local focusedWindow = focusedApp:focusedWindow()
	if focusedWindow then
		local windowFrame = focusedWindow:frame()
		local screen = focusedWindow:screen()
		local screenFrame = screen:frame()

		-- Get current mouse position
		local currentPos = hs.mouse.getAbsolutePosition()

		-- Check if the cursor is already within the window bounds
		if
			not (
				currentPos.x >= windowFrame.x
				and currentPos.x <= windowFrame.x + windowFrame.w
				and currentPos.y >= windowFrame.y
				and currentPos.y <= windowFrame.y + windowFrame.h
			)
		then
			-- Calculate relative position within the screen
			local relativeX = windowFrame.x - screenFrame.x + windowFrame.w / 2
			local relativeY = windowFrame.y - screenFrame.y + windowFrame.h / 2

			hs.mouse.setRelativePosition({ x = relativeX, y = relativeY }, screen)
		end
	end
end

hs.hotkey.bind({ "cmd", "ctrl" }, "F", moveCursorToFocusedApp)

function switchToOtherMonitor()
	-- log
	print("switchToOtherMonitor")
	local currentWindow = hs.window.focusedWindow()
	if not currentWindow then
		return
	end

	local currentScreen = currentWindow:screen()
	local allScreens = hs.screen.allScreens()
	--log
	print(allScreens)

	-- Find the other screen directly
	local otherScreen = allScreens[currentScreen == allScreens[1] and 2 or 1]
	--log
	print(otherScreen)

	if otherScreen then
		-- Get the topmost window on the other screen
		local topmostWindow = hs.fnutils.find(hs.window.orderedWindows(), function(win)
			return win:screen() == otherScreen
		end)
		print(topmostWindow)

		if topmostWindow then
			topmostWindow:focus()
			hs.mouse.absolutePosition(topmostWindow:frame().center)
		end
		print("switched to other screen")
	end
end

-- Bind the function to a hotkey
hs.hotkey.bind({ "ctrl" }, "/", switchToOtherMonitor)

local function moveCursorWithPadding(edge)
	local screenFrame = hs.screen.mainScreen():fullFrame()
	local padding = 0.05

	local newX, newY
	local currentX, currentY = hs.mouse.getAbsolutePosition().x, hs.mouse.getAbsolutePosition().y

	if edge == "left" then
		newX = screenFrame.x + screenFrame.w * padding
		-- newY = hs.mouse.getCurrentScreen():fullFrame().h / 2 -- Center vertically
		newY = currentY
	elseif edge == "up" then
		-- newX = hs.mouse.getCurrentScreen():fullFrame().w / 2 -- Center horizontally
		newY = screenFrame.y + screenFrame.h * padding
		newX = currentX
	elseif edge == "down" then
		-- newX = hs.mouse.getCurrentScreen():fullFrame().w / 2 -- Center horizontally
		newY = screenFrame.y + screenFrame.h * (1 - padding)
		newX = currentX
	elseif edge == "right" then
		newX = screenFrame.x + screenFrame.w * (1 - padding)
		newY = currentY
	end

	hs.mouse.setAbsolutePosition({ x = newX, y = newY })
end

-- -- Bind the hotkeys
-- hs.hotkey.bind({ "cmd" }, "H", function()
-- 	moveCursorWithPadding("left")
-- end)
-- -- hs.hotkey.bind({ "cmd" }, "L", function()
-- -- 	moveCursorWithPadding("right")
-- -- end)
-- hs.hotkey.bind({ "cmd" }, "K", function()
-- 	moveCursorWithPadding("up")
-- end)
-- hs.hotkey.bind({ "cmd" }, "J", function()
-- 	moveCursorWithPadding("down")
-- end)
-- hs.hotkey.bind({ "ctrl", "alt" }, "g", function()
-- 	local appName = "company.thebrowser.Browser"
-- 	local app = hs.application.get(appName)

-- 	local function focusAndPressCmd2()
-- 		hs.timer.doAfter(0.1, function()
-- 			hs.eventtap.keyStroke({ "cmd" }, "2")
-- 		end)
-- 	end

-- 	if app then
-- 		if app:isFrontmost() then
-- 			focusAndPressCmd2()
-- 		else
-- 			app:activate()
-- 			focusAndPressCmd2()
-- 		end
-- 	else
-- 		hs.application.launchOrFocus(appName)
-- 		hs.timer.doAfter(0.5, function()
-- 			app = hs.application.get(appName)
-- 			if app then
-- 				app:activate()
-- 				focusAndPressCmd2()
-- 			end
-- 		end)
-- 	end
-- end)

function screenCapture()
	local tmpfile = os.tmpname() .. ".png"
	local task = hs.task.new("/usr/sbin/screencapture", function()
		hs.pasteboard.setContents(tmpfile)
		hs.notify.show("Screenshot", "", "Path copied: " .. tmpfile)
	end, { "-i", "-s", tmpfile })
	task:start()
end

hs.hotkey.bind({ "alt", "ctrl" }, "3", screenCapture)

-- Image title rename script - processes image from clipboard and renames it
hs.hotkey.bind({ "ctrl", "cmd" }, "i", function()
	hs.alert.show("Processing image from clipboard...")
	local task = hs.task.new("/usr/bin/python3", function(exitCode, stdOut, stdErr)
		if exitCode == 0 then
			hs.alert.show("Image processed and saved!")
		else
			hs.alert.show("Error processing image: " .. (stdErr or "unknown error"))
		end
	end, {"/Users/senaca/kit/image-title-rename.py"})
	task:start()
end)

-- Focus toggle via Shortcuts so notifications can be silenced quickly
local focusShortcutName = "Toggle Focus"
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "F", function()
	hs.task.new("/usr/bin/shortcuts", function(exitCode, stdOut, stdErr)
		if exitCode ~= 0 then
			hs.alert.show("Focus shortcut failed (" .. tostring(exitCode) .. ")")
            -- log the stdErr
            print("Error: " .. tostring(stdErr))
		end
	end, { "run", focusShortcutName }):start()
end)

-- Ghostty Paste Image Handler
-- Save clipboard image and paste file path when Ctrl+V is pressed in Ghostty
local function saveClipboardImageAndPasteInGhostty()
	-- Check if clipboard contains an image
	local imageData = hs.pasteboard.readImage()
	if not imageData then
		-- No image in clipboard, do normal paste
		hs.eventtap.keyStroke({"cmd"}, "v")
		return
	end

	-- Generate filename with timestamp
	local timestamp = os.date("%Y%m%d_%H%M%S")
	local tmpDir = os.getenv("TMPDIR") or "/tmp"
	local filename = string.format("%s/clipboard_image_%s.png", tmpDir, timestamp)

	-- Save image to file
	local success = imageData:saveToFile(filename)
	if not success then
		hs.alert.show("Failed to save clipboard image")
		return
	end

	-- Optional: show notification
	hs.alert.show("Image saved and Path Copyed", 1)

    -- Set the clipboard to the file path
    hs.pasteboard.setContents(filename)

    -- Simulate Cmd+V to paste the file path
    hs.eventtap.keyStroke({"cmd"}, "v")
end

-- Bind Ctrl+V to our custom handler
hs.hotkey.bind({"ctrl", "cmd"}, "v", saveClipboardImageAndPasteInGhostty)
