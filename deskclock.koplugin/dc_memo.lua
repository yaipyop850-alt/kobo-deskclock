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

function Memo:memos() return self:load().memos end

function Memo:addMemo(text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    local m = { id = newId(self), text = text, created = os.time() }
    table.insert(self:load().memos, 1, m)
    self:save()
    return m
end

function Memo:updateMemo(id, text)
    for _, m in ipairs(self:load().memos) do
        if m.id == id then
            m.text = text
            m.edited = os.time()
            self:save()
            return true
        end
    end
end

function Memo:deleteMemo(id)
    local list = self:load().memos
    for i, m in ipairs(list) do
        if m.id == id then
            table.remove(list, i)
            self:save()
            return true
        end
    end
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
                it.error = "쓰기 주소(>로 시작하는 줄) 미설정"
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

--- Connection test (GET). @return message
function Memo:test(post_url)
    if not post_url then return "쓰기 주소가 없습니다. deskclock_urls.txt에 >로 시작하는 줄을 추가하세요." end
    local text, err = request(post_url, "GET")
    if not text then return "연결 실패: " .. tostring(err) end
    if text:match("^OK") then
        local tz = text:match("tz=(%S+)")
        local cal = text:match("cal=(.+)$")
        local msg = "연결 정상\n캘린더: " .. tostring(cal) .. "\n시간대: " .. tostring(tz)
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
