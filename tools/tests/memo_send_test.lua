local S = arg[1]
local PLUGIN = (arg[0]:match("^(.*)/[^/]*$") or ".") .. "/../../deskclock.koplugin"
package.path = PLUGIN .. "/?.lua;" .. package.path
local log, created = {}, {}
local SECRET = "abc123"
local function req(t)
  local u = t.url
  if u:find("^https://script.google.com/macros/s/X/exec") then
    if t.method == "POST" then
      local body = {}; local chunk = t.source(); while chunk do body[#body+1]=chunk; chunk=t.source() end
      body = table.concat(body)
      local key = u:match("key=([^&]+)")
      local params = {}; for k,v in body:gmatch("([^&=]+)=([^&]*)") do params[k]=v:gsub("%%(%x%x)",function(h) return string.char(tonumber(h,16)) end) end
      local res
      if key ~= SECRET then res = "ERR key" elseif created[params.uid] then res = "OK dup" else created[params.uid]=params; res="OK id1" end
      log[#log+1] = "POST "..(params.title or "").." "..(params.date or "").." "..(params.time or "종일").." -> 302"
      _G.__next = res
      t.sink(nil); return 1, 302, { location = "https://script.googleusercontent.com/macros/echo?x=1" }
    else
      t.sink("OK tz=Asia/Seoul cal=내 캘린더"); t.sink(nil); return 1, 200, {}
    end
  elseif u:find("googleusercontent") then
    assert(t.method == "GET", "redirect must be followed with GET")
    log[#log+1] = "GET echo -> " .. _G.__next
    t.sink(_G.__next); t.sink(nil); return 1, 200, {}
  end
  return nil, "no route"
end
package.loaded["socket.http"] = {request=req}
package.loaded["ssl.https"] = {request=req}
package.loaded["ltn12"] = {source={string=function(s) local done=false return function() if done then return nil end done=true return s end end}}
package.loaded["socketutil"] = {LARGE_BLOCK_TIMEOUT=1, LARGE_TOTAL_TIMEOUT=1, set_timeout=function() end, reset_timeout=function() end,
  table_sink=function(t) return function(c) if c then t[#t+1]=c end return 1 end end}
package.loaded["logger"] = {warn=function() end}
package.loaded["datastorage"] = {getSettingsDir=function() return S.."/data" end, getDataDir=function() return S.."/data" end}
package.loaded["luasettings"] = {open=function() local t={d={}} function t:readSetting(k) return self.d[k] end function t:saveSetting(k,v) self.d[k]=v end function t:flush() end return t end}
local M = require("dc_memo")
local ICS = require("dc_ics")
M:addEvent{ title = "교과서 선정 협의 & 회의", date = "2026-11-04", time = "15:00", minutes = 60 }
M:addEvent{ title = "감독표 제출", date = "2026-11-06" }
print("pending:", M:pendingCount())
print("wrong key:", M:flush("https://script.google.com/macros/s/X/exec?key=WRONG"))
print("  error stored:", M:outbox()[1].error)
print("right key:", M:flush("https://script.google.com/macros/s/X/exec?key=abc123"))
for _, l in ipairs(log) do print("  " .. l) end
print("pending after:", M:pendingCount(), "states:", M:outbox()[1].state, M:outbox()[2].state)
print("resend (should not duplicate):", M:flush("https://script.google.com/macros/s/X/exec?key=abc123"))
local n=0 for _ in pairs(created) do n=n+1 end print("events created on server:", n, "title roundtrip:", created[M:outbox()[1].uid].title)
-- local occurrence shown until feed has it
local feed = {}
print("local occ before feed:", #M:localOccurrences(feed))
feed = { { start = ICS.timegm(2026,11,4)+15*3600, stop = ICS.timegm(2026,11,4)+16*3600, summary = "교과서 선정 협의 & 회의" } }
print("local occ after one arrived:", #M:localOccurrences(feed))
M:cleanup(feed); print("outbox after cleanup:", #M:outbox())
print("test():", (M:test("https://script.google.com/macros/s/X/exec?key=abc123"):gsub("\n"," | ")))
