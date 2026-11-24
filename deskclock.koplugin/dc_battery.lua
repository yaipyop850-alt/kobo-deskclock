--[[--
Battery guard (v4.1).

  * 30 % and 20 %: warning popup + settings backup (each once per discharge)
  * 15 %: settings backup, then power off after a 60 s countdown
          ("나중에" asks again 10 min later; plugging in the charger cancels)

Runs every CHECK_EVERY seconds while KOReader is awake (on any screen, also
while reading a book) and on every timed wake-up (dc_wake). While charging
nothing happens and the warnings are re-armed.

The backup (`deskclock_backup.lua` in the KOReader folder, previous copy kept
as `.1`) holds this plugin's settings incl. calendar addresses, the memos, and
the contents of deskclock_urls.txt / deskclock_write.txt. It is written to a
temporary file, read back, and only then renamed into place, so a power cut
while writing never destroys the last good backup. A backup without any
calendar address is never written over one that has addresses.
--]]

local DataStorage = require("datastorage")
local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Battery = {
    WARN = { 30, 20 },  -- % (each shown once per discharge)
    OFF = 15,           -- % power off
    REARM = 5,          -- a warning re-arms once the level is this much above it again
    CHECK_EVERY = 120,  -- s between checks while awake
    COUNTDOWN = 60,     -- s before powering off
    SNOOZE = 600,       -- s after "나중에" before asking again
    BUSY_WAIT = 30,     -- s to wait while a sync is running
    warned = {},
    snooze_until = nil,
    dialog = nil,
}

--- Current level and charging state. @return capacity or nil, charging
function Battery.read()
    local powerd = Device.getPowerDevice and Device:getPowerDevice()
    if not powerd or not powerd.getCapacity then return nil, false end
    local ok, cap = pcall(powerd.getCapacity, powerd)
    if not ok or type(cap) ~= "number" then return nil, false end
    local charging = false
    if powerd.isCharging then
        local ok2, c = pcall(powerd.isCharging, powerd)
        charging = ok2 and c and true or false
    end
    return cap, charging
end

--- What to do at this level (pure apart from the warned/snooze state).
-- @return "off", a warning level (30 or 20), or nil
function Battery.decide(cap, charging, now)
    if not cap then return nil end
    if charging then
        Battery.warned = {}
        Battery.snooze_until = nil
        return nil
    end
    for _, lv in ipairs(Battery.WARN) do
        if Battery.warned[lv] and cap >= lv + Battery.REARM then Battery.warned[lv] = nil end
    end
    if cap <= Battery.OFF then
        for _, lv in ipairs(Battery.WARN) do Battery.warned[lv] = true end
        if Battery.snooze_until and now < Battery.snooze_until then return nil end
        return "off"
    end
    -- the most severe warning not yet shown (18 % at start -> only the 20 % one)
    local due
    for _, lv in ipairs(Battery.WARN) do
        if cap <= lv and not Battery.warned[lv] then
            if not due or lv < due then due = lv end
        end
    end
    if due then
        for _, lv in ipairs(Battery.WARN) do
            if lv >= due then Battery.warned[lv] = true end
        end
    end
    return due
end

---------------------------------------------------------------- backup

function Battery.backupPath()
    return DataStorage:getDataDir() .. "/deskclock_backup.lua"
end

local function isIdent(k) return type(k) == "string" and k:match("^[%a_][%w_]*$") end

