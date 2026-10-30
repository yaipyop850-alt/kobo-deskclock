--[[--
Minimal iCalendar (.ics) parser for Google Calendar's secret iCal feed.

All times are handled as "local epoch": seconds since 1970-01-01 00:00 in the
user's own time zone (UTC epoch + offset). This avoids depending on the
device's TZ configuration, which is unreliable on Kobo.

Supported: VEVENT, DTSTART/DTEND/DURATION, all-day events, SUMMARY, LOCATION,
STATUS:CANCELLED, RRULE (DAILY/WEEKLY/MONTHLY/YEARLY with INTERVAL, COUNT,
UNTIL, BYDAY, BYMONTHDAY, BYMONTH), EXDATE, RECURRENCE-ID overrides.
TZID values are assumed to be the user's time zone (e.g. Asia/Seoul).
--]]

local ICS = {}

local DAY = 86400
local WEEKDAYS = { SU = 0, MO = 1, TU = 2, WE = 3, TH = 4, FR = 5, SA = 6 }

-- Days since 1970-01-01 for a proleptic Gregorian date.
local function daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

function ICS.timegm(y, m, d, h, mi, s)
    return daysFromCivil(y, m, d) * DAY + (h or 0) * 3600 + (mi or 0) * 60 + (s or 0)
end

--- Weekday of a local epoch: 0 = Sunday ... 6 = Saturday.
function ICS.weekday(t)
    return (math.floor(t / DAY) + 4) % 7
end

function ICS.dayStart(t)
    return math.floor(t / DAY) * DAY
end

local function daysInMonth(y, m)
    local ny, nm = y, m + 1
    if nm > 12 then ny, nm = y + 1, 1 end
    return daysFromCivil(ny, nm, 1) - daysFromCivil(y, m, 1)
end
ICS.daysInMonth = daysInMonth

--- Parse an ICS date or date-time value into a local epoch.
-- @return epoch, is_date_only
local function parseDateTime(value, params, offset)
    if not value then return nil end
    local y, m, d = value:match("^(%d%d%d%d)(%d%d)(%d%d)")
    if not y then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    local h, mi, s, z = value:match("T(%d%d)(%d%d)(%d%d)(Z?)")
    if not h then
        return ICS.timegm(y, m, d), true
    end
    local t = ICS.timegm(y, m, d, tonumber(h), tonumber(mi), tonumber(s))
    if z == "Z" then
        t = t + offset
    end
    -- TZID=... or floating time: treated as the user's local time.
    return t, false
end

local function parseDuration(value)
    if not value then return nil end
    local sign = 1
    if value:sub(1, 1) == "-" then sign = -1 end
    local total = 0
    local w = value:match("(%d+)W")
    local d = value:match("(%d+)D")
    local h = value:match("(%d+)H")
    local mi = value:match("T.-(%d+)M")
    local s = value:match("(%d+)S")
    total = (tonumber(w) or 0) * 7 * DAY + (tonumber(d) or 0) * DAY
        + (tonumber(h) or 0) * 3600 + (tonumber(mi) or 0) * 60 + (tonumber(s) or 0)
    return sign * total
end

local function unescapeText(s)
    s = s:gsub("\\[nN]", " "):gsub("\\,", ","):gsub("\\;", ";"):gsub("\\\\", "\\")
    return s
end

--- Split one unfolded content line into name, params table and value.
local function parseLine(line)
    local in_quote = false
    local colon
    for i = 1, #line do
        local c = line:sub(i, i)
        if c == '"' then
            in_quote = not in_quote
        elseif c == ":" and not in_quote then
            colon = i
            break
        end
    end
    if not colon then return nil end
    local head, value = line:sub(1, colon - 1), line:sub(colon + 1)
    local name = head:match("^([^;]+)")
    if not name then return nil end
    local params = {}
    for k, v in head:gmatch(";([^=;]+)=([^;]*)") do
        params[k:upper()] = v:gsub('"', "")
    end
    return name:upper(), params, value
