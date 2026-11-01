--[[--
Memos (undated notes, kept on the device) and an outbox of events to add to
Google Calendar through the owner's Apps Script web app.

Outbox life cycle:
  pending  -> sent (Apps Script answered OK) -> removed once the event shows up
  in the downloaded calendar (or 3 days after sending).
Until then the event is shown on the device calendar with a "◇" mark.
--]]

local DataStorage = require("datastorage")
local ICS = require("dc_ics")
local logger = require("logger")

local DAY = 86400
local KEEP_SENT_SECONDS = 3 * DAY

local Memo = {}

local function path()
    return DataStorage:getSettingsDir() .. "/deskclock_memos.lua"
end

function Memo:load()
    if self.data then return self.data end
    local ok, LuaSettings = pcall(require, "luasettings")
    if ok then
        self.file = LuaSettings:open(path())
        self.data = {
            memos = self.file:readSetting("memos") or {},
            outbox = self.file:readSetting("outbox") or {},
            seq = self.file:readSetting("seq") or 0,
        }
    else
        self.data = { memos = {}, outbox = {}, seq = 0 }
    end
    return self.data
end

function Memo:save()
    if not self.file then return end
    self.file:saveSetting("memos", self.data.memos)
    self.file:saveSetting("outbox", self.data.outbox)
    self.file:saveSetting("seq", self.data.seq)
    self.file:flush()
end

local function newId(self)
    local d = self:load()
    d.seq = d.seq + 1
    return string.format("%d-%d", os.time(), d.seq)
end

---------------------------------------------------------------- memos
-- A memo doubles as a to-do: { id, text, created, edited, done, done_at,
--   task_id (Google Tasks id once synced), dirty (changed on the device since
--   the last Tasks sync), deleted (tombstone until the deletion is synced) }

local function touch(m)
    m.dirty = true
    m.edited = os.time()
end

