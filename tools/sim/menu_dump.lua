-- Dumps the plugin's real KOReader menu (main.lua addToMainMenu) as lines for menu_draw.py.
-- usage: luajit menu_dump.lua <scratch dir with data/> > menu.txt
-- Every KOReader module main.lua needs is replaced by a do-nothing stub; dc_* modules are real.
local P = arg[1] or "."
local here = (arg[0]:match("^(.*)/[^/]*$") or ".")
package.path = here .. "/../../deskclock.koplugin/?.lua;" .. P .. "/?.lua;" .. package.path

local function stub()
    local t = {}
    return setmetatable(t, { __index = function(_, k)
        if k == "extend" or k == "new" then return function(_, o) return setmetatable(o or {}, { __index = t }) end end
        return function() return stub() end
    end, __call = function() return stub() end })
end
table.insert(package.loaders, function(name)
    if name:match("^dc_") then return nil end
    return function() return stub() end
end)
package.loaded["datastorage"] = { getDataDir = function() return P .. "/data" end,
    getSettingsDir = function() return P .. "/data" end }
local settings = { deskclock = { sync_hours = 1, wake_hours = 3, alarm_leads = { 30, 10 }, auto_wifi_sync = true,
    last_sync = os.time{ year = 2026, month = 11, day = 11, hour = 7, min = 10 }, tasks_sync = true } }
G_reader_settings = { readSetting = function(_, k) return settings[k] end,
    saveSetting = function(_, k, v) settings[k] = v end, flush = function() end }
package.loaded["device"] = setmetatable({ isKobo = function() return true end, wakeup_mgr = {},
    rescheduleSuspend = function() end, screen = stub() }, { __index = function() return function() return stub() end end })

local DeskClock = dofile(here .. "/../../deskclock.koplugin/main.lua")
local items = {}
DeskClock.addToMainMenu(DeskClock, items)

local function label(it)
    if it.text_func then return it.text_func() end
    return it.text or "?"
end
local function walk(tbl, depth, path)
    for _, it in ipairs(tbl) do
        local kind = it.sub_item_table and "sub" or (it.radio and "radio" or (it.checked_func and "check" or "item"))
        local checked = it.checked_func and it.checked_func() and "1" or "0"
        local enabled = (it.enabled_func == nil or it.enabled_func()) and "1" or "0"
        print(table.concat({ depth, path, kind, checked, enabled, it.separator and "1" or "0", label(it) }, "\t"))
        if it.sub_item_table then walk(it.sub_item_table, depth + 1, path .. "/" .. label(it)) end
    end
end
local root = items.deskclock
print(table.concat({ 0, "", "sub", "0", "1", "0", root.text .. "  [sorting_hint=" .. root.sorting_hint .. "]" }, "\t"))
walk(root.sub_item_table, 1, root.text)
