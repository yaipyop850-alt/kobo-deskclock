--[[--
Self-update from a public GitHub repository.

The repository holds, at its root:
  release.txt              "version=2.9" / "files=a.lua,b.lua,..." / "notes=..."
  deskclock.koplugin/*.lua the plugin files themselves

Update = download every listed file into a staging folder, check each one
compiles (a truncated or garbled download is refused), back up the current
files, then copy the new ones over. Nothing in the plugin folder is touched
until every file has been downloaded and checked.
--]]

local DataStorage = require("datastorage")
local logger = require("logger")

local Update = {
    repo_raw = "https://raw.githubusercontent.com/yaipyop850-alt/kobo-deskclock/main/",
}

local function backupDir()
    return DataStorage:getDataDir() .. "/deskclock_backup"
end

local function stagingDir()
    return DataStorage:getDataDir() .. "/deskclock_staging"
end

local function mkdir(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs.attributes(path, "mode") ~= "directory" then lfs.mkdir(path) end
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

local function writeFile(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

--- GET a URL into memory (files here are small). Follows redirects.
local function fetch(url)
    local socket = require("socket")
    local socketutil = require("socketutil")
    local http = require("socket.http")
    local ok_https, https = pcall(require, "ssl.https")
    for _ = 1, 4 do
        local chunks = {}
        local requester = (url:match("^https://") and ok_https) and https or http
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local ok, r, code, headers = pcall(requester.request, {
            url = url, method = "GET", sink = socketutil.table_sink(chunks),
        })
        socketutil:reset_timeout()
        if not ok then return nil, tostring(r) end
        if not r then return nil, tostring(code) end
        if code == 200 then return table.concat(chunks) end
        if (code == 301 or code == 302 or code == 307 or code == 308) and headers and headers.location then
            url = headers.location
        else
            return nil, "HTTP " .. tostring(code)
        end
    end
    return nil, "too many redirects"
end

local function parseRelease(text)
    local r = {}
    for line in text:gmatch("[^\r\n]+") do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then r[k] = v end
    end
    if not r.version or not r.files then return nil end
    local files = {}
    for name in r.files:gmatch("[^,%s]+") do
        -- only plain file names inside the plugin folder
        if name:match("^[%w_%.%-]+$") and not name:match("%.%.") then
            table.insert(files, name)
        end
    end
    r.file_list = files
    return r
end

--- Compare "2.10" > "2.9" numerically, part by part.
function Update.isNewer(remote, current)
    local a, b = {}, {}
    for n in tostring(remote):gmatch("%d+") do a[#a + 1] = tonumber(n) end
    for n in tostring(current):gmatch("%d+") do b[#b + 1] = tonumber(n) end
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

--- Check the latest release. Blocking. @return release table or nil, err
function Update.check()
    local text, err = fetch(Update.repo_raw .. "release.txt?t=" .. os.time())
    if not text then return nil, "버전 정보를 받지 못함 (" .. tostring(err) .. ")" end
    local rel = parseRelease(text)
    if not rel or #rel.file_list == 0 then return nil, "버전 정보 형식 오류" end
    return rel
end

--- Download, verify and install `rel` into `plugin_dir`. Blocking.
-- @return true or nil, err
function Update.install(rel, plugin_dir)
    plugin_dir = plugin_dir:gsub("/$", "")
    local stage = stagingDir()
    mkdir(stage)
    -- 1) download everything first
    for _, name in ipairs(rel.file_list) do
        local data, err = fetch(Update.repo_raw .. "deskclock.koplugin/" .. name .. "?t=" .. os.time())
        if not data then return nil, name .. " 다운로드 실패 (" .. tostring(err) .. ")" end
        if #data < 20 then return nil, name .. " 내용이 비어 있음" end
        -- 2) a Lua file that does not compile is never installed
        if name:match("%.lua$") then
            local fn, perr = loadstring(data, name)
            if not fn then return nil, name .. " 검사 실패: " .. tostring(perr) end
        end
        if not writeFile(stage .. "/" .. name, data) then return nil, "임시 저장 실패" end
    end
    -- 3) back up the current files (overwrites the previous backup)
    local bdir = backupDir()
    mkdir(bdir)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs then
        for f in lfs.dir(plugin_dir) do
            if f:match("%.lua$") then
                local d = readFile(plugin_dir .. "/" .. f)
                if d then writeFile(bdir .. "/" .. f, d) end
            end
        end
    end
    -- 4) copy the new files in
    for _, name in ipairs(rel.file_list) do
        local d = readFile(stage .. "/" .. name)
        if not d or not writeFile(plugin_dir .. "/" .. name, d) then
            logger.err("deskclock update: copy failed", name)
            return nil, name .. " 설치 중 오류 — [이전 버전으로 되돌리기]를 실행하세요"
        end
        os.remove(stage .. "/" .. name)
    end
    return true
end

function Update.hasBackup()
    return readFile(backupDir() .. "/main.lua") ~= nil
end

--- Restore the files saved before the last update.
function Update.rollback(plugin_dir)
    plugin_dir = plugin_dir:gsub("/$", "")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not Update.hasBackup() then return nil, "백업이 없음" end
    for f in lfs.dir(backupDir()) do
        if f:match("%.lua$") then
            local d = readFile(backupDir() .. "/" .. f)
            if d then writeFile(plugin_dir .. "/" .. f, d) end
        end
    end
    return true
end

Update._parseRelease = parseRelease
return Update