--- Visible memos: open ones first (in their order), then done ones (latest first).
function Memo:memos()
    local open, done = {}, {}
    for _, m in ipairs(self:load().memos) do
        if not m.deleted then table.insert(m.done and done or open, m) end
    end
    table.sort(done, function(a, b) return (a.done_at or 0) > (b.done_at or 0) end)
    for _, m in ipairs(done) do open[#open + 1] = m end
    return open
end

function Memo:openCount()
    local n = 0
    for _, m in ipairs(self:load().memos) do
        if not m.deleted and not m.done then n = n + 1 end
    end
    return n
end

function Memo:doneCount()
    local n = 0
    for _, m in ipairs(self:load().memos) do
        if not m.deleted and m.done then n = n + 1 end
    end
    return n
end

local function find(self, id)
    for i, m in ipairs(self:load().memos) do
        if m.id == id then return m, i end
    end
end

function Memo:addMemo(text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    local m = { id = newId(self), text = text, created = os.time() }
    touch(m)
    table.insert(self:load().memos, 1, m)
    self:save()
    return m
end

function Memo:updateMemo(id, text)
    local m = find(self, id)
    if not m then return end
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return self:deleteMemo(id) end
    m.text = text
    touch(m)
    self:save()
    return true
end

function Memo:setDone(id, done)
    local m = find(self, id)
    if not m then return end
    m.done = done and true or nil
    m.done_at = done and os.time() or nil
    touch(m)
    self:save()
    return true
end

function Memo:toggleDone(id)
    local m = find(self, id)
    if m then return self:setDone(id, not m.done) end
end

function Memo:deleteMemo(id)
    local m, i = find(self, id)
    if not m then return end
    if m.task_id then
        -- keep a tombstone so the Google task is removed at the next sync
        m.deleted = true
        touch(m)
    else
        table.remove(self:load().memos, i)
    end
    self:save()
    return true
end

--- Delete every done item. @return number removed
function Memo:clearDone()
    local ids = {}
    for _, m in ipairs(self:load().memos) do
        if m.done and not m.deleted then ids[#ids + 1] = m.id end
    end
    for _, id in ipairs(ids) do self:deleteMemo(id) end
    return #ids
end

--- True when this memo has changes Google Tasks has not seen yet.
function Memo:isUnsynced(m)
    return m.dirty or not m.task_id
end

---------------------------------------------------------------- outbox

function Memo:outbox() return self:load().outbox end

--- @param ev { title, date = "YYYY-MM-DD", time = "HH:MM" or nil, minutes }
function Memo:addEvent(ev)
    local item = {
        uid = "dc-" .. newId(self),
        title = ev.title, date = ev.date, time = ev.time, minutes = ev.minutes or 60,
        created = os.time(), state = "pending",
    }
    table.insert(self:load().outbox, item)
    self:save()
    return item
end

function Memo:removeEvent(uid)
    local list = self:load().outbox
    for i, it in ipairs(list) do
        if it.uid == uid then
            table.remove(list, i)
            self:save()
            return true
        end
    end
end

function Memo:pendingCount()
    local n = 0
    for _, it in ipairs(self:load().outbox) do
        if it.state ~= "sent" then n = n + 1 end
    end
    return n
end

local function dayOf(it)
    local y, m, d = it.date:match("^(%d+)-(%d+)-(%d+)$")
    if not y then return nil end
    return ICS.timegm(tonumber(y), tonumber(m), tonumber(d))
end

--- Occurrences for outbox items not yet visible in the downloaded calendar.
-- @param feed occurrences from Google (to hide items that already arrived)
function Memo:localOccurrences(feed)
    local seen = {}
    for _, o in ipairs(feed or {}) do
        seen[ICS.dayStart(o.start) .. "|" .. o.summary] = true
    end
    local out = {}
    for _, it in ipairs(self:load().outbox) do
        local day = dayOf(it)
        if day and not seen[day .. "|" .. it.title] then
            local o = { summary = "◇ " .. it.title, pending = true, uid = it.uid }
            if it.time then
                local h, mi = it.time:match("^(%d+):(%d+)$")
                o.start = day + tonumber(h) * 3600 + tonumber(mi) * 60
                o.stop = o.start + (it.minutes or 60) * 60
                o.allday = false
            else
                o.start, o.stop, o.allday = day, day + DAY, true
            end
            table.insert(out, o)
        end
    end
    return out
end

--- Drop sent items that arrived in the feed, or were sent long ago.
function Memo:cleanup(feed)
    local seen = {}
    for _, o in ipairs(feed or {}) do
        seen[ICS.dayStart(o.start) .. "|" .. o.summary] = true
    end
    local list = self:load().outbox
    local changed = false
    for i = #list, 1, -1 do
        local it = list[i]
        local day = dayOf(it)
        if it.state == "sent" and ((day and seen[day .. "|" .. it.title])
                or os.time() - (it.sent_at or 0) > KEEP_SENT_SECONDS) then
            table.remove(list, i)
            changed = true
        end
    end
    if changed then self:save() end
end

---------------------------------------------------------------- network

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function form(t)
    local parts = {}
    for k, v in pairs(t) do
        if v ~= nil then table.insert(parts, urlencode(k) .. "=" .. urlencode(v)) end
    end
    return table.concat(parts, "&")
end

--- HTTP request with redirects. Apps Script answers a POST with a 302 that
-- must be followed with GET.
local function request(url, method, body)
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local http = require("socket.http")
    local ok_https, https = pcall(require, "ssl.https")
    for _ = 1, 5 do
        local chunks = {}
        local req = { url = url, method = method, sink = socketutil.table_sink(chunks) }
        if method == "POST" then
            req.source = ltn12.source.string(body)
            req.headers = {
                ["content-type"] = "application/x-www-form-urlencoded",
                ["content-length"] = tostring(#body),
            }
        end
        local requester = (url:match("^https://") and ok_https) and https or http
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local ok, r, code, headers = pcall(requester.request, req)
        socketutil:reset_timeout()
        if not ok then return nil, tostring(r) end
        if not r then return nil, tostring(code) end
        if code == 200 then return table.concat(chunks) end
        if (code == 301 or code == 302 or code == 303 or code == 307) and headers and headers.location then
            url = headers.location
            method, body = "GET", nil
        else
            return nil, "HTTP " .. tostring(code)
        end
    end
    return nil, "too many redirects"
end

local ERRORS = {
    ["ERR key"] = "비밀 키 불일치 — 주소의 key= 값 확인",
    ["ERR secret-not-set"] = "Apps Script의 SECRET 값을 바꾸지 않음",
    ["ERR date"] = "날짜 형식 오류",
    ["ERR title"] = "제목이 비어 있음",
}

--- Send every unsent item. Blocking; call only when online.
-- @return sent_count, error_message_or_nil
function Memo:flush(post_url)
    local list = self:load().outbox
    local sent, last_err = 0, nil
    for _, it in ipairs(list) do
        if it.state ~= "sent" then
            if not post_url then
                it.error = "쓰기 주소 미설정 (deskclock_write.txt)"
                last_err = it.error
            else
                local text, err = request(post_url, "POST", form{
                    action = "add", uid = it.uid, title = it.title,
                    date = it.date, time = it.time, minutes = it.time and it.minutes or nil,
                })
                if text and text:match("^OK") then
                    it.state, it.sent_at, it.error = "sent", os.time(), nil
                    sent = sent + 1
                else
                    local msg = text and (ERRORS[text:match("^ERR [%w%-]+") or ""] or text:sub(1, 60)) or err
                    it.error = msg
                    last_err = msg
                    logger.warn("deskclock: send failed", it.uid, msg)
                end
            end
        end
    end
    self:save()
    return sent, last_err
end

---------------------------------------------------------------- Google Tasks
-- Text protocol (no JSON library needed on either side):
--   request  data = lines  "U\t<memo id>\t<task id or empty>\t<0|1 done>\t<title>\t<notes>"
--                          "D\t<task id>"
--   response "OK tasks" then lines "M\t<memo id>\t<task id>" (where each U went)
--                                  "T\t<task id>\t<0|1>\t<title>\t<notes>" (every task now)
-- The device wins: its changes are applied first, then everything else is
-- taken from Google.

local function esc(s)
    return (tostring(s or ""):gsub("\\", "\\\\"):gsub("\t", "\\t"):gsub("\r", ""):gsub("\n", "\\n"))
end

local function unesc(s)
    return (s:gsub("\\(.)", function(c)
        if c == "n" then return "\n" elseif c == "t" then return "\t" end
        return c
    end))
end

local function split(line)
    local f = {}
    for part in (line .. "\t"):gmatch("(.-)\t") do f[#f + 1] = part end
    return f
end

local function toTask(text)
    local title, notes = text:match("^([^\n]*)\n?(.*)$")
    return title, notes or ""
end

local function fromTask(title, notes)
    if notes and notes ~= "" then return title .. "\n" .. notes end
    return title
end

function Memo:tasksRequest()
    local lines, sent = {}, {}
    for _, m in ipairs(self:load().memos) do
        if m.deleted then
            if m.task_id then lines[#lines + 1] = "D\t" .. esc(m.task_id) end
            sent[#sent + 1] = m
        elseif self:isUnsynced(m) then
            local title, notes = toTask(m.text)
            lines[#lines + 1] = table.concat({ "U", esc(m.id), esc(m.task_id or ""),
                m.done and "1" or "0", esc(title), esc(notes) }, "\t")
            sent[#sent + 1] = m
        end
    end
    return table.concat(lines, "\n"), sent
end

--- Merge the server answer. @return number of changes from Google
function Memo:applyTasksResponse(text, sent)
    local d = self:load()
    local map, server, order = {}, {}, {}
    for line in text:gmatch("[^\n]+") do
        local f = split(line)
        if f[1] == "M" and f[2] and f[3] then
            map[unesc(f[2])] = unesc(f[3])
        elseif f[1] == "T" and f[2] then
            local id = unesc(f[2])
            server[id] = { done = f[3] == "1", title = unesc(f[4] or ""), notes = unesc(f[5] or "") }
            order[#order + 1] = id
        end
    end
    local was_sent = {}
    for _, m in ipairs(sent) do was_sent[m] = true end
    local changes = 0
    local known = {}
    for i = #d.memos, 1, -1 do
        local m = d.memos[i]
        if m.deleted and was_sent[m] then
            table.remove(d.memos, i)
        else
            if map[m.id] then m.task_id = map[m.id] end
            if was_sent[m] then m.dirty = nil end
            if m.task_id then
                local t = server[m.task_id]
                if not t then
                    if not m.dirty then
                        -- deleted on the phone
                        table.remove(d.memos, i)
                        changes = changes + 1
                    end
                else
                    known[m.task_id] = true
                    if not m.dirty then
                        local text = fromTask(t.title, t.notes)
                        if text ~= m.text or (t.done and true or nil) ~= m.done then
                            m.text = text
                            if t.done and not m.done then m.done_at = os.time() end
                            m.done = t.done and true or nil
                            if not m.done then m.done_at = nil end
                            changes = changes + 1
                        end
                    end
                end
            end
        end
    end
    -- tasks added on the phone
    for k = #order, 1, -1 do
        local tid = order[k]
        if not known[tid] then
            local t = server[tid]
            local m = { id = newId(self), task_id = tid, text = fromTask(t.title, t.notes),
                created = os.time(), done = t.done and true or nil, done_at = t.done and os.time() or nil }
            table.insert(d.memos, 1, m)
            changes = changes + 1
        end
    end
    self:save()
    return changes
end

--- Two-way sync of memos with Google Tasks ("내 할 일"). Blocking.
-- @return true, changes | nil, error message
function Memo:syncTasks(post_url)
    if not post_url then return nil, "쓰기 주소 없음" end
    local data, sent = self:tasksRequest()
    local text, err = request(post_url, "POST", form{ action = "tasks", data = data })
    if not text then return nil, err end
    if not text:match("^OK tasks") then
        local code = text:match("^ERR [%w%-]+") or ""
        if code == "ERR action" then
            return nil, "Apps Script가 예전 코드 — 새 Code.gs로 바꾸고 새 버전 배포"
        elseif code == "ERR tasks-off" then
            return nil, "Apps Script에 Tasks 서비스가 추가되지 않음"
        end
        return nil, ERRORS[code] or text:sub(1, 60)
    end
    return true, self:applyTasksResponse(text, sent)
end

Memo._esc, Memo._unesc = esc, unesc

--- Connection test (GET). @return message
function Memo:test(post_url, write_path)
    if not post_url then
        return "쓰기 주소가 없습니다.\n\n찾아본 파일: " .. tostring(write_path or "deskclock_write.txt")
            .. "\n\nPC 없이 넣으려면: 구글 캘린더에 제목이 쓰기 주소(https://script.google.com/…/exec?key=…)인 일정을 오늘 날짜로 만들고 [지금 동기화]를 하세요."
    end
    local text, err = request(post_url, "GET")
    if not text then return "연결 실패: " .. tostring(err) end
    if text:match("^OK") then
        local tz = text:match("tz=(%S+)")
        local cal = text:match("cal=(.+)$")
        local tasks = text:match("tasks=(%S+)")
        local msg = "연결 정상\n캘린더: " .. tostring(cal) .. "\n시간대: " .. tostring(tz)
            .. "\n구글 할 일: " .. (tasks == "ok" and "연결됨"
                or tasks and "Tasks 서비스 미추가 (가이드 3단계)"
                or "Apps Script가 예전 코드 (할 일 동기화 안 됨)")
        if tz ~= "Asia/Seoul" then
            msg = msg .. "\n\n※ Apps Script 프로젝트 시간대를 서울로 바꾸세요 (종일 일정 날짜가 밀릴 수 있음)"
        end
        return msg
    end
    return "오류: " .. (ERRORS[text:match("^ERR [%w%-]+") or ""] or text:sub(1, 80))
end

Memo._form = form
Memo._request = request
return Memo
