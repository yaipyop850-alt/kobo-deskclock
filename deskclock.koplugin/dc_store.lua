--[[--
Calendar data store: settings, Google Calendar ICS download, local cache,
and expanded occurrences for the desk clock / calendar screen.
--]]

local DataStorage = require("datastorage")
local ICS = require("dc_ics")
local logger = require("logger")

local DAY = 86400

local function lfs_attr(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then return nil end
    return lfs.attributes(path)
end

local CalStore = {
    VERSION = "2.9",
    settings_key = "deskclock",
    urls = nil,           -- cached URL list (re-read on load/sync)
    urls_source = nil,
    stats = {},           -- diagnostics from the last load
    events = {},          -- parsed raw events (all calendars)
    occurrences = {},     -- expanded occurrences in the current window
    holiday_days = {},    -- [day_start] = { names }
    window_start = nil,
    window_end = nil,
}

local defaults = {
    urls_text = "",
    offset_hours = 9,      -- Asia/Seoul
    sync_hours = 1,        -- 0 = manual only
    last_sync = nil,       -- UTC epoch
    last_error = nil,
    mode = "clock",        -- "clock" | "calendar"
}

function CalStore:getSettings()
    if not self.settings then
        local s = G_reader_settings:readSetting(self.settings_key) or {}
        for k, v in pairs(defaults) do
            if s[k] == nil then s[k] = v end
        end
        self.settings = s
    end
    return self.settings
end

function CalStore:save()
    G_reader_settings:saveSetting(self.settings_key, self.settings)
    -- Write to disk now: KOReader otherwise only flushes on exit/suspend.
    if G_reader_settings.flush then G_reader_settings:flush() end
end

function CalStore:set(key, value)
    self:getSettings()[key] = value
    self:save()
end

function CalStore:offset()
    return (self:getSettings().offset_hours or 9) * 3600
end

--- Current time as local epoch (see ics.lua).
function CalStore:now()
    return os.time() + self:offset()
end

function CalStore:urlFilePath()
    return DataStorage:getDataDir() .. "/deskclock_urls.txt"
end

-- Cache file per URL (not per line number), so reordering lines is harmless.
local function urlHash(url)
    local h = 5381
    for i = 1, #url do
        h = (h * 33 + url:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

local function cachePath(url)
    return DataStorage:getSettingsDir() .. "/deskclock_cache_" .. urlHash(url) .. ".ics"
end
CalStore.cachePath = cachePath

--- Read the list of calendar URLs.
-- A file named deskclock_urls.txt in the KOReader folder takes priority over
-- the text entered in the menu. One URL per line, '#' starts a comment,
-- a leading '!' marks a holiday calendar.
-- @return list of { url = ..., holiday = bool }, source ("file" | "menu")
function CalStore:getUrls()
    if self.urls then return self.urls, self.urls_source end
    local text, source
    local f = io.open(self:urlFilePath(), "r")
    if f then
        text = f:read("*a")
        f:close()
        source = "file"
    else
        text = self:getSettings().urls_text or ""
        source = "menu"
    end
    local list = {}
    for line in text:gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local holiday = false
            if line:sub(1, 1) == "!" then
                holiday = true
                line = line:sub(2):gsub("^%s+", "")
            end
            -- Google shows webcal:// in some places; it is the same feed over https.
            line = line:gsub("^webcal://", "https://")
            if line:match("^https?://") then
                table.insert(list, { url = line, holiday = holiday })
            end
        end
    end
    self.urls, self.urls_source = list, source
    return list, source
end

-- Turn LuaSocket's English network errors into something actionable.
local function explainNetError(err)
    err = tostring(err or "")
    local low = err:lower()
    if low:find("host or service not provided") or low:find("not known")
            or low:find("name or service") or low:find("temporary failure in name resolution") then
        return "서버 이름을 찾지 못함(DNS) — Wi-Fi가 인터넷에 연결됐는지 확인"
    elseif low:find("timeout") or low:find("timed out") then
        return "응답 시간 초과 — Wi-Fi 신호 확인 후 재시도"
    elseif low:find("refused") then
        return "연결 거부됨"
    elseif low:find("certificate") or low:find("handshake") or low:find("ssl") then
        return "보안 연결(SSL) 실패 — 기기 시각이 맞는지 확인 (" .. err .. ")"
    end
    return err
end

-- Resolve a redirect Location against the URL it came from.
local function resolveLocation(base, loc)
    if loc:match("^https?://") then return loc end
    local scheme, host = base:match("^(https?)://([^/]+)")
    if not scheme then return loc end
    if loc:sub(1, 2) == "//" then return scheme .. ":" .. loc end
    if loc:sub(1, 1) == "/" then return scheme .. "://" .. host .. loc end
    local dir = base:match("^(.*/)") or (scheme .. "://" .. host .. "/")
    return dir .. loc
end

--- Download one URL straight into a file (keeps memory low on the device).
-- @return true or nil, error
local function download(url, path)
    local socket = require("socket")
    local socketutil = require("socketutil")
    local http = require("socket.http")
    local ok_https, https = pcall(require, "ssl.https")

    -- Check name resolution first so the message says what is actually wrong.
    local host = url:match("^https?://([^/:]+)")
    if not host then return nil, "주소 형식 오류 (https://로 시작해야 함)" end
    if socket.dns and socket.dns.toip then
        local ip = socket.dns.toip(host)
        if not ip then
            return nil, "서버 이름을 찾지 못함(DNS: " .. host .. ") — Wi-Fi가 인터넷에 연결됐는지 확인"
        end
    end

    for _ = 1, 4 do -- follow up to 3 redirects (Apps Script uses one)
        local handle = io.open(path, "wb")
        if not handle then return nil, "저장 공간에 쓸 수 없음" end
        local requester = (url:match("^https://") and ok_https) and https or http
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        -- request() returns (1, code, headers, status) or (nil, error message)
        local ok, r, code, headers = pcall(requester.request, {
            url = url,
            method = "GET",
            sink = socketutil.file_sink(handle),
        })
        socketutil:reset_timeout()
        pcall(handle.close, handle) -- file_sink normally closes it already
        if not ok then
            return nil, explainNetError(r)
        end
        if not r then
            return nil, explainNetError(code)
        end
        if code == 200 then
            return true
        elseif (code == 301 or code == 302 or code == 303 or code == 307 or code == 308)
                and headers and headers.location then
            url = resolveLocation(url, headers.location)
        elseif code == 404 then
            return nil, "주소 없음(404) — 비공개 주소를 다시 복사하세요"
        elseif code == 403 or code == 401 then
            return nil, "접근 거부(" .. code .. ") — 공개되지 않은 캘린더의 공개 주소일 수 있음. 비공개 주소 사용"
        else
            return nil, "HTTP " .. tostring(code)
        end
    end
    return nil, "리디렉션이 너무 많음"
end

local function looksLikeICS(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(256) or ""
    f:close()
    return head:find("BEGIN:VCALENDAR", 1, true) ~= nil
end

--- Download all calendars and refresh the cache. Blocking.
-- @return true on (at least partial) success, or false, message
function CalStore:sync()
    self.urls = nil -- pick up edits to deskclock_urls.txt
    local urls = self:getUrls()
    if #urls == 0 then
        self:set("last_error", "캘린더 주소 없음")
        return false, "등록된 캘린더 주소가 없습니다."
    end
    local errors = {}
    local got = 0
    for i, item in ipairs(urls) do
        local final = cachePath(item.url)
        local tmp = final .. ".part"
        local ok, err = download(item.url, tmp)
        if ok and looksLikeICS(tmp) then
            os.remove(final)
            os.rename(tmp, final)
            got = got + 1
        else
            os.remove(tmp)
            local msg = err or "캘린더(ICS) 형식이 아님 — 주소 확인"
            logger.warn("deskclock: sync failed", i, msg)
            table.insert(errors, i .. "번: " .. msg)
        end
    end
    local s = self:getSettings()
    if got > 0 then
        s.last_sync = os.time()
    end
    s.last_error = #errors > 0 and table.concat(errors, ", ") or nil
    self:save()
    self:load()
    if got == 0 then
        return false, "동기화 실패 (" .. s.last_error .. ")"
    end
    return true, s.last_error and ("일부 실패: " .. s.last_error) or nil
end

--- Load cached ICS files into memory and expand occurrences.
function CalStore:load()
    self.urls = nil
    local urls = self:getUrls()
    local offset = self:offset()
    local t0 = os.clock()
    -- Keep a margin before the display window so old one-offs are dropped.
    -- Keep about a year of past one-off events, so past dates can be looked up.
    local min_stop = ICS.dayStart(self:now()) - 400 * DAY
    self.min_stop = min_stop
    self.events = {}
    self.stats = { files = {}, parse_errors = 0 }
    for i, item in ipairs(urls) do
        local path = cachePath(item.url)
        local ok, evs, pinfo = pcall(ICS.parseFile, path, offset, min_stop)
        local info = { index = i, holiday = item.holiday }
        local attr = lfs_attr(path)
        info.size = attr and attr.size
        if ok and evs then
            info.events = #evs
            if pinfo then
                info.total = pinfo.total
                info.calname = pinfo.calname
                info.last_modified = pinfo.last_modified
                info.last_summary = pinfo.last_summary
                info.last_start = pinfo.last_start
                info.last_allday = pinfo.last_allday
            end
            for _, ev in ipairs(evs) do
                ev.holiday = item.holiday
                -- D-day marker at the start of the title: "[D] 2차 지필고사"
                local stripped = ev.summary:gsub("^%s*%[[Dd]%]%s*", "", 1)
                if stripped == ev.summary then stripped = ev.summary:gsub("^%s*%[디데이%]%s*", "", 1) end
                if stripped ~= ev.summary then
                    ev.dday = true
                    ev.summary = stripped ~= "" and stripped or "D-day"
                end
                table.insert(self.events, ev)
            end
        elseif not ok then
            info.error = tostring(evs)
            self.stats.parse_errors = self.stats.parse_errors + 1
            logger.warn("deskclock: parse error", i, evs)
        end
        table.insert(self.stats.files, info)
    end
    self.stats.parse_seconds = os.clock() - t0
    self.window_start = nil
    self.dday_cache = nil
    local t1 = os.clock()
    self:ensureWindow()
    self.stats.expand_seconds = os.clock() - t1
    collectgarbage()
end

--- Make sure occurrences cover from 6 weeks back to ~3 months ahead.
--- Make sure occurrences cover today's range (and `base`'s, when given:
-- a date picked or a month browsed on the calendar).
function CalStore:ensureWindow(force, base)
    local today = ICS.dayStart(self:now())
    local ws = today - 45 * DAY
    local we = today + 100 * DAY
    if base then
        base = ICS.dayStart(base)
        ws = math.min(ws, base - 14 * DAY)
        we = math.max(we, base + 45 * DAY)
    end
    if self.window_start and not force then
        -- never shrink a window that is already wider
        ws = math.min(ws, self.window_start)
        we = math.max(we, self.window_end)
    end
    if not force and self.window_start and self.window_start <= ws and self.window_end >= we then
        return
    end
    -- Past one-off events older than what was parsed are not available.
    if self.min_stop and ws < self.min_stop then ws = self.min_stop end
    -- expand holiday and normal events separately so we can tag them
    local normal, holiday = {}, {}
    for _, ev in ipairs(self.events) do
        table.insert(ev.holiday and holiday or normal, ev)
    end
    local offset = self:offset()
    self.occurrences = ICS.expand(normal, ws, we, offset)
    self.holiday_days = {}
    self.holiday_occurrences = ICS.expand(holiday, ws, we, offset)
    for _, o in ipairs(self.holiday_occurrences) do
        local d = ICS.dayStart(o.start)
        local last = o.stop > o.start and ICS.dayStart(o.stop - 1) or d
        while d <= last do
            self.holiday_days[d] = self.holiday_days[d] or {}
            table.insert(self.holiday_days[d], o.summary)
            d = d + DAY
        end
    end
    self.window_start, self.window_end = ws, we
end

--- Upcoming D-day targets (events whose title starts with [D]), nearest first.
-- @return list of { summary, day, days_left }
function CalStore:ddays(limit)
    local today = ICS.dayStart(self:now())
    if not self.dday_cache or self.dday_cache_day ~= today then
        local marked = {}
        for _, ev in ipairs(self.events) do
            if ev.dday then table.insert(marked, ev) end
        end
        local list, seen = {}, {}
        for _, o in ipairs(ICS.expand(marked, today, today + 400 * DAY, self:offset())) do
            local day = ICS.dayStart(o.start)
            -- last day the event covers (all-day ends are exclusive)
            local last = ICS.dayStart(math.max(o.start, o.stop - 1))
            if last >= today and not seen[o.summary] then
                seen[o.summary] = true
                local item = { summary = o.summary, day = day,
                    days_left = math.max(0, math.floor((day - today) / DAY)) }
                if day < today then
                    -- multi-day event already under way: "3일 중 2일째"
                    item.ongoing = true
                    item.nth = math.floor((today - day) / DAY) + 1
                    item.total = math.floor((last - day) / DAY) + 1
                end
                table.insert(list, item)
            end
        end
        -- ongoing ones first, then nearest
        table.sort(list, function(a, b)
            if (a.ongoing or false) ~= (b.ongoing or false) then return a.ongoing == true end
            return a.day < b.day
        end)
        self.dday_cache, self.dday_cache_day = list, today
    end
    local out = {}
    for i = 1, math.min(limit or #self.dday_cache, #self.dday_cache) do out[i] = self.dday_cache[i] end
    return out
end

function CalStore:eventsOnDay(day_start)
    return ICS.onDay(self.occurrences, day_start)
end

function CalStore:holidaysOnDay(day_start)
    return self.holiday_days[day_start]
end

--- Upcoming (not yet finished) timed/all-day events from now, up to `limit`.
function CalStore:upcoming(limit, horizon_days)
    local now = self:now()
    local horizon = ICS.dayStart(now) + (horizon_days or 2) * DAY
    local list = {}
    for _, o in ipairs(self.occurrences) do
        if o.start >= horizon then break end
        local ends = o.stop > o.start and o.stop or o.start + 60
        if ends > now then
            table.insert(list, o)
            if #list >= limit then break end
        end
    end
    return list
end

function CalStore:isSyncDue()
    local s = self:getSettings()
    if not s.sync_hours or s.sync_hours <= 0 then return false end
    if #self:getUrls() == 0 then return false end
    return not s.last_sync or (os.time() - s.last_sync) >= s.sync_hours * 3600
end

return CalStore
