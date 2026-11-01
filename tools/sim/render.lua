-- Layout simulator: runs the real dc_widget.lua against minimal re-implementations
-- of the KOReader widgets it uses, and prints draw operations for render.py.
-- usage: luajit render.lua <scratch> <W> <H> <mode> <now_utc_epoch> <out>
local P, W, H, MODE, NOW, OUT = arg[1], tonumber(arg[2]), tonumber(arg[3]), arg[4], tonumber(arg[5]), arg[6]
package.path = (os.getenv("PLUGIN_DIR") or ((arg[0]:match("^(.*)/[^/]*$") or ".") .. "/../../deskclock.koplugin")) .. "/?.lua;" .. P .. "/?.lua;" .. package.path
local M = dofile(P .. "/metrics.lua")

local ops = {}
local function op(s) ops[#ops + 1] = s end

---------------------------------------------------------------- utf8 helpers
local function chars(s)
    local t = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do t[#t + 1] = ch end
    return t
end
local function cp(ch)
    local b = { ch:byte(1, -1) }
    if #b == 1 then return b[1] end
    if #b == 2 then return (b[1] % 32) * 64 + b[2] % 64 end
    if #b == 3 then return (b[1] % 16) * 4096 + (b[2] % 64) * 64 + b[3] % 64 end
    return 0
end
local function textWidth(s, size, bold)
    local tab = bold and M.b or M.r
    local w = 0
    for _, ch in ipairs(chars(s)) do
        w = w + (tab[cp(ch)] or 0.92) * size
    end
    return math.floor(w + 0.5)
end

---------------------------------------------------------------- base class
local function class(parent)
    local C = {}
    C.__index = C
    if parent then setmetatable(C, { __index = parent }) end
    function C:extend(o) o = o or {}; o.__index = o; return setmetatable(o, { __index = self }) end
    function C:new(o) o = o or {}; setmetatable(o, self); self.__index = self; if o.init then o:init() end; return o end
    return C
end

local Widget = class()
function Widget:getSize() return { w = self.dimen and self.dimen.w or 0, h = self.dimen and self.dimen.h or 0 } end
function Widget:paintTo() end

local function color(c) return c end

---------------------------------------------------------------- widgets
local TextWidget = class(Widget)
function TextWidget:init()
    self.size = self.face.size
    local s = self.text
    local w = textWidth(s, self.size, self.bold)
    if self.max_width and w > self.max_width then
        local cs = chars(s)
        while #cs > 0 do
            table.remove(cs)
            s = table.concat(cs) .. "…"
            w = textWidth(s, self.size, self.bold)
            if w <= self.max_width then break end
        end
    end
    self.shown = s
    self.w = w
    self.h = math.floor(self.size * 1.362 + 0.5)
end
function TextWidget:getSize() return { w = self.w, h = self.h } end
function TextWidget:paintTo(x, y)
    op(string.format("T\t%d\t%d\t%d\t%d\t%d\t%s", x, y + math.floor(self.size * 1.069 + 0.5), self.size,
        self.bold and 1 or 0, self.fgcolor or 0, self.shown))
end

local LineWidget = class(Widget)
function LineWidget:paintTo(x, y)
    op(string.format("R\t%d\t%d\t%d\t%d\t%d", x, y, self.dimen.w, self.dimen.h, self.background or 0))
end

local Span = class(Widget)
local VerticalSpan = Span:extend{}
function VerticalSpan:getSize() return { w = 0, h = self.width or 0 } end
local HorizontalSpan = Span:extend{}
function HorizontalSpan:getSize() return { w = self.width or 0, h = 0 } end

-- Same caching behaviour as KOReader: size/offsets are computed once and
-- reused; children added after a getSize() are NOT re-measured (paint crashes).
local VerticalGroup = class(Widget)
function VerticalGroup:getSize()
    if not rawget(self, "_size") then
        local w, h = 0, 0
        self._offsets = {}
        for i, c in ipairs(self) do local s = c:getSize(); self._offsets[i] = { x = s.w, y = h }; w = math.max(w, s.w); h = h + s.h end
        self._size = { w = w, h = h }
    end
    return self._size
end
function VerticalGroup:resetLayout() self._size = nil; self._offsets = {} end
function VerticalGroup:paintTo(x, y)
    local size = self:getSize()
    for i, c in ipairs(self) do
        local o = self._offsets[i]
        if not o then error("VerticalGroup: child " .. i .. " added after getSize() (stale layout)") end
        local cx = x
        if (self.align or "center") == "center" then cx = x + math.floor((size.w - o.x) / 2)
        elseif self.align == "right" then cx = x + size.w - o.x end
        c:paintTo(cx, y + o.y)
    end
end

local HorizontalGroup = class(Widget)
function HorizontalGroup:getSize()
    if not rawget(self, "_size") then
        local w, h = 0, 0
        self._offsets = {}
        for i, c in ipairs(self) do local s = c:getSize(); self._offsets[i] = { x = w, y = s.h }; w = w + s.w; h = math.max(h, s.h) end
        self._size = { w = w, h = h }
    end
    return self._size
end
function HorizontalGroup:resetLayout() self._size = nil; self._offsets = {} end
function HorizontalGroup:paintTo(x, y)
    local size = self:getSize()
    for i, c in ipairs(self) do
        local o = self._offsets[i]
        if not o then error("HorizontalGroup: child " .. i .. " added after getSize() (stale layout)") end
        local cy = y
        if (self.align or "center") == "center" then cy = y + math.floor((size.h - o.y) / 2)
        elseif self.align == "bottom" then cy = y + size.h - o.y end
        c:paintTo(x + o.x, cy)
    end
end

local Container = class(Widget)
function Container:getSize() return { w = self.dimen.w, h = self.dimen.h } end
local CenterContainer = Container:extend{}
function CenterContainer:paintTo(x, y)
    local s = self[1]:getSize()
    self[1]:paintTo(x + math.floor((self.dimen.w - s.w) / 2), y + math.floor((self.dimen.h - s.h) / 2))
end
local LeftContainer = Container:extend{}
function LeftContainer:paintTo(x, y)
    local s = self[1]:getSize()
    self[1]:paintTo(x, y + math.floor((self.dimen.h - s.h) / 2))
end
local RightContainer = Container:extend{}
function RightContainer:paintTo(x, y)
    local s = self[1]:getSize()
    self[1]:paintTo(x + self.dimen.w - s.w, y + math.floor((self.dimen.h - s.h) / 2))
end
local BottomContainer = Container:extend{}
function BottomContainer:paintTo(x, y)
    local s = self[1]:getSize()
    self[1]:paintTo(x + math.floor((self.dimen.w - s.w) / 2), y + self.dimen.h - s.h)
end
local OverlapGroup = Container:extend{}
function OverlapGroup:getSize()
    local w, h = 0, 0
    for _, c in ipairs(self) do local sz = c:getSize(); w = math.max(w, sz.w); h = math.max(h, sz.h) end
    return { w = w, h = h }
end
function OverlapGroup:paintTo(x, y)
    for _, c in ipairs(self) do c:paintTo(x, y) end
end

-- KOReader semantics: getSize() is content + padding/border/margin ONLY;
-- width/height merely enlarge the painted background (they do not affect layout).
local FrameContainer = class(Widget)
function FrameContainer:getSize()
    local b = (self.bordersize or 0) + (self.margin or 0)
    local s = self[1]:getSize()
    local pl = self.padding_left or self.padding or 0
    local pr = self.padding_right or self.padding or 0
    local pt = self.padding_top or self.padding or 0
    local pb = self.padding_bottom or self.padding or 0
    return { w = s.w + 2 * b + pl + pr, h = s.h + 2 * b + pt + pb }
end
function FrameContainer:paintTo(x, y)
    local size = self:getSize()
    local cw, chh = self.width or size.w, self.height or size.h
    local b = self.bordersize or 0
    if b > 0 then
        op(string.format("R\t%d\t%d\t%d\t%d\t%d", x, y, cw, chh, self.color or 0))
        op(string.format("R\t%d\t%d\t%d\t%d\t%d", x + b, y + b, cw - 2 * b, chh - 2 * b, self.background or 255))
    elseif self.background then
        op(string.format("R\t%d\t%d\t%d\t%d\t%d", x, y, cw, chh, self.background))
    end
    local base = b + (self.margin or 0)
    self[1]:paintTo(x + base + (self.padding_left or self.padding or 0), y + base + (self.padding_top or self.padding or 0))
end

local WidgetContainer = class(Widget)
function WidgetContainer:getSize()
    if self.dimen then return { w = self.dimen.w, h = self.dimen.h } end
    if self[1] then return self[1]:getSize() end
    return { w = 0, h = 0 }
end
function WidgetContainer:paintTo(x, y) if self[1] then self[1]:paintTo(x, y) end end

local InputContainer = class(Widget)
InputContainer.key_events = {}

---------------------------------------------------------------- module stubs
local Screen = {
    getWidth = function() return W end, getHeight = function() return H end,
    scaleBySize = function(_, v) return math.floor(v * 265 / 160) end,
}
local stubs = {
    ["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 255, COLOR_DARK_GRAY = 136, COLOR_LIGHT_GRAY = 204 },
    ["ui/geometry"] = (function()
        local G = {}
        G.__index = G
        function G:combine(b)
            local x, y = math.min(self.x, b.x), math.min(self.y, b.y)
            return setmetatable({ x = x, y = y, w = math.max(self.x + self.w, b.x + b.w) - x,
                h = math.max(self.y + self.h, b.y + b.h) - y }, G)
        end
        return { new = function(_, o) return setmetatable(o or {}, G) end }
    end)(),
    ["ui/gesturerange"] = { new = function(_, o) return o end },
    ["ui/font"] = { getFace = function(_, _, s) return { size = Screen:scaleBySize(s) } end },
    ["ui/uimanager"] = setmetatable({}, { __index = function() return function() end end }),
    ["ui/network/manager"] = { isConnected = function() return true end },
    ["pluginshare"] = {},
    ["logger"] = { warn = print, err = print, info = function() end },
    ["datastorage"] = { getDataDir = function() return P .. "/data" end, getSettingsDir = function() return P .. "/data" end },
    ["device"] = {
        screen = Screen, isTouchDevice = function() return true end, hasKeys = function() return false end,
        getPowerDevice = function() return { getCapacity = function() return 82 end, isCharging = function() return true end } end,
    },
    ["ui/widget/textwidget"] = TextWidget,
    ["ui/widget/linewidget"] = LineWidget,
    ["ui/widget/verticalspan"] = VerticalSpan,
    ["ui/widget/horizontalspan"] = HorizontalSpan,
    ["ui/widget/verticalgroup"] = VerticalGroup,
    ["ui/widget/horizontalgroup"] = HorizontalGroup,
    ["ui/widget/container/centercontainer"] = CenterContainer,
    ["ui/widget/container/leftcontainer"] = LeftContainer,
    ["ui/widget/container/rightcontainer"] = RightContainer,
    ["ui/widget/container/bottomcontainer"] = BottomContainer,
    ["ui/widget/overlapgroup"] = OverlapGroup,
    ["ui/widget/container/framecontainer"] = FrameContainer,
    ["ui/widget/container/inputcontainer"] = InputContainer,
    ["ui/widget/infomessage"] = class(Widget),
    ["luasettings"] = { open = function(_, path)
        local t = { d = {} }
        function t:readSetting(k) return self.d[k] end
        function t:saveSetting(k, v) self.d[k] = v end
        function t:flush() end
        return t
    end },
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
}
for k, v in pairs(stubs) do package.loaded[k] = v end

local settings = { deskclock = { last_sync = NOW - 20 * 60, dday_style = os.getenv("DDAY_STYLE") } }
G_reader_settings = {
    readSetting = function(_, k) return settings[k] end,
    saveSetting = function(_, k, v) settings[k] = v end,
    flush = function() end,
}
local real_time = os.time
os.time = function(t) if t then return real_time(t) end return NOW end

local Store = require("dc_store")
for _, pair in ipairs{ { "https://example.com/my.ics", "my.ics" }, { "https://example.com/holiday.ics", "holiday.ics" } } do
    local src = io.open(P .. "/" .. pair[2]):read("*a")
    local o = io.open(Store.cachePath(pair[1]), "w"); o:write(src); o:close()
end
Store:load()
if os.getenv("MANY_TODO") then
    local M = require("dc_memo")
    for i = 1, 12 do M:addMemo("할 일 예시 " .. i .. " — 학생A 상담 기록 정리와 수행평가 채점표 확인") end
end
if os.getenv("MEMO_DATA") then
    local M = require("dc_memo")
    M:addMemo("다음 주 수업 자료: 동아시아 교역망 지도 인쇄 30부, 활동지 회수함 준비")
    M:addMemo("짧은 메모")
    M:addMemo("학년부 회의 안건\n1) 수행평가 일정 조정\n2) 체험학습 동의서 회수\n3) 기타")
    local d1 = M:addMemo("상담 일지 정리 (학생A, 학생B)")
    M:setDone(d1.id, true)
    local d2 = M:addMemo("동아시아 탐구활동지 인쇄 — 2학년 4개 반, 반별 30부씩 그리고 여분 10부")
    M:setDone(d2.id, true)
    M:addEvent{ title = "교과서 선정 협의", date = "2026-11-04", time = "15:00", minutes = 60 }
    local it = M:addEvent{ title = "모의고사 감독표 제출", date = "2026-11-06" }
    it.error = "비밀 키 불일치 — 주소의 key= 값 확인"
    Store:mergeLocal()
end
local Widget_ = require("dc_widget")
local wd = Widget_:new{ store = Store, mode = (MODE == "sleep" or MODE == "pick") and "clock" or MODE }
if MODE == "pick" then
    wd.mode = "calendar"
    wd:onSwipeAction(nil, { direction = "west" })
    local target = Store and require("dc_ics").timegm(2026, 11, 5)
    for _, r in ipairs(wd.cell_rects) do
        if r.day == target then
            print("tap at", r.x + r.w / 2, r.y + r.h / 2)
            wd:onTapToggle(nil, { pos = { x = r.x + r.w / 2, y = r.y + r.h / 2 } })
        end
    end
    print("selected:", wd.selected_day and os.date("!%Y-%m-%d", wd.selected_day))
    if os.getenv("TAP_TODAY") then
        local b = wd.today_button
        wd:onTapToggle(nil, { pos = { x = b.x + b.w - 20, y = b.y + b.h / 2 } })
        print("after today tap:", wd.selected_day, wd.month_offset, wd.mode)
    end
end
if MODE == "sleep" then
    wd:onShow()
    wd:onSuspend()
end
wd[1]:paintTo(0, 0)
if os.getenv("POPUP") then
    -- open the to-do popup via the badge, optionally tick the first item, then paint it on top
    local b = wd.todo_badge
    wd:onTapToggle(nil, { pos = { x = b.x + b.w / 2, y = b.y + b.h / 2 } })
    local pp = wd.todo_popup
    assert(pp, "popup not opened")
    if os.getenv("POPUP_TICK") then
        local r; for _, x in ipairs(pp.rects) do if x.kind == "item" then r = x break end end
        pp:onTapPopup(nil, { pos = { x = r.x + 50, y = r.y + r.h / 2 } })
        print("after tick open:", require("dc_memo"):openCount())
    end
    if os.getenv("POPUP_PAGE") then
        local r; for _, x in ipairs(pp.rects) do if x.kind == "next" then r = x end end
        if r then pp:onTapPopup(nil, { pos = { x = r.x + r.w / 2, y = r.y + r.h / 2 } }) end
        print("page", pp.page)
    end
    pp[1]:paintTo(0, 0)
    local fsz = pp.frame:getSize()
    local fr = pp.frame_rect
    print(string.format("frame %dx%d at %d,%d  rect %dx%d at %d,%d", fsz.w, fsz.h, fr.x, fr.y, fr.w, fr.h, fr.x, fr.y))
    local a = pp:refreshArea()
    print("refresh area covers frame:", a.x <= fr.x and a.y <= fr.y and a.x + a.w >= fr.x + fsz.w and a.y + a.h >= fr.y + fsz.h)
    local kinds = {}
    for _, x in ipairs(pp.rects) do kinds[#kinds + 1] = x.kind end
    print("popup rects:", table.concat(kinds, ","))
    if os.getenv("POPUP_OUT") then
        pp:onTapPopup(nil, { pos = { x = 5, y = 5 } })
        print("closed:", wd.todo_popup == nil)
    end
end
if os.getenv("SYNC_TEST") then
    local UI = package.loaded["ui/uimanager"]
    local NM = package.loaded["ui/network/manager"]
    local connected = false
    NM.isConnected = function() return connected end
    NM.isOnline = function() return connected end
    NM.enableWifi = function(_, cb) print("  -> enableWifi"); connected = true; cb(); return true end
    NM.disableWifi = function() print("  -> disableWifi"); connected = false end
    UI.nextTick = function(_, f, ...) f(...) end
    UI.scheduleIn = function(_, t, f, ...) if t < 30 then f(...) end end
    UI.show = function(_, w) print("  popup:", w.text) end
    Store.sync = function() print("  -> store:sync (connected=" .. tostring(connected) .. ")"); return true end
    local b = wd.sync_button
    print(string.format("button rect %d %d %d %d", b.x, b.y, b.w, b.h))
    wd:onTapToggle(nil, { pos = { x = b.x + b.w / 2, y = b.y + b.h / 2 } })
    print("after: syncing=", wd.syncing, "wifi connected=", connected, "mode=", wd.mode)
    print("-- second run with Wi-Fi already on")
    connected = true
    wd:onTapToggle(nil, { pos = { x = b.x + b.w / 2, y = b.y + b.h / 2 } })
    print("after: wifi connected=", connected)
end
if os.getenv("MEMO_TAP") then
    for _, r in ipairs(wd.memo_rects) do
        print(string.format("RECT %s %d %d %d %d %s", r.kind, r.x, r.y, r.w, r.h, r.memo and r.memo.text:sub(1,12) or (r.item and r.item.title or "")))
    end
end
if os.getenv("HOLD_TEST") then
    local asked
    wd.askEventTitle = function(_, t, d) asked = d end
    local r = wd.cell_rects[10]
    wd:onHoldExit(nil, { pos = { x = r.x + 5, y = r.y + 5 } })
    print("hold on date ->", asked and os.date("!%Y-%m-%d", asked))
    local closed = false
    package.loaded["ui/uimanager"].close = function() closed = true end
    wd:onHoldExit(nil, { pos = { x = 5, y = 5 } })
    print("hold on header -> exit:", closed)
end
if os.getenv("MONTH_TEST") then
    local UI = package.loaded["ui/uimanager"]
    UI.show = function(_, w) print("POPUP:\n" .. tostring(w.text)) end
    local function tapDay(dnum)
        for _, r in ipairs(wd.cell_rects) do
            if os.date("!%d", r.day) + 0 == dnum then
                wd:onTapToggle(nil, { pos = { x = r.x + r.w / 2, y = r.y + r.h - 5 } }) return
            end
        end
    end
    tapDay(30)
    wd:onSwipeAction(nil, { direction = "west" })
    print("browsing:", wd:isBrowsing(), "today_button:", wd.today_button ~= nil)
    local b = wd.today_button
    wd:onTapToggle(nil, { pos = { x = b.x + 5, y = b.y + 5 } })
    print("after today:", wd.month_offset, wd.mode)
    wd:onTapToggle(nil, { pos = { x = 300, y = 10 } })
    print("after header tap mode:", wd.mode)
    wd.mode = "month"; wd:onShow(); wd:onSuspend(); wd:rebuild()
    print("sleeping month ok, sync_button:", wd.sync_button)
end
if os.getenv("TAP_EVENT") then
    package.loaded["ui/uimanager"].show = function(_, w) print("POPUP:\n" .. tostring(w.text)) end
    for _, r in ipairs(wd.event_rects) do
        print(string.format("rect %4d %4d %4d %3d  %s", r.x, r.y, r.w, r.h, r.occ.summary))
    end
    for _, r in ipairs(wd.event_rects) do
        if r.occ.summary:find(os.getenv("TAP_EVENT"), 1, true) then
            wd:onTapToggle(nil, { pos = { x = r.x + r.w - 5, y = r.y + r.h - 3 } })
            print("mode after tap:", wd.mode)
            break
        end
    end
    -- tap on empty area below the list should toggle
end

local f = io.open(OUT, "w")
f:write(table.concat(ops, "\n"))
f:close()
print(MODE, W .. "x" .. H, #ops .. " ops, events " .. #Store.occurrences)
if os.getenv("TAP_TEST") then
    -- tap the box of the first open memo, then its text, then the to-do badge from clock mode
    local M = require("dc_memo")
    local calls = {}
    local shown
    package.loaded["ui/widget/buttondialog"] = { new = function(_, o) shown = o.title return o end }
    package.loaded["ui/widget/confirmbox"] = { new = function(_, o) return o end }
    wd.refresh = function() calls[#calls+1] = "refresh" ; wd:rebuild() end
    local first
    for _, r in ipairs(wd.memo_rects) do if r.kind == "check" then first = r break end end
    local before = M:openCount()
    wd:onTapToggle(nil, { pos = { x = first.x + 10, y = first.y + 20 } })
    print("tap box: open", before, "->", M:openCount())
    for _, r in ipairs(wd.memo_rects) do if r.kind == "memo" then first = r break end end
    wd:onTapToggle(nil, { pos = { x = first.x + 200, y = first.y + 20 } })
    print("tap text: dialog for", shown and shown:sub(1, 30))
    wd.mode = "clock"; wd:rebuild()
    local b = wd.todo_badge
    wd:onTapToggle(nil, { pos = { x = b.x + b.w / 2, y = b.y + b.h / 2 } })
    print("tap badge: mode", wd.mode)
    local s = wd.sync_button
    print("badge/sync rects overlap:", not (b.x + b.w <= s.x or s.x + s.w <= b.x))
end
if os.getenv("CLOCK_TAP") then
    local M = require("dc_memo")
    wd.refresh = function() wd:rebuild() end
    local detail
    wd.showEventDetail = function(_, o) detail = o.summary end
    print("clock todo rects", #wd.clock_todo_rects, "event rects", #wd.event_rects)
    local e = wd.event_rects[1]
    wd:onTapToggle(nil, { pos = { x = e.x + 300, y = e.y + e.h / 2 } })
    print("tap event ->", detail)
    local c = wd.clock_todo_rects[1]
    local before = M:openCount()
    wd:onTapToggle(nil, { pos = { x = c.x + c.w - 5, y = c.y + c.h / 2 } })
    print("tap todo box: open", before, "->", M:openCount(), "mode", wd.mode)
    local o = wd.clock_todo_rects[2]
    wd:onTapToggle(nil, { pos = { x = o.x + 100, y = o.y + o.h / 2 } })
    print("tap todo text -> mode", wd.mode)
end
if os.getenv("WAKE_TEST") then
    -- simulate KOReader's RTC wake-up flow on Kobo
    local Dev = package.loaded["device"]
    local UI = package.loaded["ui/uimanager"]
    local NM = package.loaded["ui/network/manager"]
    local tasks, resched, log = {}, {}, {}
    Dev.isKobo = function() return true end
    Dev.wakeup_mgr = {
        addTask = function(_, sec, cb) tasks[#tasks + 1] = { sec = sec, cb = cb } end,
        removeTasks = function(_, _, cb)
            for i = #tasks, 1, -1 do if tasks[i].cb == cb then table.remove(tasks, i) end end
        end,
    }
    Dev.rescheduleSuspend = function(_, t) resched[#resched + 1] = t end
    local cap, charging = 82, false
    Dev.getPowerDevice = function() return { getCapacity = function() return cap end, isCharging = function() return charging end } end
    UI.nextTick = function(_, f) f() end
    UI.scheduleIn = function() end
    UI.unschedule = function() end
    UI.setDirty = function() end
    UI.forceRePaint = function() end
    NM.isConnected = function() return true end
    NM.isOnline = function() return true end
    local Store = require("dc_store")
    local synced = 0
    Store.sync = function() synced = synced + 1 return true end
    Store:getSettings().wake_hours = 3
    Store:getSettings().sleep_view = true
    wd:onSuspend()
    print("armed tasks:", #tasks, tasks[1] and tasks[1].sec, "status:", wd:statusText())
    -- alarm fires: KOReader runs the task callback
    local t = table.remove(tasks, 1)
    t.cb()
    print("after wake: synced", synced, "re-armed", #tasks, "reschedule", table.concat(resched, ","))
    print("log:", Store:getSettings().wake_log[1])
    -- user presses power: resume cancels the next alarm
    wd:onResume()
    print("after resume: tasks", #tasks, "next_wake", tostring(wd.next_wake))
    -- low battery: no arming
    cap = 10
    wd:onSuspend()
    print("low battery: tasks", #tasks, "log:", Store:getSettings().wake_log[1])
    -- battery drops during the chain: wake stops, no re-arm
    cap = 82; wd:onResume(); wd:onSuspend(); t = table.remove(tasks, 1); cap = 15; resched = {}
    t.cb()
    print("drop during chain: tasks", #tasks, "synced", synced, "resched", #resched, "log:", Store:getSettings().wake_log[1])
    -- disabled
    cap = 82; wd:onResume(); Store:getSettings().wake_hours = 0; wd:onSuspend()
    print("disabled: tasks", #tasks)
    -- user wakes the device while a wake-up sync is running: no forced re-suspend
    Store:getSettings().wake_hours = 1; wd:onResume(); wd:onSuspend(); t = table.remove(tasks, 1); resched = {}
    Store.sync = function() wd:onResume() return true end
    t.cb()
    print("woken during sync: resched", table.concat(resched, ","), "sleeping", tostring(wd.sleeping))
end
