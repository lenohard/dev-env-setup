-- Inspired by https://github.com/Hammerspoon/hammerspoon/issues/2196 and the code found at
-- https://github.com/lodestone/macpaste

-- TODO:
--     move to spoon
--     monitor pasteboard changecount to detect when the copy is no longer ours
--       flag to do/not do paste with third button?
--     alternate paste methods for trackpad use?
--
--     monitor for shift down and arrow movements to get text selected this way?
--       would have to wait until shift released to minimize extra copies to clipboard
--
--     update hs.pasteboard to "backup" and "restore" clipboard? would allow backup of existing item(s)
--       while still using cmd-C ourselves to get as many types and promised types as offered then
--       move to alternate clipboard and restore, so traditional use of cut/paste not interrupted

local eventtap = require("hs.eventtap")
local eventTypes = eventtap.event.types
local timer = require("hs.timer")

local M = {}

local dragCount = 0
local clickStack = {}

local function trackClick()
	clickStack[2] = clickStack[1]
	clickStack[1] = timer.secondsSinceEpoch()

	return false
end

local function incrementDragCount()
	dragCount = dragCount + 1

	return false
end

local function wasDoubleClick()
	if not clickStack[2] then
		return false
	end

	return clickStack[1] - clickStack[2] <= eventtap.doubleClickInterval()
end

local function wasDragging()
	return dragCount > 10
end

local function handleMouseUp()
	local additionalEvents = {}

	if wasDragging() or wasDoubleClick() then
		additionalEvents = {
			eventtap.event.newKeyEvent({ "cmd" }, "c", true),
			eventtap.event.newKeyEvent({ "cmd" }, "c", false),
		}
	end
	dragCount = 0

	return false, additionalEvents
end

M._mouseDownEvent = eventtap.new({ eventTypes.leftMouseDown }, trackClick)
M._mouseDragEvent = eventtap.new({ eventTypes.leftMouseDragged }, incrementDragCount)
M._mouseUpEvent = eventtap.new({ eventTypes.leftMouseUp }, handleMouseUp)

M.load = function()
  M._mouseDownEvent:start()
  M._mouseDragEvent:start()
  M._mouseUpEvent:start()
end

return M