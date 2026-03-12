local module = {}

module.toggle_application = function(app_name)
	-- Enable spotlight
	hs.application.enableSpotlightForNameSearches(true)

	-- If name is not bundleID, get the bundleID
	local bundleID = app_name
	if not module.isBundleID(app_name) then
		local success, bundleIDResult = pcall(function()
			return hs.application.infoForBundlePath("/Applications/" .. app_name .. ".app")["CFBundleIdentifier"]
		end)
		if success then
			bundleID = bundleIDResult
		end
	end

	local app = hs.application.find(bundleID)
	if app then
		print(bundleID .. " is found")
		if app:isFrontmost() then
			if app:mainWindow() == nil then
				print(bundleID .. " has no main window")
				hs.execute("open -b " .. bundleID)
				print("open -b " .. bundleID)
			else
				print(bundleID .. " is frontmost and has main window")
				-- dont hide when the window is approximately full size eg: measures fit: left < 2 %, right > 98 %, top < 2 %, bottom > 98 %
				local frame = app:focusedWindow():frame()
				if
					frame.w < 0.98 * hs.screen.mainScreen():frame().w
					or frame.h < 0.98 * hs.screen.mainScreen():frame().h
				then
					app:hide()
					print("hide " .. bundleID)
				end
				print("window is too large so not hiding")
			end
		else
			print(bundleID .. " is not frontmost")
			app:activate()
			print("activate " .. bundleID)

			if app:mainWindow() == nil then
				print(bundleID .. " has no main window")
				hs.execute("open -b " .. bundleID)
				print("open -b " .. bundleID)
				app:activate()
			end
		end
	else
		print(bundleID .. " is not found")
		local result = hs.application.launchOrFocus(bundleID)
		print("launchOrFocus result: " .. tostring(result))
		if not result then
			hs.execute("open -b " .. bundleID)
			print("open -b " .. bundleID)
		end
	end
end

-- module.toggle_application = function(app_name)
--   -- enable spotlight
--   hs.application.enableSpotlightForNameSearches(true)

--   -- if name is not bundleID, get the bundleID
--   local bundleID = app_name
--   if not module.isBundleID(app_name) then
--     local success, bundleID = pcall(function()
--       return hs.application.infoForBundlePath("/Applications/" .. app_name .. ".app")["CFBundleIdentifier"]
--     end)
--   end

--   local app = hs.application.find(bundleID)
--   if app then
--     print(bundleID .. " is found")
--     if app:isFrontmost() then
--       if app:mainWindow() == nil then
--         print(bundleID .. " has no main window")
--         hs.execute("open -b " .. bundleID)
--         print("open -b " .. bundleID)
--       else
--         print(bundleID .. " is frontmost and has main window")
--         app:hide()
--         print("hide " .. bundleID)
--       end
--     else
--       print(bundleID .. " is not frontmost")
--       app:activate()
--       print("activate " .. bundleID)
--       -- if there is no window, create the main window
--       if app:mainWindow() == nil then
--         print(bundleID .. " has no main window")
--         hs.execute("open -b " .. bundleID)
--         print("open -b " .. bundleID)
--         app:activate() -- necessary, otherwise the newly opend window will be under iterm2 for some reason I don't know rightnow.
--       end
--     end
--   else
--     print(bundleID .. " is not found")
--     result = hs.application.launchOrFocus(bundleID)
--     print("lanuchOrFocus result: " .. tostring(result))
--     if not result then
--       hs.execute("open -b " .. bundleID)
--       print("open -b " .. bundleID)
--     end
--   end
-- end

module.isBundleID = function(str)
	-- Bundle ID should be in the form of com.companyname.applicationname
	local pattern = "^[%w-]+%.[%w-]+%.[%w-]+$"
	return string.match(str, pattern) ~= nil
end

-- if current application have no window
-- create a new window
module.newWindow = function()
	local app = hs.application.frontmostApplication()
	print("the frontmost application is " .. app:name())
	if app:mainWindow() == nil then
		print("the frontmost application has no window")
		hs.execute("open -b " .. app:bundleID())
	end
end

-- hide and refocuse the current window.
module.refocus = function()
	local app = hs.application.frontmostApplication()
	print("the frontmost application is " .. app:name())
	if app:isFrontmost() then
		print("the frontmost application is frontmost")
		app:hide()
		app:activate()
	else
		print("the frontmost application is not frontmost")
		app:activate()
	end
end

module.getSelectedFile = function()
	local _, files = hs.osascript.applescript([[
    tell application "Finder"
      set theSelection to selection
      if (count of theSelection) > 0 then
        set theItem to item 1 of theSelection as alias
        return POSIX path of theItem
      else
        return ""
      end if
    end tell
  ]])
	return files
end

return module
