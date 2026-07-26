-- universal_control.lua
-- 用键盘快捷键把指针"推过"屏幕边缘, 触发 Universal Control 切到另一台 Mac。
--
-- 关键点:
--  1. 用 hs.mouse.getCurrentScreen() (本机原代码已用), 而不是 hs.screen.find(pos)
--     —— 后者在 UC 接管时常常返回 nil, 这就是之前提示 "找不到鼠标所在屏" 的原因。
--  2. 光 hs.mouse.setAbsolutePosition (其实是 CGWarpMouseCursorPosition) 是 *瞬移*,
--     UC 的边缘检测不响应 warp —— 所以必须再发真实的 mouseMoved 事件穿越边缘。
--  3. 流程: 先 warp 到边缘内侧 2px → 40ms 后发 mouseMoved 到边缘外 8px → 再抖一次。
--
-- 快捷键 (init.lua 末尾 require("universal_control").bind() 启用):
--   ⌘⌥→  向东推 (右侧 Mac)
--   ⌘⌥←  向西推 (左侧 Mac)
--   ⌘⌥↑  向北推 (上侧 Mac)
--   ⌘⌥↓  向南推 (下侧 Mac)

local M = {}

local function leap(dir)
    local scr = hs.mouse.getCurrentScreen()
    if not scr then
        hs.alert.show("UC: 找不到当前屏")
        return
    end
    local f = scr:fullFrame()
    local midX = f.x + f.w / 2
    local midY = f.y + f.h / 2

    local start, fin
    if dir == "right" then
        start = { x = f.x + f.w - 2, y = midY }
        fin   = { x = f.x + f.w + 8, y = midY }
    elseif dir == "left" then
        start = { x = f.x + 2,      y = midY }
        fin   = { x = f.x - 8,      y = midY }
    elseif dir == "up" then
        start = { x = midX, y = f.y + 2      }
        fin   = { x = midX, y = f.y - 8      }
    elseif dir == "down" then
        start = { x = midX, y = f.y + f.h - 2 }
        fin   = { x = midX, y = f.y + f.h + 8 }
    else
        return
    end

    -- 1) 先瞬移到边缘内侧, 离边界只有 2px
    hs.mouse.setAbsolutePosition(start)

    -- 2) 多步渐进地往外推, 每步发真实 mouseMoved 并 warp 同步位置。
    --    UC 的边缘切换要求指针 *持续贴边向外推*, 单发一两次越不过去。
    --    这里用 8 个小步, 每步 35ms, 总共 ~0.28s 推到 fin, 再持续贴住 0.2s。
    local function step(p)
        hs.mouse.setAbsolutePosition(p)
        hs.eventtap.event
            .newMouseEvent(hs.eventtap.event.types.mouseMoved, p)
            :post()
    end

    local steps, gap = 8, 0.035
    for i = 1, steps do
        local t = i / steps
        local p = {
            x = start.x + (fin.x - start.x) * t,
            y = start.y + (fin.y - start.y) * t,
        }
        hs.timer.doAfter(gap * i, function() step(p) end)
    end
    -- 3) 抵达 fin 后继续多几次东消, 持住贴边 0.2s, 保证 UC 接管
    for j = 1, 6 do
        hs.timer.doAfter(gap * steps + 0.03 * j, function() step(fin) end)
    end
end

function M.bind()
    hs.hotkey.bind({ "cmd", "alt" }, "right", function() leap("right") end)
    hs.hotkey.bind({ "cmd", "alt" }, "left",  function() leap("left")  end)
    hs.hotkey.bind({ "cmd", "alt" }, "up",    function() leap("up")    end)
    hs.hotkey.bind({ "cmd", "alt" }, "down",  function() leap("down")  end)
end

return M