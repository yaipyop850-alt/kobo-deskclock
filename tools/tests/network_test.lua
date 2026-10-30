local PLUGIN = (arg[0]:match("^(.*)/[^/]*$") or ".") .. "/../../deskclock.koplugin"
package.path = PLUGIN .. "/?.lua;" .. package.path
local queue = {}
local shown = {}
local UI = { show=function(_, w) shown[#shown+1] = w.text end, close=function() end, forceRePaint=function() end,
  scheduleIn=function(_, t, f, ...) queue[#queue+1] = {f, {...}} end, nextTick=function(_, f) f() end }
local NM = {}
local function stub(name, v) package.loaded[name] = v end
stub("ui/uimanager", UI); stub("ui/network/manager", NM)
stub("dispatcher", {registerAction=function() end})
local function cls() local c = {} c.__index=c function c:extend(o) o=o or {} o.__index=o return setmetatable(o,{__index=self}) end function c:new(o) return setmetatable(o or {}, self) end return c end
stub("ui/widget/infomessage", cls()); stub("ui/widget/inputdialog", cls()); stub("ui/widget/confirmbox", cls())
stub("ui/widget/container/widgetcontainer", cls())
stub("dc_store", {}); stub("dc_widget", {}); stub("dc_update", {}); stub("dc_ics", {})
local DeskClock = dofile(PLUGIN .. "/main.lua")
local function run(desc, setup, keep)
  queue, shown = {}, {}
  local st = setup()
  local ran = false
  DeskClock.withOnline({}, "업데이트 확인", function() ran = true end, keep)
  local n = 0
  while #queue > 0 and n < 500 do local q = table.remove(queue, 1); q[1](unpack(q[2])); n = n + 1 end
  print(string.format("%-34s ran=%-5s wifi_off_called=%-5s msgs=%s", desc, tostring(ran), tostring(st.off), table.concat(shown, " / "):gsub("\n"," ")))
end
run("connected+online", function() local st={} NM.isConnected=function() return true end NM.isOnline=function() return true end NM.disableWifi=function() st.off=true end return st end)
run("connected, DNS late (3 polls)", function() local st={n=0} NM.isConnected=function() return true end NM.isOnline=function() st.n=st.n+1 return st.n>3 end NM.disableWifi=function() st.off=true end return st end)
run("wifi off -> turn on -> online", function() local st={on=false} NM.isConnected=function() return st.on end NM.isOnline=function() return st.on end NM.enableWifi=function() st.on=true return true end NM.disableWifi=function() st.off=true end return st end)
run("wifi off, update keeps wifi", function() local st={on=false} NM.isConnected=function() return st.on end NM.isOnline=function() return st.on end NM.enableWifi=function() st.on=true return true end NM.disableWifi=function() st.off=true end return st end, true)
run("never online (timeout)", function() local st={} NM.isConnected=function() return true end NM.isOnline=function() return false end NM.disableWifi=function() st.off=true end return st end)
