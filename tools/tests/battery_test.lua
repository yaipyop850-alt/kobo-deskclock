-- Battery guard (dc_battery, v4.1): thresholds, once-per-discharge warnings,
-- re-arming, power-off countdown (charger / timeout / snooze / busy), and the
-- backup file (atomic write, read-back, never overwritten by an address-less one,
-- restore). usage: luajit tools/tests/battery_test.lua <scratch dir>
local S = arg[1]
local PLUGIN = (arg[0]:match("^(.*)/[^/]*$") or ".") .. "/../../deskclock.koplugin"
package.path = PLUGIN .. "/?.lua;" .. package.path
os.execute("mkdir -p " .. S .. "/data")
os.remove(S .. "/data/deskclock_backup.lua"); os.remove(S .. "/data/deskclock_backup.lua.1")
os.remove(S .. "/data/deskclock_urls.txt"); os.remove(S .. "/data/deskclock_write.txt")

local clock = 1764000000
local real_time = os.time
os.time = function(t) if t then return real_time(t) end return clock end

local cap, charging = 82, false
local shown, closed, scheduled, powered = {}, 0, {}, 0
local UI = {
    show = function(_, w) shown[#shown + 1] = w end,
    close = function() closed = closed + 1 end,
    scheduleIn = function(_, sec, f) scheduled[#scheduled + 1] = { at = clock + sec, f = f } end,
    unschedule = function(_, f) for i = #scheduled, 1, -1 do if scheduled[i].f == f then table.remove(scheduled, i) end end end,
    nextTick = function(_, f) f() end,
    poweroff_action = function() powered = powered + 1 end,
}
local function run(sec) -- advance the clock, running due scheduled functions
    local stop = clock + sec
    while true do
        table.sort(scheduled, function(a, b) return a.at < b.at end)
        local n = scheduled[1]
        if not n or n.at > stop then break end
        table.remove(scheduled, 1)
        clock = n.at
        n.f()
    end
    clock = stop
end
package.loaded["ui/uimanager"] = UI
package.loaded["logger"] = { warn = function() end, info = function() end, err = print }
package.loaded["datastorage"] = { getSettingsDir = function() return S .. "/data" end, getDataDir = function() return S .. "/data" end }
package.loaded["device"] = { getPowerDevice = function()
    return { getCapacity = function() return cap end, isCharging = function() return charging end }
end }
package.loaded["ui/widget/infomessage"] = { new = function(_, o) o.kind = "info"; return o end }
package.loaded["ui/widget/confirmbox"] = { new = function(_, o) o.kind = "confirm"; return o end }
local files = {} -- one table per path (memos and, since v4.1, the plugin settings)
package.loaded["luasettings"] = { open = function(_, path)
    local t = files[path] or { d = {} }
    files[path] = t
    function t:readSetting(k) return self.d[k] end
    function t:saveSetting(k, v) self.d[k] = v end
    function t:flush() end
    return t
end }
local memo_file = { d = {} }
files[S .. "/data/deskclock_memos.lua"] = memo_file
local settings = {}
G_reader_settings = {
    readSetting = function(_, k) return settings[k] end,
    saveSetting = function(_, k, v) settings[k] = v end,
    flush = function() end,
}

local Store = require("dc_store")
local B = require("dc_battery")
local Memo = require("dc_memo")
local fails = 0
local function check(name, cond)
    print((cond and "ok   " or "FAIL ") .. name)
    if not cond then fails = fails + 1 end
end

-- decide(): thresholds and once-per-discharge
B.warned = {}
check("82% nothing", B.decide(82, false, clock) == nil)
check("31% nothing", B.decide(31, false, clock) == nil)
check("30% -> warn 30", B.decide(30, false, clock) == 30)
check("29% no repeat", B.decide(29, false, clock) == nil)
check("20% -> warn 20", B.decide(20, false, clock) == 20)
check("16% no repeat", B.decide(16, false, clock) == nil)
check("15% -> off", B.decide(15, false, clock) == "off")
B.warned = {}
check("start at 18% -> only the 20 warning", B.decide(18, false, clock) == 20 and B.decide(18, false, clock) == nil)
check("charging resets", B.decide(18, true, clock) == nil and next(B.warned) == nil)
check("after charging, 18% warns again", B.decide(18, false, clock) == 20)
check("rises to 25% (no re-arm of 20 yet)", B.decide(24, false, clock) == nil)
check("rises to 26% re-arms 20, drop to 20 warns", B.decide(26, false, clock) == nil and B.decide(20, false, clock) == 20)
B.snooze_until = clock + 600
check("snoozed: no off", B.decide(14, false, clock) == nil)
check("snooze over: off", B.decide(14, false, clock + 601) == "off")
B.snooze_until = nil

-- backup with nothing to save yet
local s = Store:getSettings()
s.urls_text = ""
local ok = B.backup(Store, "시험 1")
check("backup without addresses writes when no backup exists", ok)
s.urls_text = "https://calendar.google.com/calendar/ical/a/private-x/basic.ics\n!https://example.com/holiday.ics"
s.wake_hours = 3
s.wake_log = { "log line" }
Memo:addMemo("메모 하나 — 학생A 상담")
ok = B.backup(Store, "시험 2")
check("backup with addresses", ok)
local data = B.readBackup()
check("backup has settings", data and data.settings.wake_hours == 3)
check("backup skips wake log", data and data.settings.wake_log == nil)
check("backup has memos", data and #data.memos.memos == 1)
check("previous copy kept as .1", B.readBackup(B.backupPath() .. ".1") ~= nil)
check("no temp file left", io.open(B.backupPath() .. ".tmp") == nil)

-- settings lost: an address-less backup must not replace the good one
s.urls_text = ""
local ok2, why = B.backup(Store, "시험 3")
check("address-less backup refused (" .. tostring(why) .. ")", not ok2 and B.readBackup().settings.urls_text ~= "")

-- restore after losing everything
Store.settings = nil
settings.deskclock = nil
files[S .. "/data/deskclock_settings.lua"] = nil
memo_file.d = {}
Memo.data = nil
local rok, rmemos = B.restore(Store)
check("restore ok", rok)
check("restored addresses", (Store:getSettings().urls_text or ""):find("private%-x") ~= nil)
Store.urls = nil
check("restored getUrls", #Store:getUrls() == 2)
check("restored memos", rmemos and #Memo:load().memos == 1)

-- the urls file is put back only when missing
local f = io.open(Store:urlFilePath(), "w"); f:write("https://example.com/file.ics\n"); f:close()
B.backup(Store, "시험 4")
os.remove(Store:urlFilePath())
B.restore(Store)
f = io.open(Store:urlFilePath()); local txt = f and f:read("*a"); if f then f:close() end
check("urls file recreated", txt and txt:find("file.ics") ~= nil)

-- a corrupt backup is reported, not loaded
local cf = io.open(S .. "/data/broken.lua", "w"); cf:write("return { settings = "); cf:close()
local bad, err = B.readBackup(S .. "/data/broken.lua")
check("corrupt backup rejected", bad == nil and err ~= nil)

-- check(): warning popups
B.warned = {}; B.snooze_until = nil; shown = {}
cap = 30
check("check 30 -> warn", B.check(Store, {}) == 30 and shown[1] and shown[1].kind == "info")
print("     30% popup:\n" .. shown[1].text:gsub("\n", "\n       "))
cap = 20; shown = {}
check("check 20 -> warn", B.check(Store, {}) == 20)
print("     20% popup:\n" .. shown[1].text:gsub("\n", "\n       "))
cap = 19; shown = {}
check("check 19 -> nothing", B.check(Store, {}) == nil and #shown == 0)

-- power off: timeout
cap = 15; shown = {}; powered = 0; scheduled = {}
check("check 15 -> off dialog", B.check(Store, {}) == "off" and shown[1].kind == "confirm")
print("     off dialog:\n" .. shown[1].text:gsub("\n", "\n       ") .. "\n       [" .. shown[1].ok_text .. "] [" .. shown[1].cancel_text .. "]")
check("no second dialog while counting down", B.check(Store, {}) == nil and #shown == 1)
run(55)
check("not yet off at 55 s", powered == 0)
run(10)
check("off after 60 s", powered == 1 and B.dialog == nil)

-- power off: charger plugged in during countdown
B.warned = {}; B.dialog = nil; powered = 0; scheduled = {}; shown = {}
cap = 14; charging = false
B.check(Store, {})
run(20); charging = true; run(10)
check("charger cancels", powered == 0 and B.dialog == nil and #scheduled == 0)
charging = false

-- power off: "10분 뒤 다시"
B.warned = {}; B.dialog = nil; scheduled = {}; shown = {}
B.check(Store, {})
local dlg = shown[1]
dlg.cancel_callback()
check("snooze closes countdown", B.dialog == nil and #scheduled == 0 and powered == 0)
run(300); check("snoozed check at +5 min: nothing", B.check(Store, {}) == nil)
run(301); check("after 10 min asks again", B.check(Store, {}) == "off")
B.dialog.ok_callback()
check("[지금 끄기] powers off now", powered == 1)

-- busy (sync running): wait, then off
B.warned = {}; B.dialog = nil; B.snooze_until = nil; powered = 0; scheduled = {}
local busy = true
check("busy -> wait", B.check(Store, { busy = function() return busy end }) == "wait")
busy = false
run(31)
check("after the sync -> off", B.check(Store, { busy = function() return busy end }) == "off")
B.dialog = nil; scheduled = {}

-- asleep (timed wake-up): no dialog, off at once
B.warned = {}; B.snooze_until = nil; powered = 0; shown = {}
check("asleep -> off at once", B.check(Store, { asleep = true }) == "off" and powered == 1 and #shown == 0)
B.warned = {}; cap = 25; shown = {}
check("asleep warning: backup only, no popup", B.check(Store, { asleep = true }) == 30 and #shown == 0)

-- periodic start is idempotent
scheduled = {}
B.tick = nil
B.start(Store, function() return false end)
B.start(Store, function() return false end)
check("start schedules once", #scheduled == 1)

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
