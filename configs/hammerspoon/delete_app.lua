local module = {}

local function deleteApp(appName, appPath)
	if appPath then
		-- get the application size and store it into 'size'
		local cmd = "du -sh '" .. appPath .. "'" .. " | awk '{print $1}'"
		local size = hs.execute(cmd)
		-- open finder and locate this app
		local cmd = "open -R '"
			.. appPath
			.. '\' && sleep 0.5 && osascript -e \'tell application "Finder" to delete POSIX file "'
			.. appPath
			.. "\"'"
		local task = hs.task.new("/bin/sh", function(exitCode)
			if exitCode == 0 then
				print("Application '" .. appName .. "' has been moved to the trash.")
				-- alert: 释放了 size 空间
				hs.alert.show("Removing '" .. appName .. "' has freed " .. size .. " space.")
			else
				print("Error moving application to trash: Exit code " .. exitCode)
			end
		end, function() end, { "-c", cmd })
		task:start()
	else
		print("Application not found.")
	end
end

module.appList = function()
	local appsPath = "/Applications/"
	local choices = {}

	for file in hs.fs.dir(appsPath) do
		if file:sub(-4) == ".app" then
			local appName = file:sub(1, -5)
			local appPath = appsPath .. file
			table.insert(choices, {
				["text"] = appName,
				["subText"] = appPath,
			})
		end
	end

	return choices
end

module.appSelected = function(choice)
	if choice then
		deleteApp(choice.text, choice.subText)
	end
end

module.appChooser = hs.chooser.new(module.appSelected)

return module
