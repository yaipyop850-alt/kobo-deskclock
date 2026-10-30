local S = arg[1]
local HERE = arg[0]:match("^(.*)/[^/]*$") or "."
local PLUGIN = (arg[0]:match("^(.*)/[^/]*$") or ".") .. "/../../deskclock.koplugin"
package.path = PLUGIN .. "/?.lua;" .. package.path
local function sh(c) local f = io.popen(c) local o = f:read("*a") f:close() return o end
local store = S .. "/store.json"
local function req(t)
  local q = t.url:match("%?(.*)$") or ""
  if t.method == "POST" then
    local body = {}; local chunk = t.source(); while chunk do body[#body+1]=chunk; chunk=t.source() end
    local f = io.open(S.."/body.txt","w") f:write(q.."\n\n"..table.concat(body)) f:close()
    t.sink(sh("node "..HERE.."/tasks_fake_appsscript.js "..store.." POST "..S.."/body.txt")); t.sink(nil); return 1, 200, {}
  end
  t.sink(sh("node "..HERE.."/tasks_fake_appsscript.js "..store.." GET '"..q.."'")); t.sink(nil); return 1, 200, {}
end
package.loaded["socket.http"] = {request=req}
package.loaded["ssl.https"] = {request=req}
package.loaded["ltn12"] = {source={string=function(s) local done=false return function() if done then return nil end done=true return s end end}}
package.loaded["socketutil"] = {LARGE_BLOCK_TIMEOUT=1, LARGE_TOTAL_TIMEOUT=1, set_timeout=function() end, reset_timeout=function() end,
  table_sink=function(t) return function(c) if c then t[#t+1]=c end return 1 end end}
package.loaded["logger"] = {warn=function() end}
package.loaded["datastorage"] = {getSettingsDir=function() return S end, getDataDir=function() return S end}
package.loaded["luasettings"] = {open=function() local t={d={}} function t:readSetting(k) return self.d[k] end function t:saveSetting(k,v) self.d[k]=v end function t:flush() end return t end}
local M = require("dc_memo")
local URL = "https://script.google.com/macros/s/X/exec?key=abc%40%40"
local function phone(op) sh("node "..HERE.."/tasks_fake_appsscript.js "..store.." PHONE '"..op.."'") end
local function server() return sh("node -e \"const s=require('"..store.."');console.log(s.tasks.filter(t=>!t.deleted).map(t=>t.id+':'+t.title+(t.notes?'['+t.notes.replace(/\\n/g,'/')+']':'')+(t.status==='completed'?'(v)':'')).join(' | '))\"") end
local function dev() local o={} for _,m in ipairs(M:memos()) do o[#o+1]=(m.task_id or "-")..":"..m.text:gsub("\n","/")..(m.done and "(v)" or "")..(M:isUnsynced(m) and "*" or "") end return table.concat(o," | ") end
local function step(name) local ok, n = M:syncTasks(URL) print(("%-34s sync=%s %s"):format(name, tostring(ok), tostring(n))) print("   dev: "..dev()) io.write("   srv: "..server()) end

print(M:test(URL))
-- old memos from v3.0 (no task_id/dirty) must be uploaded
local d = M:load(); table.insert(d.memos, {id="old-1", text="옛 메모\n둘째 줄 탭\t포함 \\ 백슬래시", created=1})
M:addMemo("동아시아 탐구활동지 인쇄")
M:addMemo("수행평가 채점 기준 확정")
step("1 first sync (upload all)")
phone('{"add":"세특 초안 검토","notes":"2학년"}')
step("2 phone added a task")
local ids = {} for _,m in ipairs(M:memos()) do ids[m.text:match("^[^\n]*")] = m end
M:setDone(ids["동아시아 탐구활동지 인쇄"].id, true)
step("3 device ticks done")
phone('{"rename":["T1","채점 기준 (폰에서 수정)"]}')
M:updateMemo(ids["수행평가 채점 기준 확정"].id, "채점 기준 (기기에서 수정)")
step("4 conflict: both edited -> device")
phone('{"done":"T1"}')
phone('{"del":"T2"}')
step("5 phone: done T1? del T2(dirty? no)")
M:updateMemo(ids["옛 메모"].id, "옛 메모 수정")
phone('{"del":"T3"}')
step("6 phone deleted + device edited -> recreate")
print("   cleared:", M:clearDone())
step("7 clear done (deletes on server)")
step("8 idle sync (no changes)")
phone('{"off":true}')
print(M:syncTasks(URL)); print(M:test(URL))
