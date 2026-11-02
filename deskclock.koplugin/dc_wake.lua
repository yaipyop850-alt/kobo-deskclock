--[[--
Timed wake-ups while asleep (experimental, off by default).

KOReader's WakeupMgr sets the RTC alarm; on Kobo, about 15 s after an alarm
wake-up `Kobo:checkUnexpectedWakeup` runs our task and then puts the device
back to sleep 30 s later. That is too short for Wi-Fi (10-20 s on an Aura HD)
plus a sync, so the task asks for a longer window first, and asks to sleep
again as soon as the new sleep screen is on the panel. If anything hangs, the
window simply runs out and the device sleeps anyway.

Safety:
  * battery below MIN_BATTERY (and not charging) -> stop the chain
  * the user waking the device (power button) cancels the pending alarm
  * every attempt is logged (last 8) for the diagnostics screen
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Wake = {
    MIN_BATTERY = 20,   -- %
    BUDGET = 150,       -- seconds awake at most per wake-up
    LOG_SIZE = 8,
}

--- Can this device be woken by an alarm the way we need?
function Wake.supported()
    return Device.wakeup_mgr ~= nil
        and type(Device.rescheduleSuspend) == "function"
        and (Device.isKobo == nil or Device:isKobo())
end

local function battery()
    local powerd = Device.getPowerDevice and Device:getPowerDevice()
    if not powerd or not powerd.getCapacity then return nil, false end
    return powerd:getCapacity(), powerd.isCharging and powerd:isCharging() or false
end

function Wake.log(store, line)
    local s = store:getSettings()
    s.wake_log = s.wake_log or {}
    table.insert(s.wake_log, 1, os.date("!%m/%d %H:%M ", store:now()) .. line)
    while #s.wake_log > Wake.LOG_SIZE do table.remove(s.wake_log) end
    store:save()
    logger.info("deskclock wake:", line)
end

function Wake.hours(store)
    local h = store:getSettings().wake_hours
    return (type(h) == "number" and h > 0) and h or nil
end

--- Called when the device goes to sleep showing our calendar.
function Wake.arm(w)
    Wake.disarm(w)
    local hours = Wake.hours(w.store)
    if not hours or not Wake.supported() then return end
    if w.store:getSettings().sleep_view == false then return end
    local cap, charging = battery()
    if cap and cap < Wake.MIN_BATTERY and not charging then
        Wake.log(w.store, string.format("배터리 %d%% — 자동 깨우기 안 함", cap))
        return
    end
    w.wake_cb = w.wake_cb or function()
        -- run after KOReader's own bookkeeping for this wake-up has finished
        UIManager:nextTick(function() Wake.run(w) end)
    end
    Device.wakeup_mgr:addTask(math.floor(hours * 3600), w.wake_cb)
    w.next_wake = os.time() + math.floor(hours * 3600)
end

--- Called on a real resume (power button) or when the screen closes.
function Wake.disarm(w)
    if w.wake_cb and Device.wakeup_mgr then
        Device.wakeup_mgr:removeTasks(nil, w.wake_cb)
    end
    w.next_wake = nil
end

--- The alarm went off: sync, redraw the sleep screen, sleep again.
function Wake.run(w)
    if not w.sleeping then return end
    local store = w.store
    w.next_wake = nil
    local cap, charging = battery()
    if cap and cap < Wake.MIN_BATTERY and not charging then
        Wake.log(store, string.format("배터리 %d%% — 자동 깨우기 멈춤", cap))
        return -- KOReader puts the device back to sleep by itself
    end
    -- next round first, so a failure below does not end the chain
    local hours = Wake.hours(store)
    if hours then
        Device.wakeup_mgr:addTask(math.floor(hours * 3600), w.wake_cb)
        w.next_wake = os.time() + math.floor(hours * 3600)
    end
    Device:rescheduleSuspend(Wake.BUDGET)
    local started = os.time()
    w.after_sync = function(ok, err)
        if not w.sleeping then return end -- woken by the user meanwhile
        w.sleep_time = store:now()
        -- a popup left on the sleep screen shows the new data too
        if w.todo_popup and w.todo_popup.refreshForNow then w.todo_popup:refreshForNow() end
        w:rebuild()
        UIManager:setDirty(w, function() return "full", w.dimen end)
        UIManager:forceRePaint()
        Wake.log(store, (ok and "동기화 성공" or ("동기화 실패: " .. tostring(err)))
            .. string.format(" (%d초)", os.time() - started))
        -- give the panel a moment to finish, then sleep again
        Device:rescheduleSuspend(3)
    end
    w:syncNow(true)
end

return Wake
