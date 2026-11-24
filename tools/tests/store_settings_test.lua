-- v4.1: plugin settings in settings/deskclock_settings.lua (migrated once from
-- KOReader's settings.reader.lua, old copy untouched), and the "address file
-- vanished" message. usage: luajit tools/tests/store_settings_test.lua <scratch dir>
local S = arg[1]
local PLUGIN = (arg[0]:match("^(.*)/[^/]*$") or ".") .. "/../../deskclock.koplugin"
package.path = PLUGIN .. "/?.lua;" .. package.path
os.execute("rm -rf " .. S .. "/data && mkdir -p " .. S .. "/data")

local files = {}
local flushes = {}
package.loaded["luasettings"] = { open = function(_, path)
    local t = files[path] or { d = {}, path = path }
    files[path] = t
    function t:readSetting(k) return self.d[k] end
    function t:saveSetting(k, v) self.d[k] = v end
    function t:flush() flushes[self.path] = (flushes[self.path] or 0) + 1 end
    return t
end }
package.loaded["logger"] = { warn = function() end, info = function() end }
package.loaded["datastorage"] = { getSettingsDir = function() return S .. "/data" end, getDataDir = function() return S end }
package.loaded["device"] = {}
package.loaded["ui/uimanager"] = {}
package.loaded["libs/libkoreader-lfs"] = {
    dir = function(d)
        local p = io.popen('ls -1 "' .. d .. '" 2>/dev/null')
        local names = {}
        for l in p:lines() do names[#names + 1] = l end
        p:close()
        local i = 0
        return function() i = i + 1 return names[i] end
    end,
    attributes = function() return nil end,
}
local kosettings = { deskclock = { wake_hours = 3, alarm_lead = 5, urls_text = "", last_error = "캘린더 주소 없음" } }
local ko_flush = 0
G_reader_settings = {
    readSetting = function(_, k) return kosettings[k] end,
    saveSetting = function(_, k, v) kosettings[k] = v end,
    flush = function() ko_flush = ko_flush + 1 end,
}
local fails = 0
local function check(name, cond)
    print((cond and "ok   " or "FAIL ") .. name)
    if not cond then fails = fails + 1 end
end

local Store = require("dc_store")
local own = S .. "/data/deskclock_settings.lua"

-- migration
local s = Store:getSettings()
check("migrated values", s.wake_hours == 3 and s.alarm_lead == 5)
check("written to own file", files[own] and files[own].d.deskclock and files[own].d.deskclock.wake_hours == 3)
check("KOReader settings not flushed by migration", ko_flush == 0)
Store:set("wake_hours", 6)
check("save goes to own file", files[own].d.deskclock.wake_hours == 6 and flushes[own] >= 2)
check("KOReader copy untouched (rollback to 4.0 still works)", kosettings.deskclock.wake_hours == 3 and ko_flush == 0)
check("own settings is a copy, not the same table", kosettings.deskclock ~= files[own].d.deskclock)

-- next start reads the own file, not KOReader's
Store.settings = nil
kosettings.deskclock.wake_hours = 99
check("second start reads own file", Store:getSettings().wake_hours == 6)

-- never set up
Store.urls = nil
local msg, short = Store:noAddressMessage()
check("never set up -> 미설정", short == "캘린더 미설정" and not msg:find("없어졌"))

-- addresses from the file are remembered
local f = io.open(Store:urlFilePath(), "w"); f:write("https://example.com/a.ics\n!https://example.com/h.ics\n"); f:close()
Store.urls = nil
check("file read", #Store:getUrls() == 2 and Store:getSettings().urls_had_file == true)

-- the file vanishes, no cache, no backup
os.remove(Store:urlFilePath())
Store.urls = nil
msg, short = Store:noAddressMessage()
check("file vanished -> 없어짐", short == "주소 파일 없음" and msg:find("deskclock_urls.txt)이 없어졌습니다", 1, true) ~= nil)
check("says not Wi-Fi, points to PC", msg:find("Wi%-Fi 문제가 아닙니다") and msg:find("PC로") ~= nil)
print("     message:\n       " .. msg:gsub("\n", "\n       "))

-- only cache files left (e.g. settings from before v4.1 without the flag)
Store:getSettings().urls_had_file = nil
local c = io.open(S .. "/data/deskclock_cache_0a7afecb.ics", "w"); c:write("BEGIN:VCALENDAR\nEND:VCALENDAR\n"); c:close()
local lost, had_file, has_cache = Store:addressesLost()
check("cache only -> lost", lost and not had_file and has_cache)
msg, short = Store:noAddressMessage()
check("cache wording", msg:find("일정 파일은 남아") ~= nil and short == "주소 파일 없음")

-- with a backup that has addresses -> point to restore
local B = require("dc_battery")
local bf = io.open(B.backupPath(), "w")
bf:write('return { saved_at = 1, settings = { urls_text = "" }, urls_file = "https://example.com/a.ics\\n" }\n'); bf:close()
msg = Store:noAddressMessage()
check("backup -> restore hint", msg:find("설정 백업에서 복원") ~= nil)
print("     message:\n       " .. msg:gsub("\n", "\n       "))

-- sync with no address: kind + short error, no Wi-Fi hint material
local ok, err = Store:sync()
check("sync fails with no_urls kind", ok == false and Store.last_fail_kind == "no_urls" and Store:getSettings().last_error == "주소 파일 없음")

-- the own file is lost later: falls back to KOReader's copy rather than empty
files[own] = nil
Store.settings = nil
kosettings.deskclock.wake_hours = 3
check("own file lost -> KOReader copy", Store:getSettings().wake_hours == 3)

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
