--[[--
Alarms before timed events and timed to-dos (off by default).

  * lead time: 5 / 10 / 15 / 30 minutes before the start (`alarm_lead`, 0 = off)
  * events: every timed event, or only those whose title starts with "!"
    (`alarm_target` = "all" | "mark"); all-day events never ring
  * to-dos: an open to-do whose first line carries a time in brackets,
    e.g. "밥 먹기 (15:30)". It rings once, at the first 15:30 after the device
    first saw that text (written at 16:00 -> tomorrow 15:30).

Each alarm rings once (`alarm_fired`). Ringing = the screen is inverted a few
times (e-ink full refreshes; no sound, no front light) and an alarm popup is
left on the screen. Asleep, `dc_wake` wakes the device for it (no Wi-Fi) and
puts it back to sleep with the popup showing.

All times here are "local epochs" (store:now()), like the calendar data.
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ICS = require("dc_ics")
local Memo = require("dc_memo")
local Screen = Device.screen

local DAY = 86400

local Alarm = {
    LEADS = { 5, 10, 15, 30 },
    FLASHES = 3,        -- inverted / normal pairs
    FLASH_STEP = 1.0,   -- seconds per state (an Aura HD full refresh takes ~0.5 s)
    DUE_AHEAD = 30,     -- an alarm this close counts as due now (seconds)
}

function Alarm.lead(store)
    local v = store:getSettings().alarm_lead
    return (type(v) == "number" and v > 0) and v or nil
end

function Alarm.target(store)
    return store:getSettings().alarm_target == "mark" and "mark" or "all"
end

-- full-width forms typed on a Korean keyboard count too
local function normalize(t)
    return (t or ""):gsub("（", "("):gsub("）", ")"):gsub("：", ":"):gsub("！", "!")
end

local function marked(title)
    -- "◇ " marks an event sent from the device that Google has not returned yet
    local t = normalize(title):gsub("^%s*◇%s*", "")
    return t:match("^%s*!") ~= nil
end
Alarm.marked = marked

--- "밥 먹기 (15:30)" -> 15, 30 (first line only; "( 9:05 )" also works)
function Alarm.todoTime(text)
    local first = normalize((text or ""):match("^[^\n]*") or "")
    local h, m = first:match("%(%s*(%d%d?)%s*:%s*(%d%d)%s*%)")
    h, m = tonumber(h), tonumber(m)
    if not h or h > 23 or m > 59 then return nil end
    return h, m
end

-- When did the device first see this to-do text? (local epoch)
-- Kept per memo; a changed text starts again from now.
local function seenAt(store, m, now)
    local s = store:getSettings()
    s.alarm_seen = s.alarm_seen or {}
    local rec = s.alarm_seen[m.id]
    if not rec or rec.text ~= m.text then
        local base = now
        if not rec and m.created then
            -- a to-do written on the device before this feature existed: its own time
            base = math.min(now, (m.edited or m.created) + store:offset())
        end
        rec = { text = m.text, at = base }
        s.alarm_seen[m.id] = rec
        store:save()
    end
    return rec.at
end

--- Everything that can ring, with `at` (alarm time) and `start`, sorted by `at`.
function Alarm.items(store, now)
    local lead = Alarm.lead(store)
    if not lead then return {} end
    now = now or store:now()
    local list = {}
    local only_marked = Alarm.target(store) == "mark"
    local horizon = now + 2 * DAY
    for _, o in ipairs(store.occurrences or {}) do
        if o.start > horizon then break end
        if not o.allday and o.start > now - 3600 and (not only_marked or marked(o.summary)) then
            local title = o.summary or ""
            if o.location and o.location ~= "" then title = title .. "  (" .. o.location .. ")" end
            list[#list + 1] = {
                kind = "event", key = "e|" .. (o.summary or "") .. "|" .. o.start,
                start = o.start, stop = o.stop, title = title,
            }
        end
    end
    local seen_ids = {}
    for _, m in ipairs(Memo:memos()) do
        if not m.done then
            local h, mi = Alarm.todoTime(m.text)
            if h then
                seen_ids[m.id] = true
                local base = seenAt(store, m, now)
                local t = ICS.dayStart(base) + h * 3600 + mi * 60
                if t <= base then t = t + DAY end
                list[#list + 1] = { kind = "todo", key = "t|" .. m.id .. "|" .. t, start = t, memo_id = m.id }
            end
        end
    end
    -- forget memos that are gone, done or lost their time
    local s = store:getSettings()
    if s.alarm_seen then
        local dirty = false
        for id in pairs(s.alarm_seen) do
            if not seen_ids[id] then s.alarm_seen[id] = nil; dirty = true end
        end
        if dirty then store:save() end
    end
    for _, it in ipairs(list) do it.at = it.start - lead * 60 end
    table.sort(list, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.key < b.key end)
    return list
end

local function fired(store)
    local s = store:getSettings()
    s.alarm_fired = s.alarm_fired or {}
    return s.alarm_fired
end

--- Alarms to ring now: alarm time reached, not started yet (or just), not rung.
function Alarm.due(store, now)
    now = now or store:now()
    local done = fired(store)
    local list = {}
    for _, it in ipairs(Alarm.items(store, now)) do
        if it.at <= now + Alarm.DUE_AHEAD and it.start > now - 60 and not done[it.key] then
            list[#list + 1] = it
        end
    end
    return list
end

--- Next alarm time (local epoch) still to come, or nil.
function Alarm.nextAt(store, now)
    now = now or store:now()
    local done = fired(store)
    for _, it in ipairs(Alarm.items(store, now)) do
        if it.at > now + Alarm.DUE_AHEAD and not done[it.key] then return it.at, it end
    end
    return nil
end

function Alarm.markFired(store, items)
    local done = fired(store)
    local now = store:now()
    for _, it in ipairs(items) do done[it.key] = it.start end
    for k, start in pairs(done) do
        if type(start) ~= "number" or start < now - 2 * DAY then done[k] = nil end
    end
    store:save()
end

---------------------------------------------------------------- flashing

-- Painted on top of everything: inverts what is already on the screen buffer.
local Flash = WidgetContainer:extend{ name = "DeskClockFlash", covers_fullscreen = false }

function Flash:paintTo(bb, x, y)
    if bb and bb.invertRect then
        bb:invertRect(0, 0, bb:getWidth(), bb:getHeight())
    end
end

--- Invert the screen FLASHES times, then call `done`.
function Alarm.flash(w, done)
    Alarm.stopFlash(w)
    local ov = Flash:new{ dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } }
    local n, total = 0, Alarm.FLASHES * 2
    local step
    step = function()
        if n >= total then
            w.flash_step = nil
            w.flash_widget = nil
            if done then done() end
            return
        end
        if n % 2 == 0 then
            UIManager:show(ov, "full")
        else
            UIManager:close(ov, "full") -- repaints the screen and the popup below it
        end
        UIManager:forceRePaint()
        n = n + 1
        UIManager:scheduleIn(Alarm.FLASH_STEP, step)
    end
    w.flash_step, w.flash_widget = step, ov
    step()
end

--- Stop a running flash (the screen closes, or a new alarm starts).
function Alarm.stopFlash(w)
    if w.flash_step then
        UIManager:unschedule(w.flash_step)
        w.flash_step = nil
    end
    if w.flash_widget then
        UIManager:close(w.flash_widget)
        w.flash_widget = nil
    end
end

return Alarm