local function serialize(v, indent, depth)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "nil" end
        return (v == math.floor(v) and math.abs(v) < 2^53) and string.format("%d", v) or string.format("%.17g", v)
    end
    if t == "boolean" then return tostring(v) end
    if t ~= "table" or depth > 20 then return "nil" end
    local keys = {}
    for k in pairs(v) do
        if type(k) == "string" or type(k) == "number" then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == "number"
    end)
    local pad = indent .. "  "
    local out = { "{" }
    for _, k in ipairs(keys) do
        local key = isIdent(k) and k or ("[" .. serialize(k, "", depth + 1) .. "]")
        out[#out + 1] = pad .. key .. " = " .. serialize(v[k], pad, depth + 1) .. ","
    end
    out[#out + 1] = indent .. "}"
    return table.concat(out, "\n")
end
Battery._serialize = serialize

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- Read a backup file. @return table or nil, error
function Battery.readBackup(path)
    path = path or Battery.backupPath()
    local chunk, err = loadfile(path)
    if not chunk then return nil, err end
    if setfenv then setfenv(chunk, {}) end -- data only
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" or type(data.settings) ~= "table" then
        return nil, "백업 파일이 손상됨"
    end
    return data
end

local function countUrls(text)
    local n = 0
    for line in (text or ""):gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", ""):gsub("^!%s*", "")
        if line:match("^https?://") or line:match("^webcal://") then n = n + 1 end
    end
    return n
end

local function backupHasUrls(data)
    return countUrls(data.urls_file) + countUrls(data.settings and data.settings.urls_text) > 0
end
Battery.backupHasUrls = backupHasUrls

--- Write the backup. @return true, or false and a reason
function Battery.backup(store, reason)
    local Memo = require("dc_memo")
    local s = store:getSettings()
    local copy = {}
    for k, v in pairs(s) do
        if k ~= "wake_log" then copy[k] = v end -- the log is not worth restoring
    end
    local md = Memo:load()
    local data = {
        saved_at = os.time(),
        reason = reason,
        version = store.VERSION,
        settings = copy,
        memos = { memos = md.memos, outbox = md.outbox, seq = md.seq },
        urls_file = readFile(store:urlFilePath()),
        write_file = readFile(store:writeFilePath()),
    }
    local path = Battery.backupPath()
    if not backupHasUrls(data) then
        local old = Battery.readBackup(path)
        if old and backupHasUrls(old) then
            logger.warn("deskclock battery: no calendar address now; keeping the existing backup")
            return false, "캘린더 주소가 없어 기존 백업을 유지함"
        end
    end
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false, "파일을 만들 수 없음" end
    f:write("-- 책상 시계·달력 설정 백업 (메뉴 '업데이트·관리 › 설정 백업에서 복원'으로 되살림)\n")
    f:write("-- 캘린더 비공개 주소가 들어 있으니 다른 사람과 공유하지 마세요.\n")
    f:write("return ", serialize(data, "", 0), "\n")
    f:flush()
    f:close()
    -- read it back before it replaces anything
    if not Battery.readBackup(tmp) then
        os.remove(tmp)
        return false, "백업 확인 실패"
    end
    if readFile(path) then
        os.remove(path .. ".1")
        os.rename(path, path .. ".1")
    end
    local ok, err = os.rename(tmp, path)
    if not ok then return false, tostring(err) end
    s.last_backup = data.saved_at
    store:save()
    logger.info("deskclock battery: backup written", reason)
    return true
end

--- Put a backup back. Settings are replaced; memos only if the device has
-- none; the address files only if they are missing. @return true or nil, error
function Battery.restore(store, path)
    local data, err = Battery.readBackup(path)
    if not data then return nil, err end
    local s = {}
    for k, v in pairs(data.settings) do s[k] = v end
    local cur = store:getSettings()
    s.wake_log = cur.wake_log
    store.settings = s
    store:save()
    local Memo = require("dc_memo")
    local md = Memo:load()
    local restored_memos = false
    if data.memos and #(md.memos or {}) == 0 and #(data.memos.memos or {}) > 0 then
        md.memos = data.memos.memos
        md.outbox = data.memos.outbox or {}
        md.seq = math.max(md.seq or 0, data.memos.seq or 0)
        Memo:save()
        restored_memos = true
    end
    local function putBack(fpath, text)
        if text and text ~= "" and not readFile(fpath) then
            local f = io.open(fpath, "w")
            if f then f:write(text); f:close() end
        end
    end
    putBack(store:urlFilePath(), data.urls_file)
    putBack(store:writeFilePath(), data.write_file)
    store.urls = nil
    return true, restored_memos, data
end

---------------------------------------------------------------- checks

local function fmtTime(store, t)
    return os.date("!%m/%d %H:%M", t + store:offset())
end

function Battery.warnText(level, cap, backed_up)
    local lines = {
        string.format("배터리 %d%%", cap),
        "",
        level <= 20 and "곧 충전이 필요합니다. 충전기를 연결해 주세요."
            or "충전기를 연결해 주세요.",
        string.format("%d%%가 되면 기기를 보호하려고 전원을 자동으로 끕니다.", Battery.OFF),
    }
    lines[#lines + 1] = backed_up and "설정을 백업했습니다." or "설정 백업: 건너뜀 (진단 정보 참고)"
    return table.concat(lines, "\n")
end

function Battery.offText(cap, backed_up)
    return string.format("배터리 %d%%\n\n기기를 보호하려고 %d초 뒤 전원을 끕니다.\n%s\n충전기를 연결하면 취소됩니다.",
        cap, Battery.COUNTDOWN, backed_up and "설정은 백업했습니다." or "설정 백업: 건너뜀 (진단 정보 참고)")
end

local function powerOff(store)
    if store then store:save() end
    if UIManager.poweroff_action then
        UIManager:poweroff_action()
    elseif Device.powerOff then
        Device:powerOff()
    end
end
Battery._powerOff = powerOff

local function closeDialog()
    if Battery.dialog then
        UIManager:close(Battery.dialog)
        Battery.dialog = nil
    end
    if Battery.countdown_fn then
        UIManager:unschedule(Battery.countdown_fn)
        Battery.countdown_fn = nil
    end
end

function Battery.askPowerOff(store, cap, backed_up)
    if Battery.dialog then return end
    local ConfirmBox = require("ui/widget/confirmbox")
    local deadline = os.time() + Battery.COUNTDOWN
    Battery.dialog = ConfirmBox:new{
        text = Battery.offText(cap, backed_up),
        ok_text = "지금 끄기",
        cancel_text = "10분 뒤 다시",
        ok_callback = function()
            Battery.dialog = nil
            closeDialog()
            powerOff(store)
        end,
        cancel_callback = function()
            Battery.dialog = nil
            closeDialog()
            Battery.snooze_until = os.time() + Battery.SNOOZE
            Battery.log(store, string.format("배터리 %d%% — 전원 끄기 미룸(10분)", cap))
        end,
    }
    UIManager:show(Battery.dialog)
    -- every 5 s: charger plugged in -> cancel; time up -> power off
    Battery.countdown_fn = function()
        local c, charging = Battery.read()
        if charging then
            closeDialog()
            Battery.decide(c, true, os.time())
            Battery.log(store, "충전기 연결 — 전원 끄기 취소")
            return
        end
        if os.time() >= deadline then
            closeDialog()
            powerOff(store)
            return
        end
        UIManager:scheduleIn(5, Battery.countdown_fn)
    end
    UIManager:scheduleIn(5, Battery.countdown_fn)
end

function Battery.log(store, line)
    local ok, Wake = pcall(require, "dc_wake")
    if ok and Wake.log then Wake.log(store, line) else logger.info("deskclock battery:", line) end
end

--- One check. ctx.busy() -> true while a sync is running (wait for it).
-- ctx.asleep -> called from a timed wake-up (nobody is looking): power off
-- right away instead of the countdown. @return the decision
function Battery.check(store, ctx)
    ctx = ctx or {}
    if Battery.dialog then return nil end -- the power-off countdown is already running
    local cap, charging = Battery.read()
    local action = Battery.decide(cap, charging, os.time())
    if not action then return nil end
    if action == "off" then
        if ctx.busy and ctx.busy() then
            Battery.snooze_until = os.time() + Battery.BUSY_WAIT
            return "wait"
        end
        local ok, why = Battery.backup(store, string.format("배터리 %d%% (전원 끄기 전)", cap))
        Battery.log(store, string.format("배터리 %d%% — 전원 끄기%s", cap, ok and "" or (" (백업: " .. tostring(why) .. ")")))
        if ctx.asleep then
            powerOff(store)
        else
            Battery.askPowerOff(store, cap, ok)
        end
        return "off"
    end
    local ok, why = Battery.backup(store, string.format("배터리 %d%% 경고", cap))
    Battery.log(store, string.format("배터리 %d%% — 경고%s", cap, ok and ", 설정 백업" or (" (백업: " .. tostring(why) .. ")")))
    if not ctx.asleep then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = Battery.warnText(action, cap, ok) })
    end
    return action
end

--- Start the periodic check (idempotent). Runs while KOReader is awake.
function Battery.start(store, busy)
    Battery.busy = busy
    if Battery.tick then return end
    Battery.tick = function()
        local ok, err = pcall(Battery.check, store, { busy = Battery.busy })
        if not ok then logger.warn("deskclock battery check failed:", err) end
        UIManager:scheduleIn(Battery.CHECK_EVERY, Battery.tick)
    end
    UIManager:scheduleIn(10, Battery.tick)
end

function Battery.status(store)
    local s = store:getSettings()
    local cap, charging = Battery.read()
    local parts = {
        string.format("배터리 보호: %d%%·%d%% 경고, %d%% 전원 끄기", Battery.WARN[1], Battery.WARN[2], Battery.OFF),
        "현재: " .. (cap and (cap .. "%" .. (charging and " (충전 중)" or "")) or "알 수 없음"),
        "마지막 백업: " .. (s.last_backup and fmtTime(store, s.last_backup) or "없음"),
    }
    return table.concat(parts, "\n")
end

return Battery
