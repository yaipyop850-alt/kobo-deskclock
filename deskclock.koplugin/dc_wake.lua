--[[--
Timed wake-ups while asleep (Kobo only): automatic sync every N hours, and
alarms before events / timed to-dos (dc_alarm).

KOReader's WakeupMgr sets the RTC alarm; on Kobo, about 15 s after an alarm
wake-up `Kobo:checkUnexpectedWakeup` runs our task and then puts the device
back to sleep 30 s later. A sync needs more (Wi-Fi takes 10-20 s on an Aura
HD), so the task asks for a longer window first, and asks to sleep again as
soon as the new sleep screen is on the panel. If anything hangs, the window
simply runs out and the device sleeps anyway.

One task at a time: we always schedule only the earliest of "next sync" and
"next alarm", and decide what is due when it fires. (Two WakeupMgr tasks a
few seconds apart could leave the RTC set to a time already past.)

Safety:
  * battery below MIN_BATTERY (and not charging) -> no more syncs;
    below MIN_ALARM_BATTERY -> no wake-ups at all
  * the user waking the device (power button) cancels the pending wake-up
  * every wake-up is logged (last 8) for the diagnostics screen
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Alarm = require("dc_alarm")

local Wake = {
    MIN_BATTERY = 20,        -- % for syncs (Wi-Fi)
    MIN_ALARM_BATTERY = 10,  -- % for alarms (no Wi-Fi)
    BUDGET = 150,            -- seconds awake at most for a sync
    ALARM_BUDGET = 40,       -- seconds awake at most for an alarm alone
    MIN_AHEAD = 20,          -- never set the RTC closer than this
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

local function removeTask(w)
    if w.wake_cb and Device.wakeup_mgr then
        Device.wakeup_mgr:removeTasks(nil, w.wake_cb)
    end
    w.next_wake = nil
    w.next_alarm = nil
end

--- (Re)set the one RTC task: the earlier of the next sync and the next alarm.
-- `w.next_sync_at` (os.time) is kept by the caller.
function Wake.schedule(w)
    removeTask(w)
    if not Wake.supported() then return end
    local store = w.store
    local now = os.time()
    local target
    if w.next_sync_at then target = w.next_sync_at end
    local at = Alarm.nextAt(store, store:now())
    if at then
        w.next_alarm = at - store:offset()
        if not target or w.next_alarm < target then target = w.next_alarm end
    end
    if not target then return end
    target = math.max(target, now + Wake.MIN_AHEAD)
    w.wake_cb = w.wake_cb or function()
        -- run after KOReader's own bookkeeping for this wake-up has finished
        UIManager:nextTick(function() Wake.run(w) end)
    end
    Device.wakeup_mgr:addTask(target - now, w.wake_cb)
    w.next_wake = target
end

--- Called when the device goes to sleep showing our calendar.
function Wake.arm(w)
    Wake.disarm(w)
    if not Wake.supported() then return end
    if w.store:getSettings().sleep_view == false then return end
    local hours = Wake.hours(w.store)
    local cap, charging = battery()
    local low = cap and not charging
    if low and cap < Wake.MIN_ALARM_BATTERY then
        Wake.log(w.store, string.format("배터리 %d%% — 자동 깨우기 안 함", cap))
        return
    end
    if hours and low and cap < Wake.MIN_BATTERY then
        Wake.log(w.store, string.format("배터리 %d%% — 자동 동기화 안 함", cap))
        hours = nil
    end
    w.next_sync_at = hours and (os.time() + math.floor(hours * 3600)) or nil
    Wake.schedule(w)
end

--- Called on a real resume (power button) or when the screen closes.
function Wake.disarm(w)
    removeTask(w)
    w.next_sync_at = nil
end

--- The RTC alarm went off: ring due alarms, sync if due, redraw, sleep again.
function Wake.run(w)
    if not w.sleeping then return end
    local store = w.store
    local now = os.time()
    w.next_wake = nil
    local cap, charging = battery()
    local low = cap and not charging
    if low and cap < Wake.MIN_ALARM_BATTERY then
        Wake.log(store, string.format("배터리 %d%% — 자동 깨우기 멈춤", cap))
        w.next_sync_at = nil
        return -- KOReader puts the device back to sleep by itself
    end

    local alarms = Alarm.due(store, store:now())
    local sync_due = w.next_sync_at ~= nil and w.next_sync_at <= now + 60
    if sync_due then
        local hours = Wake.hours(store)
        if low and cap < Wake.MIN_BATTERY then
            Wake.log(store, string.format("배터리 %d%% — 자동 동기화 멈춤", cap))
            sync_due, w.next_sync_at = false, nil
        else
            w.next_sync_at = hours and (now + math.floor(hours * 3600)) or nil
        end
    end
    if #alarms > 0 then Alarm.markFired(store, alarms) end
    -- next round first, so a failure below does not end the chain
    Wake.schedule(w)
    if not sync_due and #alarms == 0 then
        -- nothing left to do (an event was moved or removed meanwhile)
        Device:rescheduleSuspend(3)
        return
    end
    Device:rescheduleSuspend(sync_due and Wake.BUDGET or Wake.ALARM_BUDGET)

    local started = os.time()
    local function finish(ok, err)
        if not w.sleeping then return end -- woken by the user meanwhile
        w.sleep_time = store:now()
        -- a popup left on the sleep screen shows the new data too
        if w.todo_popup and w.todo_popup.refreshForNow then w.todo_popup:refreshForNow() end
        if sync_due then Wake.schedule(w) end -- new events may ring earlier
        w:rebuild()
        UIManager:setDirty(w, function() return "full", w.dimen end)
        UIManager:forceRePaint()
        local parts = {}
        if #alarms > 0 then parts[#parts + 1] = string.format("알림 %d건", #alarms) end
        if sync_due then
            parts[#parts + 1] = ok and "동기화 성공" or ("동기화 실패: " .. tostring(err))
        end
        Wake.log(store, table.concat(parts, " · ") .. string.format(" (%d초)", os.time() - started))
        -- give the panel a moment to finish, then sleep again
        Device:rescheduleSuspend(3)
    end
    local function afterAlarm()
        if not w.sleeping then return end
        if sync_due then
            w.after_sync = finish
            w:syncNow(true)
        else
            finish(true)
        end
    end
    if #alarms > 0 then
        w:ringAlarms(alarms, afterAlarm)
    else
        afterAlarm()
    end
end

return Wake