end

local function parseRRule(value)
    local r = {}
    for k, v in value:gmatch("([^=;]+)=([^;]*)") do
        r[k:upper()] = v
    end
    return r
end

--- Core parser over an iterator of raw (possibly folded) lines.
-- @param next_line function returning the next raw line or nil
-- @param offset seconds east of UTC for the user's time zone (KST = 32400)
-- @param min_stop optional local epoch: non-recurring events ending before it are dropped
local function parseLines(next_line, offset, min_stop)
    offset = offset or 32400
    local events = {}
    local cur
    local in_alarm = false
    local calname

    local function handle(line)
        if line == "BEGIN:VEVENT" then
            cur = { exdates = {} }
        elseif line == "END:VEVENT" then
            if cur and cur.start then
                table.insert(events, cur)
            end
            cur = nil
        elseif line == "BEGIN:VALARM" then
            in_alarm = true
        elseif line == "END:VALARM" then
            in_alarm = false
        elseif cur and not in_alarm then
            -- Skip bulky properties we never show before splitting them.
            local c = line:byte(1)
            if c == 68 and line:sub(1, 11) == "DESCRIPTION" then return end -- 'D'
            if c == 65 and line:sub(1, 6) == "ATTACH" then return end       -- 'A'
            local name, params, value = parseLine(line)
            if name == "DTSTART" then
                cur.start, cur.allday = parseDateTime(value, params, offset)
            elseif name == "DTEND" then
                cur.stop = parseDateTime(value, params, offset)
            elseif name == "DURATION" then
                cur.duration = parseDuration(value)
            elseif name == "SUMMARY" then
                cur.summary = unescapeText(value)
            elseif name == "LOCATION" then
                cur.location = unescapeText(value)
            elseif name == "UID" then
                cur.uid = value
            elseif name == "STATUS" then
                cur.status = value:upper()
            elseif name == "RRULE" then
                cur.rrule = parseRRule(value)
            elseif name == "EXDATE" then
                for v in value:gmatch("[^,]+") do
                    local t = parseDateTime(v, params, offset)
                    if t then cur.exdates[t] = true end
                end
            elseif name == "RECURRENCE-ID" then
                cur.recurrence_id = parseDateTime(value, params, offset)
            elseif name == "LAST-MODIFIED" then
                cur.modified = value
            elseif name == "X-WR-CALNAME" then
                -- (only appears outside VEVENT; handled below)
            end
        elseif not cur then
            local name, _, value = parseLine(line)
            if name == "X-WR-CALNAME" then calname = unescapeText(value) end
        end
    end

    -- Unfold continuation lines (RFC 5545 3.1) on the fly.
    local pending
    for raw in next_line do
        raw = raw:gsub("\r$", "")
        local first = raw:sub(1, 1)
        if first == " " or first == "\t" then
            if pending then pending = pending .. raw:sub(2) end
        elseif raw ~= "" then
            if pending then handle(pending) end
            pending = raw
        end
    end
    if pending and pending ~= "" then handle(pending) end

    local kept = {}
    -- Diagnostics: how many events the file had, and which one changed last
    -- (tells whether an event just added in Google has reached the feed).
    local info = { total = #events, calname = calname }
    for _, ev in ipairs(events) do
        if ev.modified and (not info.last_modified or ev.modified > info.last_modified) then
            info.last_modified = ev.modified
            info.last_summary = ev.summary
            info.last_start = ev.start
            info.last_allday = ev.allday
        end
    end
    for _, ev in ipairs(events) do
        if not ev.stop then
            if ev.duration then
                ev.stop = ev.start + ev.duration
            elseif ev.allday then
                ev.stop = ev.start + DAY
            else
                ev.stop = ev.start
            end
        end
        if ev.stop < ev.start then ev.stop = ev.start end
        ev.summary = ev.summary or "(제목 없음)"
        -- Old one-off events are never shown: drop them to save memory.
        -- (Overrides with RECURRENCE-ID are kept so their master skips them.)
        if not min_stop or ev.rrule or ev.recurrence_id or ev.stop >= min_stop then
            table.insert(kept, ev)
        end
    end
    return kept, info
end

--- Parse ICS text (string) into a list of raw events.
function ICS.parse(text, offset, min_stop)
    return parseLines(text:gmatch("[^\n]*"), offset, min_stop)
end

--- Parse an ICS file line by line (does not hold the whole file in memory).
-- @return events, or nil if the file cannot be opened
function ICS.parseFile(path, offset, min_stop)
    local f = io.open(path, "rb")
    if not f then return nil end
    local ok, res, info = pcall(parseLines, f:lines(), offset, min_stop)
    f:close()
    if not ok then error(res) end
    return res, info
end

-- Date of the n-th given weekday in a month (n may be negative = from the end).
local function nthWeekdayOfMonth(y, m, wday, n)
    local first = daysFromCivil(y, m, 1)
    local dim = daysInMonth(y, m)
    if n > 0 then
        local first_wd = (first + 4) % 7
        local day = 1 + (wday - first_wd) % 7 + (n - 1) * 7
        if day > dim then return nil end
        return day
    else
        local last_wd = (first + dim - 1 + 4) % 7
        local day = dim - (last_wd - wday) % 7 + (n + 1) * 7
        if day < 1 then return nil end
        return day
    end
end

local function parseByDay(s)
    local list = {}
    if not s then return list end
    for item in s:gmatch("[^,]+") do
        local n, wd = item:match("^([+-]?%d*)(%u%u)$")
        if wd and WEEKDAYS[wd] then
            table.insert(list, { n = tonumber(n), wday = WEEKDAYS[wd] })
        end
    end
    return list
end

local function parseNumList(s)
    local list = {}
    if not s then return list end
    for item in s:gmatch("[^,]+") do
        local n = tonumber(item)
        if n then table.insert(list, n) end
    end
    return list
end

-- Candidate days (1..dim) within a month for MONTHLY/YEARLY rules.
local function monthDays(y, m, byday, bymonthday, default_day)
    local days = {}
    local dim = daysInMonth(y, m)
    if #bymonthday > 0 then
        for _, d in ipairs(bymonthday) do
            local dd = d > 0 and d or dim + d + 1
            if dd >= 1 and dd <= dim then days[dd] = true end
        end
    elseif #byday > 0 then
        for _, b in ipairs(byday) do
            if b.n then
                local dd = nthWeekdayOfMonth(y, m, b.wday, b.n)
                if dd then days[dd] = true end
            else
                local first = daysFromCivil(y, m, 1)
                for dd = 1, dim do
                    if (first + dd - 1 + 4) % 7 == b.wday then days[dd] = true end
                end
            end
        end
    elseif default_day <= dim then
        days[default_day] = true
    end
    local sorted = {}
    for dd in pairs(days) do table.insert(sorted, dd) end
    table.sort(sorted)
    return sorted
end

local MAX_PERIODS = 20000

--- Expand recurrence and return occurrences overlapping [win_start, win_end).
-- Each occurrence: { start, stop, allday, summary, location }
function ICS.expand(events, win_start, win_end, offset)
    offset = offset or 32400
    -- Collect overridden instances (RECURRENCE-ID) so the master skips them.
    local overridden = {}
    for _, ev in ipairs(events) do
        if ev.recurrence_id and ev.uid then
            overridden[ev.uid .. "|" .. ev.recurrence_id] = true
        end
    end

    local out = {}
    local function emit(ev, s)
        local e = s + (ev.stop - ev.start)
        local overlaps = (e > win_start and s < win_end) or (e == s and s >= win_start and s < win_end)
        if overlaps then
            table.insert(out, {
                start = s, stop = e, allday = ev.allday,
                summary = ev.summary, location = ev.location,
            })
        end
    end

    for _, ev in ipairs(events) do
        if ev.status == "CANCELLED" then
            -- skip (cancelled override instances are still recorded in `overridden`)
        elseif not ev.rrule or ev.recurrence_id then
            emit(ev, ev.start)
        else
            local r = ev.rrule
            local freq = r.FREQ
            local interval = tonumber(r.INTERVAL) or 1
            if interval < 1 then interval = 1 end
            local count = tonumber(r.COUNT)
            local until_t
            if r.UNTIL then
                local u, date_only = parseDateTime(r.UNTIL, {}, offset)
                if u then until_t = date_only and (u + DAY - 1) or u end
            end
            local byday = parseByDay(r.BYDAY)
            local bymonthday = parseNumList(r.BYMONTHDAY)
            local bymonth = parseNumList(r.BYMONTH)
            local wkst = WEEKDAYS[r.WKST or "MO"] or 1
            local tod = ev.start - ICS.dayStart(ev.start)
            local start_day = math.floor(ev.start / DAY)
            local sd = os.date("!*t", ev.start)
            local generated = 0
            local done = false

            local function consider(t)
                if t < ev.start then return end
                if until_t and t > until_t then done = true return end
                if t >= win_end then done = true return end
                generated = generated + 1
                if count and generated > count then done = true return end
                local key = ev.uid and (ev.uid .. "|" .. t)
                if not ev.exdates[t] and not (key and overridden[key]) then
                    emit(ev, t)
                end
            end

            for k = 0, MAX_PERIODS do
                if done then break end
                local p = k * interval
                if freq == "DAILY" then
                    consider(ev.start + p * DAY)
                elseif freq == "WEEKLY" then
                    -- Weeks start on WKST (RFC default MO); matters for INTERVAL > 1.
                    local wk_first = start_day - (ICS.weekday(ev.start) - wkst) % 7 + p * 7
                    local cands = {}
                    if #byday > 0 then
                        for _, b in ipairs(byday) do
                            table.insert(cands, wk_first + (b.wday - wkst) % 7)
                        end
                    else
                        table.insert(cands, start_day + p * 7)
                    end
                    table.sort(cands)
                    for _, dnum in ipairs(cands) do
                        consider(dnum * DAY + tod)
                        if done then break end
                    end
                elseif freq == "MONTHLY" then
                    local mi = sd.month - 1 + p
                    local y, m = sd.year + math.floor(mi / 12), mi % 12 + 1
                    for _, dd in ipairs(monthDays(y, m, byday, bymonthday, sd.day)) do
                        consider(ICS.timegm(y, m, dd) + tod)
                        if done then break end
                    end
                elseif freq == "YEARLY" then
                    local y = sd.year + p
                    local months = #bymonth > 0 and bymonth or { sd.month }
                    for _, m in ipairs(months) do
                        local default_day = sd.day
                        local bd = byday
                        if #bymonth == 0 and #bymonthday == 0 then bd = {} end
                        for _, dd in ipairs(monthDays(y, m, bd, bymonthday, default_day)) do
                            consider(ICS.timegm(y, m, dd) + tod)
                            if done then break end
                        end
                        if done then break end
                    end
                else
                    -- Unsupported frequency: show the first instance only.
                    emit(ev, ev.start)
                    break
                end
            end
        end
    end

    table.sort(out, function(a, b)
        if a.start ~= b.start then return a.start < b.start end
        if a.allday ~= b.allday then return a.allday end
        return a.summary < b.summary
    end)
    return out
end

--- Occurrences that touch the local day starting at `day_start`.
function ICS.onDay(occurrences, day_start)
    local day_end = day_start + DAY
    local list = {}
    for _, o in ipairs(occurrences) do
        if (o.stop > day_start and o.start < day_end)
            or (o.stop == o.start and o.start >= day_start and o.start < day_end) then
            table.insert(list, o)
        end
    end
    return list
end

return ICS
