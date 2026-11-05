--[[--
Full-screen desk clock / month calendar for e-ink.

Gestures:
  tap            switch clock <-> calendar
  tap a date     (calendar) list that date's events; tap today to go back
  swipe left     next month (calendar)
  swipe right    previous month (calendar)
  swipe down     sync Google Calendar now
  swipe up       rotate 90° (portrait <-> landscape); remembered for next time
  long press     exit
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local PluginShare = require("pluginshare")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Memo = require("dc_memo")
local Wake = require("dc_wake")
local Alarm = require("dc_alarm")
local ICS = require("dc_ics")
local Screen = Device.screen

local DAY = 86400
local WDAY = { "일", "월", "화", "수", "목", "금", "토" }
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_DARK_GRAY
local LIGHT = Blitbuffer.COLOR_LIGHT_GRAY

local FULL_REFRESH_EVERY = 30   -- minutes between full (flashing) refreshes
local SYNC_RETRY_SECONDS = 15 * 60

local UI = require("dc_ui")
local fsize, text, wrapText, inRect = UI.fsize, UI.text, UI.wrapText, UI.inRect

local function hm(t)
    return os.date("!%H:%M", t)
end

local DeskWidget = InputContainer:extend{
    name = "DeskClock",
    store = nil,
    ui = nil,          -- FileManager or ReaderUI that opened us (for proper rotation)
    mode = "clock",
    covers_fullscreen = true,
}

function DeskWidget:init()
    self.month_offset = 0
    self.ticks = 0
    self.current_day = nil
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
    if Device:isTouchDevice() then
        local full = function() return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } end
        self.ges_events = {
            TapToggle = { GestureRange:new{ ges = "tap", range = full } },
            HoldExit = { GestureRange:new{ ges = "hold", range = full } },
            SwipeAction = { GestureRange:new{ ges = "swipe", range = full } },
        }
    end
    if Device:hasKeys() then
        self.key_events.Exit = { { "Back" } }
    end
    self.tick_cb = function() self:onTick() end
    self:rebuild()
end

---------------------------------------------------------------- lifecycle

--- Keep the device awake only when it makes sense:
-- always in clock mode; in calendar mode only if "calendar_autosleep" is off.
function DeskWidget:updateKeepAwake(force_release)
    local s = self.store:getSettings()
    local want = not force_release
        and (self.mode == "clock" or s.calendar_autosleep == false)
    if want and not self.keeping_awake then
        self.prev_pause = PluginShare.pause_auto_suspend
        PluginShare.pause_auto_suspend = true
        UIManager:preventStandby()
        self.keeping_awake = true
    elseif not want and self.keeping_awake then
        PluginShare.pause_auto_suspend = self.prev_pause
        UIManager:allowStandby()
        self.keeping_awake = false
    end
end

-- While we are shown, make KOReader's sleep screen "leave screen as is",
-- so the calendar we draw on suspend stays visible. Restored on close.
local SS_KEYS = { "screensaver_type", "screensaver_show_message", "screensaver_delay" }

function DeskWidget:overrideSleepScreen()
    local s = self.store:getSettings()
    if s.sleep_view == false or s.saved_ss then return end
    local saved = {}
    for _, k in ipairs(SS_KEYS) do
        saved[k] = G_reader_settings:readSetting(k)
        if saved[k] == nil then saved[k] = "__nil__" end
    end
    s.saved_ss = saved
    self.store:save() -- persisted first, so a crash can be recovered at next start
    G_reader_settings:saveSetting("screensaver_type", "disable")
    G_reader_settings:saveSetting("screensaver_show_message", false)
    G_reader_settings:saveSetting("screensaver_delay", "disable")
end

function DeskWidget.restoreSleepScreen(store)
    local s = store:getSettings()
    if not s.saved_ss then return end
    for k, v in pairs(s.saved_ss) do
        if v == "__nil__" then
            G_reader_settings:delSetting(k)
        else
            G_reader_settings:saveSetting(k, v)
        end
    end
    s.saved_ss = nil
    store:save()
end

function DeskWidget:onShow()
    self:updateKeepAwake()
    self:overrideSleepScreen()
    self:scheduleTick()
    UIManager:setDirty(self, function() return "full", self.dimen end)
    return true
end

function DeskWidget:onCloseWidget()
    UIManager:unschedule(self.tick_cb)
    Wake.disarm(self)
    Alarm.stopFlash(self)
    if self.todo_popup then
        UIManager:close(self.todo_popup)
        self.todo_popup = nil
    end
    if self.syncing then
        UIManager:unschedule(self.sync_timeout_cb)
        self.syncing = false
        if self.wifi_turned_on_by_us then pcall(NetworkMgr.disableWifi, NetworkMgr) end
    end
    self:updateKeepAwake(true)
    DeskWidget.restoreSleepScreen(self.store)
    UIManager:setDirty(nil, "full")
end

-- KOReader broadcasts Suspend a few seconds before the device actually sleeps
-- (after drawing its own sleep screen, which we set to "leave as is").
function DeskWidget:onSuspend()
    UIManager:unschedule(self.tick_cb)

    if self.store:getSettings().sleep_view == false then return end
    -- Sleep on today's view, not on a browsed month/date.
    self.selected_day = nil
    self.month_offset = 0
    self.sleeping = true
    self.sleep_time = self.store:now()
    -- An open popup stays on the sleep screen (the owner leaves today's events
    -- and to-dos showing); it is refreshed to the current state first.
    if self.todo_popup and self.todo_popup.refreshForNow then
        self.todo_popup:refreshForNow()
    end
    Wake.arm(self) -- before drawing, so the sleep screen can show the next wake-up
    self:rebuild()
    UIManager:setDirty(self, function() return "full", self.dimen end)
    UIManager:forceRePaint()
    if UIManager.waitForVSync then pcall(UIManager.waitForVSync, UIManager) end
end

function DeskWidget:onResume()
    self.sleeping = false
    Wake.disarm(self)
    self.after_sync = nil
    -- a popup kept over the sleep screen gets its buttons back
    if self.todo_popup and self.todo_popup.build then self.todo_popup:build() end
    -- Time has jumped while asleep: redraw everything.
    self:refresh(true)
    self:scheduleTick()
end

function DeskWidget:onSetDimensions(dimen)
    self.dimen = Geom:new{ x = 0, y = 0, w = dimen.w, h = dimen.h }
    self:refresh(true)
end

---------------------------------------------------------------- gestures

local IDLE_RESET_SECONDS = 5 * 60

function DeskWidget:isBrowsing()
    return self.selected_day ~= nil or self.month_offset ~= 0
end


--- Which calendar cell (if any) holds screen position `pos`.
function DeskWidget:dayAt(pos)
    if not pos or not self.cell_rects then return nil end
    for _, r in ipairs(self.cell_rects) do
        if pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h then
            return r.day
        end
    end
end

--- Popup with the full details of one event; tap anywhere (or wait) to close.
function DeskWidget:showEventDetail(o, day)
    local d = os.date("!*t", day)
    local lines = { o.summary, "" }
    local when = string.format("%d월 %d일 (%s)", d.month, d.day, WDAY[d.wday])
    if o.allday then
        local last = ICS.dayStart(math.max(o.start, o.stop - 1))
        if last > ICS.dayStart(o.start) then
            local s, e = os.date("!*t", o.start), os.date("!*t", last)
            when = string.format("%d월 %d일 ~ %d월 %d일 (종일)", s.month, s.day, e.month, e.day)
        else
            when = when .. " 종일"
        end
    else
        when = when .. " " .. hm(o.start)
        if o.stop > o.start then
            local same = ICS.dayStart(o.stop - 1) == ICS.dayStart(o.start)
            when = when .. " – " .. (same and hm(o.stop) or os.date("!%m/%d %H:%M", o.stop))
        end
    end
    table.insert(lines, when)
    if o.location and o.location ~= "" then
        table.insert(lines, "장소: " .. o.location)
    end
    if o.pending then
        table.insert(lines, "")
        table.insert(lines, "◇ 기기에서 추가한 일정 — 구글 캘린더 반영 전")
    end
    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
        show_icon = false,
        timeout = 20,
    })
end

function DeskWidget:openMemoScreen()
    self.mode = "memo"
    self.month_offset = 0
    self.selected_day = nil
    self.store:set("mode", "memo")
    self:updateKeepAwake()
    self:refresh(true)
end

function DeskWidget:onTapToggle(_, ges)
    self.last_touch = os.time()
    local pos = ges and ges.pos
    if not self.sleeping and inRect(pos, self.sync_button) then
        self:syncNow()
        return true
    end
    -- hidden sync button: the "2026년 11월" title of the full-screen month
    -- (the small [동기화] button is easy to miss there)
    if not self.sleeping and self.mode == "month" and inRect(pos, self.month_title_rect) then
        self:syncNow()
        return true
    end
    if not self.sleeping and self.mode == "clock" then
        for _, r in ipairs(self.clock_todo_rects or {}) do
            if inRect(pos, r) then
                if r.kind == "check" then
                    Memo:toggleDone(r.memo.id)
                    self:refresh(false)
                else
                    self:openMemoScreen()
                end
                return true
            end
        end
    end
    if not self.sleeping and self.mode ~= "memo" and inRect(pos, self.todo_badge) then
        self:showTodoPopup()
        return true
    end
    if self.mode == "memo" then
        for _, r in ipairs(self.memo_rects or {}) do
            if inRect(pos, r) then
                self:onMemoItem(r)
                return true
            end
        end
    end
    for _, r in ipairs(self.event_rects or {}) do
        if inRect(pos, r) then
            self:showEventDetail(r.occ, r.day)
            return true
        end
    end
    if self.mode == "month" then
        if self:isBrowsing() and inRect(pos, self.today_button) then
            self.month_offset = 0
            self:refresh(false)
            return true
        end
        local day = self:dayAt(pos)
        if day then
            self.store:ensureWindow(false, day)
            self:showDayDetail(day)
            return true
        end
    end
    if self.mode == "calendar" then
        if self:isBrowsing() and inRect(ges and ges.pos, self.today_button) then
            self.selected_day = nil
            self.month_offset = 0
            self:refresh(false)
            return true
        end
        local day = self:dayAt(ges and ges.pos)
        if day then
            local today = ICS.dayStart(self.store:now())
            self.selected_day = (day ~= today) and day or nil
            self.store:ensureWindow(false, day)
            self:refresh(false)
            return true
        end
    end
    -- clock -> calendar + list -> full-screen month -> clock
    local NEXT = { clock = "calendar", calendar = "month", month = "memo", memo = "clock" }
    self.mode = NEXT[self.mode] or "clock"
    self.month_offset = 0
    self.selected_day = nil
    self.store:set("mode", self.mode)
    self:updateKeepAwake()
    self:refresh(true)
    return true
end

function DeskWidget:onHoldExit(_, ges)
    local pos = ges and ges.pos
    if pos and not self.sleeping and (self.mode == "calendar" or self.mode == "month") then
        local day = self:dayAt(pos)
        if day then
            self:askEventTitle(nil, day)
            return true
        end
    end
    UIManager:close(self)
    return true
end
DeskWidget.onExit = DeskWidget.onHoldExit

function DeskWidget:displayedMonthStart()
    local td = os.date("!*t", self.store:now())
    local mi = td.month - 1 + self.month_offset
    return ICS.timegm(td.year + math.floor(mi / 12), mi % 12 + 1, 1)
end

function DeskWidget:onSwipeAction(_, ges)
    self.last_touch = os.time()
    local dir = ges and ges.direction
    if dir == "south" then
        self:syncNow()
    elseif dir == "north" then
        self:rotate()
    elseif self.mode == "memo" and (dir == "west" or dir == "east") then
        self.memo_page = math.max(1, (self.memo_page or 1) + (dir == "west" and 1 or -1))
        self:refresh(false)
    elseif (self.mode == "calendar" or self.mode == "month") and (dir == "west" or dir == "east") then
        self.month_offset = self.month_offset + (dir == "west" and 1 or -1)
        self.store:ensureWindow(false, self:displayedMonthStart())
        self:refresh(false)
    end
    return true
end

--- Rotate the whole UI by 90° clockwise and remember it.
function DeskWidget:rotate()
    local mode = (Screen:getRotationMode() + 1) % 4
    self:applyRotation(mode)
    self.store:set("rotation", mode)
end

--- Apply a rotation mode through the underlying UI, so that the file browser
-- or the open document is laid out for the new orientation too.
function DeskWidget:applyRotation(mode)
    if mode == nil or mode == Screen:getRotationMode() then return end
    local Event = require("ui/event")
    if self.ui and self.ui.handleEvent then
        self.ui:handleEvent(Event:new("SetRotationMode", mode))
    end
    if Screen:getRotationMode() ~= mode then
        Screen:setRotationMode(mode)
    end
    self:refresh(true)
end

--- Sync with automatic Wi-Fi handling:
-- (Wi-Fi off) turn on -> wait for internet -> download -> turn Wi-Fi off again.
-- (Wi-Fi already on) just download, and leave Wi-Fi as it was.
-- Progress is shown on the small button instead of a popup.
local WIFI_TIMEOUT = 60      -- seconds to get connected
local ONLINE_TRIES = 40      -- x 0.5 s waiting for DNS after connecting

function DeskWidget:setSyncState(state)
    self.sync_state = state
    self:rebuild()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    UIManager:forceRePaint()
end

function DeskWidget:finishSync(ok, err, silent)
    UIManager:unschedule(self.sync_timeout_cb)
    if self.wifi_turned_on_by_us then
        self.wifi_turned_on_by_us = false
        pcall(NetworkMgr.disableWifi, NetworkMgr)
    end
    self.syncing = false
    self.sync_state = nil
    if (not ok or err) and not silent then
        UIManager:show(InfoMessage:new{ text = err or "동기화 실패", timeout = 5 })
    end
    self:refresh(true)
    -- one-shot hook (timed wake-up while asleep)
    local after = self.after_sync
    self.after_sync = nil
    if after then after(ok, err) end
end

function DeskWidget:syncNow(silent)
    if self.syncing then return end
    self.syncing = true
    self.sync_silent = silent
    self.last_attempt = os.time()

    local function doSync()
        if not self.syncing then return end -- timed out meanwhile
        self:setSyncState("동기화 중")
        UIManager:nextTick(function()
            local ok, err = self.store:sync()
            self:finishSync(ok, err, silent)
        end)
    end

    local waitOnline
    waitOnline = function(n)
        if not self.syncing then return end
        if NetworkMgr:isOnline() then
            doSync()
        elseif n < ONLINE_TRIES then
            UIManager:scheduleIn(0.5, waitOnline, n + 1)
        else
            self:finishSync(false, "인터넷 연결 확인 실패(DNS) — 공유기 상태 확인", silent)
        end
    end

    if NetworkMgr:isConnected() then
        self.wifi_turned_on_by_us = false
        waitOnline(0)
        return
    end

    self:setSyncState("Wi-Fi 연결 중")
    self.wifi_turned_on_by_us = true
    self.sync_timeout_cb = self.sync_timeout_cb or function()
        if self.syncing then
            self:finishSync(false, "Wi-Fi 연결 실패 — 저장된 Wi-Fi 네트워크가 있는지 확인", self.sync_silent)
        end
    end
    UIManager:scheduleIn(WIFI_TIMEOUT, self.sync_timeout_cb)
    local started = NetworkMgr:enableWifi(function() waitOnline(0) end, false)
    if started == false then
        self:finishSync(false, "Wi-Fi를 켜지 못함", silent)
    elseif started == nil then
        -- another connection attempt is in progress: just wait for it
        UIManager:scheduleIn(1, waitOnline, 0)
    end
end

---------------------------------------------------------------- ticking

function DeskWidget:scheduleTick()
    UIManager:unschedule(self.tick_cb)
    local delay = 60 - (os.time() % 60) + 0.5
    UIManager:scheduleIn(delay, self.tick_cb)
end

function DeskWidget:maybeAutoSync()
    if not self.store:isSyncDue() then return end
    local now = os.time()
    if self.last_attempt and now - self.last_attempt < SYNC_RETRY_SECONDS then return end
    if self.syncing then return end
    -- By default only use Wi-Fi that is already connected; with the "auto Wi-Fi"
    -- option, turn it on just for the sync and off again afterwards.
    if not NetworkMgr:isConnected() then
        if self.store:getSettings().auto_wifi_sync then
            self:syncNow(true)
        end
        return
    end
    -- Connected to Wi-Fi is not enough: DNS may not be ready yet (common on Kobo).
    if NetworkMgr.isOnline and not NetworkMgr:isOnline() then return end
    self.last_attempt = now
    self.store:sync()
end

function DeskWidget:onTick()
    -- A desk calendar should drift back to "today" when left alone.
    if (self.selected_day or self.month_offset ~= 0)
            and os.time() - (self.last_touch or 0) > IDLE_RESET_SECONDS then
        self.selected_day = nil
        self.month_offset = 0
    end
    self:maybeAutoSync()
    self:refresh(false)
    -- awake: alarms ring from the minute tick (asleep, dc_wake wakes us)
    if not self.sleeping and not self.flash_step then
        local due = Alarm.due(self.store)
        if #due > 0 then
            Alarm.markFired(self.store, due)
            self:ringAlarms(due)
        end
    end
    self:scheduleTick()
end

--- Show the alarm popup (replacing any other popup) and flash the screen.
-- `done` runs when the flashing is over.
function DeskWidget:ringAlarms(items, done)
    if self.todo_popup then
        UIManager:close(self.todo_popup)
        self.todo_popup = nil
    end
    self.todo_popup = require("dc_todopopup").AlarmPopup:new{
        parent = self, items = items,
    }
    UIManager:show(self.todo_popup)
    self:rebuild()
    -- a dirty screen repaints the popup on top of it too
    UIManager:setDirty(self, function() return "full", self.dimen end)
    UIManager:forceRePaint()
    Alarm.flash(self, done)
end

function DeskWidget:refresh(full)
    local today = ICS.dayStart(self.store:now())
    if self.current_day ~= today then
        if self.current_day then
            self.month_offset = 0
            self.selected_day = nil
            full = true
        end
        self.current_day = today
        self.store:ensureWindow()
    end
    self:rebuild()
    self.ticks = self.ticks + 1
    if self.ticks % FULL_REFRESH_EVERY == 0 then full = true end
    local mode = full and "full" or "ui"
    UIManager:setDirty(self, function() return mode, self.dimen end)
end

---------------------------------------------------------------- shared bits

function DeskWidget:statusText()
    local parts = {}
    if self.sleeping then
        local off = self.store:offset()
        local today = ICS.dayStart(self.store:now())
        local function when(t)
            t = t + off
            return os.date(ICS.dayStart(t) == today and "!%H:%M" or "!%m/%d %H:%M", t)
        end
        local bits = { "잠자기 중" }
        if self.next_alarm then bits[#bits + 1] = "다음 알림 " .. when(self.next_alarm) end
        if self.next_sync_at then bits[#bits + 1] = "다음 자동 동기화 " .. when(self.next_sync_at) end
        if #bits == 1 then bits[2] = "전원 버튼을 누르면 깨어남" end
        return table.concat(bits, " · ")
    end
    local powerd = Device:getPowerDevice()
    if powerd and powerd.getCapacity then
        local cap = powerd:getCapacity()
        local charging = powerd.isCharging and powerd:isCharging()
        table.insert(parts, "배터리 " .. cap .. "%" .. (charging and " 충전 중" or ""))
    end
    local s = self.store:getSettings()
    if #self.store:getUrls() == 0 then
        table.insert(parts, "캘린더 미설정")
    elseif s.last_sync then
        local ls = s.last_sync + self.store:offset()
        local same_day = ICS.dayStart(ls) == ICS.dayStart(self.store:now())
        table.insert(parts, "동기화 " .. os.date(same_day and "!%H:%M" or "!%m/%d %H:%M", ls))
    else
        table.insert(parts, "동기화 전")
    end
    if s.last_error then
        table.insert(parts, "오류: " .. s.last_error)
    end
    return table.concat(parts, "  ·  ")
end

--- Status line + a small outlined "동기화" button. Records the button's touch area.
-- `ox, oy` = absolute top-left where the returned group will be painted.
function DeskWidget:statusBar(px, maxw, ox, oy)
    if self.sleeping then
        self.sync_button = nil
        return text(self:statusText(), px, { color = GRAY, max_width = maxw })
    end
    local label = self.sync_state and (self.sync_state .. "…") or "동기화"
    local btn_text = text(label, px * 0.95, { bold = true, color = self.sync_state and GRAY or BLACK })
    local bs = btn_text:getSize()
    local padx, pady = math.floor(px * 0.45), math.floor(px * 0.15)
    local button = FrameContainer:new{
        bordersize = math.max(1, math.floor(px / 14)), radius = 0, margin = 0,
        color = self.sync_state and GRAY or BLACK,
        padding = 0, padding_left = padx, padding_right = padx, padding_top = pady, padding_bottom = pady,
        background = WHITE,
        width = bs.w + 2 * padx + 2 * math.max(1, math.floor(px / 14)),
        height = bs.h + 2 * pady + 2 * math.max(1, math.floor(px / 14)),
        btn_text,
    }
    local bsz = button:getSize()
    local gap = math.floor(px * 0.8)
    -- "할 일 N": open to-dos, a small black badge next to the button (tap = memo screen)
    local badge, badge_w = nil, 0
    local open_n = Memo:openCount()
    self.todo_badge = nil
    if open_n > 0 then
        local lbl = text("할 일 " .. open_n, px * 0.9, { bold = true, color = WHITE })
        local ls = lbl:getSize()
        local bpx, bpy = math.floor(px * 0.4), math.floor(px * 0.12)
        badge = FrameContainer:new{
            bordersize = 0, radius = math.floor(ls.h / 2 + bpy), margin = 0, background = BLACK,
            padding = 0, padding_left = bpx, padding_right = bpx, padding_top = bpy, padding_bottom = bpy,
            lbl,
        }
        badge_w = ls.w + 2 * bpx
    end
    local bgap = math.floor(px * 0.5)
    local status = self.sync_state and "" or self:statusText()
    local reserved = bsz.w + gap + (badge and (badge_w + bgap) or 0)
    local st = text(status, px, { color = GRAY, max_width = math.max(px * 4, maxw - reserved) })
    local group = HorizontalGroup:new{ align = "center", st, HorizontalSpan:new{ width = gap } }
    if badge then
        table.insert(group, badge)
        table.insert(group, HorizontalSpan:new{ width = bgap })
    end
    table.insert(group, button)
    local gs = group:getSize()
    -- generous touch areas around the small buttons (e-ink fingers are not precise)
    local slack = math.floor(px * 0.6)
    local x = ox + st:getSize().w + gap
    if badge then
        local bh = badge:getSize().h
        local by0 = oy + math.floor((gs.h - bh) / 2)
        self.todo_badge = { x = x - slack, y = by0 - slack, w = badge_w + bgap / 2 + slack, h = bh + 2 * slack }
        x = x + badge_w + bgap
    end
    local by = oy + math.floor((gs.h - bsz.h) / 2)
    self.sync_button = { x = x - math.floor(bgap / 2), y = by - slack, w = bsz.w + slack + math.floor(bgap / 2), h = bsz.h + 2 * slack }
    return group
end

local function ddayText(it)
    if it.ongoing then return string.format("진행 중 %d/%d일", it.nth, it.total) end
    return it.days_left == 0 and "D-DAY" or ("D-" .. it.days_left)
end

--- One row of D-day targets, in the chosen style ("text" or "badge").
-- Returns nil when there is nothing to show.
function DeskWidget:ddayRow(px, maxw, limit)
    local items = self.store:ddays(limit)
    if #items == 0 then return nil end
    local style = self.store:getSettings().dday_style or "text"

    local function piece(it, name_max)
        if style == "badge" then
            local lbl = text(ddayText(it), px * 0.85, { bold = true, color = WHITE })
            local ls = lbl:getSize()
            local padx, pady = math.floor(px * 0.35), math.floor(px * 0.08)
            local badge = FrameContainer:new{
                bordersize = 0, radius = 0, margin = 0, background = BLACK,
                padding = 0, padding_left = padx, padding_right = padx, padding_top = pady, padding_bottom = pady,
                width = ls.w + 2 * padx, height = ls.h + 2 * pady,
                lbl,
            }
            return HorizontalGroup:new{ align = "center",
                badge, HorizontalSpan:new{ width = math.floor(px * 0.35) },
                text(it.summary, px, { max_width = name_max }) }
        end
        -- "D-45 2차 지필고사": count first (bold), then the name (gray)
        return HorizontalGroup:new{ align = "center",
            text(ddayText(it), px, { bold = true }),
            HorizontalSpan:new{ width = math.floor(px * 0.35) },
            text(it.summary, px, { color = GRAY, max_width = name_max }) }
    end
    local function sep()
        return style == "badge" and HorizontalSpan:new{ width = px } or text("  ·  ", px, { color = GRAY })
    end
    local function build(name_max)
        local row = HorizontalGroup:new{ align = "center" }
        for i, it in ipairs(items) do
            if i > 1 then table.insert(row, sep()) end
            table.insert(row, piece(it, name_max))
        end
        return row
    end

    -- One line if everything fits; otherwise one D-day per line
    -- (never drop one: the user asked for up to 2 to be shown).
    local row = build(nil)
    if row:getSize().w <= maxw then return row end
    local stack = VerticalGroup:new{ align = "left" }
    for _, it in ipairs(items) do
        local p = piece(it, nil)
        if p:getSize().w > maxw then
            p = piece(it, maxw - piece(it, 1):getSize().w)
        end
        table.insert(stack, p)
    end
    return stack
end

local function dayLabel(day, today)
    local diff = math.floor((day - today) / DAY)
    if diff == 0 then return "오늘" end
    if diff == 1 then return "내일" end
    if diff == 2 then return "모레" end
    local d = os.date("!*t", day)
    return string.format("%d/%d(%s)", d.month, d.day, WDAY[d.wday])
end

local function eventTime(o, day)
    if o.allday then return "종일" end
    local day_end = day + DAY
    if o.start < day and o.stop >= day_end then return "종일" end
    if o.start < day then return "~" .. hm(o.stop) end
    if o.stop > o.start and o.stop <= day_end then
        return hm(o.start) .. "–" .. hm(o.stop)
    end
    return hm(o.start)
end

---------------------------------------------------------------- clock mode

function DeskWidget:buildClock(W, H)
    -- Portrait: clock on top, then upcoming events, then open to-dos (full width,
    -- so titles are not cut). Landscape: a bigger clock on top, then two columns
    -- [events | to-dos]. Everything is stacked from the top; the status bar sits
    -- at the bottom.
    local store = self.store
    local now = store:now()
    local today = ICS.dayStart(now)
    local d = os.date("!*t", now)
    local m = math.min(W, H)
    local land = W > H
    local pad = math.floor(m * 0.05)
    local cw = W - 2 * pad

    local time_px = land and math.min(m * 0.28, cw / 2.75) or math.min(m * 0.28, cw / 3.0)
    local date_px = land and m * 0.046 or m * 0.05
    local dday_px = land and m * 0.037 or m * 0.04
    local ev_px = land and m * 0.033 or m * 0.036
    local status_px = m * 0.028
    local line_h = math.max(1, math.floor(m * 0.003))
    self.clock_todo_rects = {}

    local date_str = string.format("%d년 %d월 %d일 %s요일", d.year, d.month, d.day, WDAY[d.wday])
    local hol = store:holidaysOnDay(today)
    if hol then date_str = date_str .. "  ·  " .. table.concat(hol, ", ") end

    -- NOTE: never call getSize() on a group that will still receive children
    -- (KOReader caches the layout on the first getSize()). Heights are summed
    -- by hand from leaf widgets instead.
    local top = VerticalGroup:new{ align = "left" }
    local y = 0
    local function add(wdg, h)
        table.insert(top, wdg)
        y = y + (h or wdg:getSize().h)
    end
    local function vspace(px) add(VerticalSpan:new{ width = math.floor(px) }, math.floor(px)) end
    local function centered(wdg, h)
        h = h or wdg:getSize().h
        return CenterContainer:new{ dimen = Geom:new{ w = W, h = h }, wdg }, h
    end
    local function hline(w)
        return HorizontalGroup:new{ HorizontalSpan:new{ width = pad },
            LineWidget:new{ background = LIGHT, dimen = Geom:new{ w = w, h = line_h } } }
    end

    vspace(land and m * 0.025 or m * 0.045)
    -- TextWidget's box is the font's full line height; the digits only use the
    -- middle ~55% of it. A shorter centered box trims the empty top and bottom.
    local tbox = math.floor(time_px * 0.80)
    add(centered(text(string.format("%02d:%02d", d.hour, d.min), time_px, { bold = true }), tbox))
    vspace(m * 0.012)
    add(centered(text(date_str, date_px, { max_width = cw })))
    local drow = self:ddayRow(dday_px, cw, 2)
    if drow then
        vspace(m * 0.01)
        add(centered(drow))
    end
    vspace(land and m * 0.025 or m * 0.03)
    add(hline(cw), line_h)
    local sep_gap = math.floor(land and m * 0.03 or m * 0.035)
    vspace(sep_gap)

    -- status bar (measured first: the lists may use everything above it)
    local bottom_h = H - math.floor(m * 0.03)
    local probe = self:statusBar(status_px, math.floor(W * 0.9), 0, 0)
    local ps = probe:getSize()
    local sx, sy = math.floor((W - ps.w) / 2), bottom_h - ps.h
    local lists_bottom = sy - math.floor(m * 0.03)

    ------------------------------------------------ list builders
    local row_h = text("가", ev_px):getSize().h
    local row_gap = math.floor(ev_px * 0.28)
    local time_col = math.max(text("진행 중", ev_px * 0.9):getSize().w, text("00:00", ev_px * 0.9):getSize().w)
    local tgap = math.floor(ev_px * 0.6)

    local function whenOf(o, oday)
        if o.start <= now and o.stop > now and not o.allday then return "진행 중" end
        if o.allday then return "종일" end
        if o.start < oday then
            if o.stop >= oday + DAY then return "종일" end
            return "~" .. hm(o.stop)
        end
        return hm(o.start)
    end
    local function headOf(oday)
        local diff = math.floor((oday - today) / DAY)
        if diff == 0 then return "오늘" end
        local dd = os.date("!*t", oday)
        local md = string.format("%d/%d(%s)", dd.month, dd.day, WDAY[dd.wday])
        if diff == 1 then return "내일 " .. md end
        if diff == 2 then return "모레 " .. md end
        return md
    end

    --- Events column: day headings + "time  title" rows, as many as fit in `budget`.
    -- @return group, used height, rows {y, h, occ, day} relative to the column top
    local function eventsColumn(width, budget)
        local col = VerticalGroup:new{ align = "left" }
        local used, rects = 0, {}
        local function put(wdg, h) table.insert(col, wdg); used = used + h end
        if #store:getUrls() == 0 then
            put(wrapText("메뉴에서 구글 캘린더 주소를 설정하면 일정이 표시됩니다", ev_px * 0.9, width, 2, { color = GRAY }), row_h * 2)
            return col, used, rects
        end
        local items = store:upcoming(40, 14)
        if #items == 0 then
            put(text("앞으로 2주 동안 일정 없음", ev_px, { color = GRAY, max_width = width }), row_h)
            return col, used, rects
        end
        local last_day
        for _, o in ipairs(items) do
            local oday = math.max(ICS.dayStart(o.start), today)
            local need = row_h + row_gap
            local new_day = oday ~= last_day
            if new_day then need = need + row_h + (last_day and row_gap * 2 or 0) end
            if used + need > budget then break end
            if new_day then
                if last_day then put(VerticalSpan:new{ width = row_gap * 2 }, row_gap * 2) end
                put(text(headOf(oday), ev_px * 0.9, { bold = true, max_width = width }), row_h)
                last_day = oday
            end
            local row = HorizontalGroup:new{ align = "center",
                LeftContainer:new{ dimen = Geom:new{ w = time_col, h = row_h },
                    text(whenOf(o, oday), ev_px * 0.9, { color = GRAY }) },
                HorizontalSpan:new{ width = tgap },
                text(o.summary, ev_px, { max_width = width - time_col - tgap }),
            }
            table.insert(rects, { y = used, h = row_h, occ = o, day = oday })
            put(row, row_h)
            put(VerticalSpan:new{ width = row_gap }, row_gap)
        end
        return col, used, rects
    end

    --- To-do column: open memos only, one line each. @return group, used, rects
    local function todoColumn(width, budget, with_title)
        local col = VerticalGroup:new{ align = "left" }
        local used, rects = 0, {}
        local function put(wdg, h) table.insert(col, wdg); used = used + h end
        if with_title then
            put(text("할 일", ev_px * 0.9, { bold = true }), row_h)
        end
        local box = math.floor(ev_px * 0.8)
        local bth = math.max(2, math.floor(ev_px / 16))
        local open = {}
        for _, mm in ipairs(Memo:memos()) do if not mm.done then open[#open + 1] = mm end end
        for i, mm in ipairs(open) do
            local need = row_h + row_gap
            -- keep room for the "…외 N개" line while more items follow
            local tail = i < #open and row_h or 0
            if used + need + tail > budget then
                local more = #open - i + 1
                if used + row_h > budget and #rects > 0 then
                    -- not even the note fits: give up the last row for it
                    table.remove(col); table.remove(col); used = used - row_h - row_gap
                    table.remove(rects)
                    more = more + 1
                end
                if used + row_h <= budget then
                    put(text(string.format("…외 %d개 (탭하면 메모 화면)", more), ev_px * 0.85, { color = GRAY }), row_h)
                    table.insert(rects, { y = used - row_h, h = row_h, kind = "open" })
                end
                break
            end
            local row = HorizontalGroup:new{ align = "center",
                FrameContainer:new{ bordersize = bth, radius = 0, margin = 0, padding = 0, color = BLACK, background = WHITE,
                    CenterContainer:new{ dimen = Geom:new{ w = box - 2 * bth, h = box - 2 * bth }, VerticalSpan:new{ width = 0 } } },
                HorizontalSpan:new{ width = math.floor(ev_px * 0.45) },
                text((mm.text:gsub("%s*\n+%s*", " · ")), ev_px, { max_width = width - box - math.floor(ev_px * 0.45) }),
            }
            table.insert(rects, { y = used, h = row_h, memo = mm, box_w = box + math.floor(ev_px * 0.45) })
            put(row, row_h)
            put(VerticalSpan:new{ width = row_gap }, row_gap)
        end
        return col, used, rects
    end

    local function addEventRects(rects, x, w, col_top)
        for _, r in ipairs(rects) do
            table.insert(self.event_rects, { x = x, y = col_top + r.y - math.floor(row_gap / 2),
                w = w, h = r.h + row_gap, occ = r.occ, day = r.day })
        end
    end
    local function addTodoRects(rects, x, w, col_top)
        for _, r in ipairs(rects) do
            local ry, rh = col_top + r.y - math.floor(row_gap / 2), r.h + row_gap
            if r.memo then
                table.insert(self.clock_todo_rects, { kind = "check", memo = r.memo,
                    x = x - math.floor(pad * 0.8), y = ry, w = r.box_w + math.floor(pad * 0.8), h = rh })
                table.insert(self.clock_todo_rects, { kind = "open", x = x + r.box_w, y = ry, w = w - r.box_w, h = rh })
            else
                table.insert(self.clock_todo_rects, { kind = "open", x = x, y = ry, w = w, h = rh })
            end
        end
    end

    local open_n = Memo:openCount()
    local avail = lists_bottom - y
    if land then
        ------------------------------------------------ landscape: [events | to-dos]
        local col_gap = math.floor(m * 0.03)
        local left_w = open_n > 0 and math.floor(cw * 0.6) - col_gap or cw
        local ev_col, ev_used, ev_rects = eventsColumn(left_w, avail)
        local row = HorizontalGroup:new{ align = "top", ev_col }
        addEventRects(ev_rects, pad, left_w, y)
        if open_n > 0 then
            local right_x = pad + left_w + 2 * col_gap + line_h
            local right_w = W - pad - right_x
            local td_col, td_used, td_rects = todoColumn(right_w, avail, true)
            local col_h = math.max(ev_used, td_used)
            -- fixed-width left column so the divider does not move with the text
            row = HorizontalGroup:new{ align = "top",
                LeftContainer:new{ dimen = Geom:new{ w = left_w, h = col_h }, ev_col },
                HorizontalSpan:new{ width = col_gap },
                LineWidget:new{ background = LIGHT, dimen = Geom:new{ w = line_h, h = col_h } },
                HorizontalSpan:new{ width = col_gap },
                td_col,
            }
            addTodoRects(td_rects, right_x, right_w, y)
        end
        add(HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = pad }, row }, 0)
    else
        ------------------------------------------------ portrait: events, then to-dos
        -- keep room for a few to-dos; events fill the rest, to-dos take what is left
        local todo_reserve = 0
        if open_n > 0 then
            todo_reserve = row_h + math.min(open_n, 3) * (row_h + row_gap) + 2 * sep_gap + line_h
        end
        local ev_col, ev_used, ev_rects = eventsColumn(cw, avail - todo_reserve)
        add(HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = pad }, ev_col }, ev_used)
        addEventRects(ev_rects, pad, cw, y - ev_used)
        if open_n > 0 then
            vspace(sep_gap - row_gap)
            add(hline(cw), line_h)
            vspace(sep_gap)
            local td_col, td_used, td_rects = todoColumn(cw, lists_bottom - y, true)
            add(HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = pad }, td_col }, td_used)
            addTodoRects(td_rects, pad, cw, y - td_used)
        end
    end

    local clock_status = BottomContainer:new{
        dimen = Geom:new{ w = W, h = bottom_h },
        self:statusBar(status_px, math.floor(W * 0.9), sx, sy),
    }
    return OverlapGroup:new{
        dimen = Geom:new{ w = W, h = H },
        top,
        clock_status,
    }
end

---------------------------------------------------------------- calendar mode

function DeskWidget:buildGrid(w, h, ox, oy)
    local store = self.store
    local now = store:now()
    local today = ICS.dayStart(now)
    local td = os.date("!*t", now)
    local mi = td.month - 1 + self.month_offset
    local year, month = td.year + math.floor(mi / 12), mi % 12 + 1

    local title_h = math.floor(h * 0.12)
    local head_h = math.floor(h * 0.07)
    local title_px = title_h * 0.62

    -- Right side of the title: the time, "as of" when asleep, or a
    -- "back to today" button while browsing another month/date.
    local right_widget
    self.today_button = nil
    if self.sleeping then
        right_widget = text(os.date("!%m/%d %H:%M 기준", self.sleep_time or now), title_px * 0.42, { color = GRAY })
    elseif self:isBrowsing() then
        local label = text("◀ 오늘로", title_px * 0.5, { bold = true, color = WHITE })
        local bsize = label:getSize()
        local padx, pady = math.floor(title_px * 0.3), math.floor(title_px * 0.15)
        right_widget = FrameContainer:new{
            bordersize = 0, margin = 0, radius = 0,
            padding = 0, padding_left = padx, padding_right = padx, padding_top = pady, padding_bottom = pady,
            background = BLACK,
            width = bsize.w + 2 * padx, height = bsize.h + 2 * pady,
            label,
        }
        -- Generous touch target: the whole right half of the title row.
        self.today_button = { x = (ox or 0) + math.floor(w / 2), y = oy or 0, w = math.ceil(w / 2), h = title_h }
    else
        right_widget = text(string.format("%02d:%02d", td.hour, td.min), title_px * 0.85)
    end
    local title = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = title_h },
        LeftContainer:new{ dimen = Geom:new{ w = w, h = title_h },
            text(string.format("%d년 %d월", year, month), title_px, { bold = true }) },
        RightContainer:new{ dimen = Geom:new{ w = w, h = title_h }, right_widget },
    }

    local first = ICS.timegm(year, month, 1)
    local first_wd = ICS.weekday(first)
    local dim = ICS.daysInMonth(year, month)
    local rows = math.ceil((first_wd + dim) / 7)
    local cell_w = math.floor(w / 7)
    local sep = 1
    local cell_h = math.floor((h - title_h - head_h - sep * rows) / rows)

    local grid = VerticalGroup:new{ align = "left", title }
    local head = HorizontalGroup:new{}
    for i = 1, 7 do
        table.insert(head, CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = head_h },
            text(WDAY[i], head_h * 0.55, { color = (i == 1 or i == 7) and GRAY or BLACK, bold = true }),
        })
    end
    table.insert(grid, head)

    self.cell_rects = {}
    local border = math.max(2, math.floor(cell_w * 0.03))

    -- Google-Calendar-like marks (without titles):
    --   timed event          -> dot
    --   one all-day day      -> short bar
    --   multi-day event      -> bar joined across the days it covers
    -- Bars sit in up to MAX_LANES fixed lanes so a multi-day bar stays at the
    -- same height in every cell it crosses.
    local MAX_LANES = 2
    local grid_start = first
    local grid_end = first + dim * DAY
    local spans = {}
    for _, o in ipairs(store.occurrences or {}) do
        local sday = ICS.dayStart(o.start)
        local eday = ICS.dayStart(math.max(o.start, o.stop - 1))
        if (o.allday or eday > sday) and o.stop > grid_start and o.start < grid_end then
            table.insert(spans, { s = sday, e = eday })
        end
    end
    table.sort(spans, function(a, b)
        if a.s ~= b.s then return a.s < b.s end
        return (a.e - a.s) > (b.e - b.s)
    end)
    local lane_end = {}
    local lanes_by_day = {}   -- day -> { [lane] = span }
    local extra_by_day = {}   -- day -> count of bar events that did not fit
    for _, sp in ipairs(spans) do
        local lane
        for l = 1, MAX_LANES do
            if not lane_end[l] or lane_end[l] < sp.s then lane = l break end
        end
        local d = math.max(sp.s, grid_start)
        while d <= sp.e and d < grid_end do
            if lane then
                lanes_by_day[d] = lanes_by_day[d] or {}
                lanes_by_day[d][lane] = sp
            else
                extra_by_day[d] = (extra_by_day[d] or 0) + 1
            end
            d = d + DAY
        end
        if lane then lane_end[lane] = sp.e end
    end

    -- Fixed vertical budget so marks line up across cells.
    local lane_h = math.max(5, math.floor(cell_h * 0.10))
    local thick = math.max(3, math.floor(lane_h * 0.55))
    local dot_px = math.max(10, cell_h * 0.17)
    local num_px = math.min(cell_h * 0.36, cell_w * 0.40)
    local num_h = text("0", num_px):getSize().h
    local dot_h = text("•", dot_px):getSize().h
    local budget = math.floor(cell_h * 0.94)
    if num_h + MAX_LANES * lane_h + dot_h > budget then
        num_px = num_px * (budget - MAX_LANES * lane_h - dot_h) / num_h
    end
    local inset = math.floor(cell_w * 0.12)
    for r = 0, rows - 1 do
        table.insert(grid, LineWidget:new{ background = LIGHT, dimen = Geom:new{ w = cell_w * 7, h = sep } })
        local row = HorizontalGroup:new{}
        for c = 0, 6 do
            local dn = r * 7 + c - first_wd + 1
            local cell_content
            local bg = WHITE
            local selected = false
            if dn >= 1 and dn <= dim then
                local day = first + (dn - 1) * DAY
                local is_today = day == today
                selected = self.selected_day == day
                table.insert(self.cell_rects, {
                    x = (ox or 0) + c * cell_w,
                    y = (oy or 0) + title_h + head_h + r * (sep + cell_h) + sep,
                    w = cell_w, h = cell_h, day = day,
                })
                local holiday = store:holidaysOnDay(day)
                local color = (c == 0 or c == 6 or holiday) and GRAY or BLACK
                if is_today then
                    bg = BLACK
                    color = WHITE
                end
                local mark = is_today and WHITE or BLACK
                local inner_w = cell_w - 2 * (selected and border or 0)
                -- timed, single-day events -> dots (+ bar events that found no lane)
                local ndots = extra_by_day[day] or 0
                for _, o in ipairs(store:eventsOnDay(day)) do
                    local sday = ICS.dayStart(o.start)
                    local eday = ICS.dayStart(math.max(o.start, o.stop - 1))
                    if not o.allday and eday == sday then ndots = ndots + 1 end
                end
                cell_content = VerticalGroup:new{
                    align = "center",
                    text(tostring(dn), num_px, { bold = is_today or holiday ~= nil, color = color }),
                }
                local lanes = lanes_by_day[day] or {}
                for l = 1, MAX_LANES do
                    local sp = lanes[l]
                    if sp then
                        -- reach the cell edge where the event continues (same week row)
                        local left = (sp.s < day and c > 0) and 0 or inset
                        local right = (sp.e > day and c < 6) and 0 or inset
                        table.insert(cell_content, CenterContainer:new{
                            dimen = Geom:new{ w = inner_w, h = lane_h },
                            HorizontalGroup:new{
                                align = "center",
                                HorizontalSpan:new{ width = left },
                                LineWidget:new{ background = mark,
                                    dimen = Geom:new{ w = math.max(2, inner_w - left - right), h = thick } },
                                HorizontalSpan:new{ width = right },
                            },
                        })
                    else
                        table.insert(cell_content, VerticalSpan:new{ width = lane_h })
                    end
                end
                table.insert(cell_content,
                    text(ndots > 0 and string.rep("•", math.min(ndots, 3)) or " ", dot_px, { color = mark }))
            else
                cell_content = VerticalSpan:new{ width = 0 }
            end
            local b = selected and border or 0
            table.insert(row, FrameContainer:new{
                bordersize = b, padding = 0, margin = 0, radius = 0,
                color = BLACK,
                background = bg,
                width = cell_w, height = cell_h,
                CenterContainer:new{ dimen = Geom:new{ w = cell_w - 2 * b, h = cell_h - 2 * b }, cell_content },
            })
        end
        table.insert(grid, row)
    end
    return grid
end

function DeskWidget:buildList(w, h, ox, oy)
    local store = self.store
    local now = store:now()
    local today = ICS.dayStart(now)
    local m = math.min(Screen:getWidth(), Screen:getHeight())
    local head_px = m * 0.040
    local item_px = m * 0.034
    local status_px = m * 0.026
    local status_h = math.floor(status_px * 2.3)
    -- leave room for the status bar and for the "…" line shown when the list overflows
    local avail = h - status_h - math.floor(item_px * 1.4)

    -- Asleep: open to-dos under the events (a few rows reserved for them)
    local todo_open = {}
    if self.sleeping then
        for _, mm in ipairs(Memo:memos()) do
            if not mm.done then todo_open[#todo_open + 1] = mm end
        end
    end
    local todo_row_h = text("가", item_px):getSize().h + math.floor(item_px * 0.28)
    local todo_head_h = text("가", head_px, { bold = true }):getSize().h + math.floor(item_px * 0.25)
    local todo_reserve = 0
    if #todo_open > 0 then
        -- today's events come first: keep just two to-do rows for sure (the heading shows the total)
        todo_reserve = math.floor(item_px * 0.9) + 1 + todo_head_h + math.min(#todo_open, 2) * todo_row_h
        avail = avail - todo_reserve
    end

    local list = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(widget, gap)
        local hgt = widget:getSize().h + (gap or 0)
        if used + hgt > avail then return false end
        table.insert(list, widget)
        if gap and gap > 0 then table.insert(list, VerticalSpan:new{ width = gap }) end
        used = used + hgt
        return true
    end

    -- Picked date > first day of a browsed month > today.
    local base = self.selected_day
        or (self.month_offset ~= 0 and self:displayedMonthStart())
        or today

    local list_time_col = text("00:00–00:00", item_px, { bold = true }):getSize().w
    local drow = self:ddayRow(item_px, w, 2)
    if drow then
        add(drow, math.floor(item_px * 0.45))
        add(LineWidget:new{ background = LIGHT, dimen = Geom:new{ w = w, h = 1 } }, math.floor(item_px * 0.5))
    end
    local full = false
    for i = 0, 13 do
        local day = base + i * DAY
        local events = store:eventsOnDay(day)
        local holiday = store:holidaysOnDay(day)
        if i == 0 or #events > 0 or holiday then
            local d = os.date("!*t", day)
            local label = string.format("%d월 %d일 (%s)", d.month, d.day, WDAY[d.wday])
            local diff = math.floor((day - today) / DAY)
            local rel = (diff >= 0 and diff <= 2) and dayLabel(day, today) or nil
            if rel then label = label .. "  " .. rel end
            if holiday then label = label .. "  · " .. table.concat(holiday, ", ") end
            if used > 0 then
                if not add(VerticalSpan:new{ width = math.floor(item_px * 0.6) }) then full = true break end
            end
            if not add(text(label, head_px, { bold = true, max_width = w }), math.floor(item_px * 0.25)) then full = true break end
            if #events == 0 then
                if not add(text("  일정 없음", item_px, { color = GRAY, max_width = w }), math.floor(item_px * 0.2)) then full = true break end
            end
            for _, o in ipairs(events) do
                local past = not o.allday and (o.stop > o.start and o.stop or o.start + 60) <= now
                local indent = math.floor(item_px * 0.6)
                -- fixed-width time column so "종일" and "13:15–14:15" titles line up
                local time_w = text(eventTime(o, day), item_px, { color = past and GRAY or BLACK, bold = not past })
                local th = time_w:getSize().h
                local line = HorizontalGroup:new{
                    align = "top",
                    HorizontalSpan:new{ width = indent },
                    LeftContainer:new{ dimen = Geom:new{ w = math.max(list_time_col, time_w:getSize().w), h = th }, time_w },
                    HorizontalSpan:new{ width = indent },
                    wrapText(o.summary, item_px, math.max(item_px * 3, w - 2 * indent - math.max(list_time_col, time_w:getSize().w)), 2,
                        { color = past and GRAY or BLACK }),
                }
                local row_y = used
                if not add(line, math.floor(item_px * 0.2)) then full = true break end
                table.insert(self.event_rects, {
                    x = ox or 0, y = (oy or 0) + row_y, w = w, h = line:getSize().h,
                    occ = o, day = day,
                })
            end
            if full then break end
        end
    end
    if full then
        table.insert(list, text("  …", item_px, { color = GRAY }))
        used = used + text("  …", item_px):getSize().h
    end

    if #todo_open > 0 then
        local sep = math.floor(item_px * 0.45)
        table.insert(list, VerticalSpan:new{ width = sep })
        table.insert(list, LineWidget:new{ background = LIGHT, dimen = Geom:new{ w = w, h = 1 } })
        table.insert(list, VerticalSpan:new{ width = sep })
        table.insert(list, text(string.format("할 일 %d", #todo_open), head_px, { bold = true }))
        table.insert(list, VerticalSpan:new{ width = math.floor(item_px * 0.25) })
        -- whatever the events left over, at least the reserved rows
        local budget = (h - status_h) - used - 2 * sep - 1 - todo_head_h
        local rows = UI.todoRows(todo_open, item_px, w, budget, true)
        table.insert(list, rows)
    end

    local probe = self:statusBar(status_px, w, 0, 0)
    local ph = probe:getSize().h
    local list_status = self:statusBar(status_px, w, ox or 0,
        (oy or 0) + h - status_h + math.floor((status_h - ph) / 2))

    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        list,
        BottomContainer:new{
            dimen = Geom:new{ w = w, h = h },
            LeftContainer:new{ dimen = Geom:new{ w = w, h = status_h }, list_status },
        },
    }
end

function DeskWidget:buildCalendar(W, H)
    local m = math.min(W, H)
    local pad = math.floor(m * 0.04)
    local iw, ih = W - 2 * pad, H - 2 * pad
    local body
    if W > H then
        local gw = math.floor(iw * 0.50)
        local gap = math.floor(pad * 1.2)
        local list_x = pad + gw + gap + 1 + gap
        body = HorizontalGroup:new{
            align = "top",
            self:buildGrid(gw, ih, pad, pad),
            HorizontalSpan:new{ width = gap },
            LineWidget:new{ background = LIGHT, dimen = Geom:new{ w = 1, h = ih } },
            HorizontalSpan:new{ width = gap },
            self:buildList(iw - gw - 2 * gap - 1, ih, list_x, pad),
        }
    else
        -- asleep, the list also carries the to-dos: give it more of the page
        local gh = math.floor(ih * ((self.sleeping and Memo:openCount() > 0) and 0.47 or 0.56))
        local gap = math.floor(pad * 0.8)
        local list_y = pad + gh + gap + 1 + gap
        body = VerticalGroup:new{
            align = "left",
            self:buildGrid(iw, gh, pad, pad),
            VerticalSpan:new{ width = gap },
            LineWidget:new{ background = LIGHT, dimen = Geom:new{ w = iw, h = 1 } },
            VerticalSpan:new{ width = gap },
            self:buildList(iw, ih - gh - 2 * gap - 1, pad, list_y),
        }
    end
    return FrameContainer:new{
        bordersize = 0, margin = 0, padding = pad,
        background = WHITE,
        body,
    }
end

---------------------------------------------------------------- full-screen month

--- Popup listing everything on one day (used by the full-screen month).
--- Rows for the day popup: { time, title, past } per event of `day`.
function DeskWidget:dayEvents(day)
    local now = self.store:now()
    local events = {}
    for _, o in ipairs(self.store:eventsOnDay(day)) do
        local title = o.summary
        if o.location and o.location ~= "" then title = title .. "  (" .. o.location .. ")" end
        events[#events + 1] = {
            time = eventTime(o, day), title = title,
            past = not o.allday and (o.stop > o.start and o.stop or o.start + 60) <= now,
        }
    end
    return events
end

function DeskWidget:dayLabel(day)
    local d = os.date("!*t", day)
    local label = string.format("%d월 %d일 (%s)", d.month, d.day, WDAY[d.wday])
    local hol = self.store:holidaysOnDay(day)
    if hol then label = label .. "  · " .. table.concat(hol, ", ") end
    return label
end

function DeskWidget:showDayDetail(day)
    if self.todo_popup then return end
    -- To-dos have no date: they belong to "today", so today's popup lists them too.
    self.todo_popup = require("dc_todopopup").DayPopup:new{
        parent = self, day = day,
        with_todos = day == ICS.dayStart(self.store:now()),
    }
    UIManager:show(self.todo_popup)
end

function DeskWidget:buildMonth(W, H)
    local store = self.store
    local now = store:now()
    local today = ICS.dayStart(now)
    local td = os.date("!*t", now)
    local mi = td.month - 1 + self.month_offset
    local year, month = td.year + math.floor(mi / 12), mi % 12 + 1
    local m = math.min(W, H)
    local landscape = W > H
    local pad = math.floor(m * 0.022)

    local title_px = m * 0.044
    local small_px = m * 0.022
    local ev_px = math.max(15, m * 0.0175)
    local line_h = math.floor(ev_px * 1.45)

    ------------------------------------------------ header
    local title = text(string.format("%d년 %d월", year, month), title_px, { bold = true })
    local title_w = title:getSize().w
    local title_h = title:getSize().h

    -- right side: time / "기준" / [오늘로], then status + [동기화]
    local right_left
    self.today_button = nil
    if self.sleeping then
        right_left = text(os.date("!%m/%d %H:%M 기준", self.sleep_time or now), small_px, { color = GRAY })
    elseif self:isBrowsing() then
        local lbl = text("◀ 오늘로", small_px * 1.1, { bold = true, color = WHITE })
        local ls = lbl:getSize()
        local px_, py_ = math.floor(small_px * 0.5), math.floor(small_px * 0.2)
        right_left = FrameContainer:new{
            bordersize = 0, margin = 0, radius = 0, background = BLACK,
            padding = 0, padding_left = px_, padding_right = px_, padding_top = py_, padding_bottom = py_,
            width = ls.w + 2 * px_, height = ls.h + 2 * py_,
            lbl,
        }
    else
        right_left = text(string.format("%02d:%02d", td.hour, td.min), title_px * 0.8)
    end
    local rl = right_left:getSize()
    local gap = math.floor(small_px * 1.2)
    local status_max = math.floor(W * (landscape and 0.36 or 0.55))
    local probe = self:statusBar(small_px, status_max, 0, 0)
    local ps = probe:getSize()
    local header_h = math.max(title:getSize().h, rl.h, ps.h)
    local right_w = rl.w + gap + ps.w
    local right_x = W - pad - right_w
    local sb_x = right_x + rl.w + gap
    local sb_y = pad + math.floor((header_h - ps.h) / 2)
    local sbar = self:statusBar(small_px, status_max, sb_x, sb_y)
    if self:isBrowsing() and not self.sleeping then
        self.today_button = { x = right_x - gap, y = 0, w = rl.w + 2 * gap, h = pad + header_h + gap }
    end
    -- the title text (plus a little slack) syncs; the rest of the line still switches screens
    local slack = math.floor(title_h * 0.2)
    self.month_title_rect = { x = 0, y = 0, w = pad + title_w + slack, h = pad + header_h + slack }
    local right = HorizontalGroup:new{ align = "center", right_left, HorizontalSpan:new{ width = gap }, sbar }

    -- D-day: beside the title in landscape, on its own line in portrait
    local dday_line
    local header_row
    if landscape then
        local dmax = W - 2 * pad - title_w - right_w - 3 * gap
        local drow = self:ddayRow(small_px, dmax, 2)
        if drow and drow:getSize().h > small_px * 1.8 then drow = self:ddayRow(small_px, dmax, 1) end
        local left = HorizontalGroup:new{ align = "center", title }
        if drow then
            table.insert(left, HorizontalSpan:new{ width = 2 * gap })
            table.insert(left, drow)
        end
        header_row = left
    else
        header_row = title
        dday_line = self:ddayRow(small_px, W - 2 * pad, 2)
    end
    local header = OverlapGroup:new{
        dimen = Geom:new{ w = W - 2 * pad, h = header_h },
        LeftContainer:new{ dimen = Geom:new{ w = W - 2 * pad, h = header_h }, header_row },
        RightContainer:new{ dimen = Geom:new{ w = W - 2 * pad, h = header_h }, right },
    }
    local page = VerticalGroup:new{ align = "left", header }
    local top = pad + header_h
    if dday_line then
        table.insert(page, VerticalSpan:new{ width = math.floor(small_px * 0.4) })
        table.insert(page, dday_line)
        top = top + math.floor(small_px * 0.4) + dday_line:getSize().h
    end

    ------------------------------------------------ weekday row
    local gw = W - 2 * pad
    local cell_w = math.floor(gw / 7)
    local head_h = math.floor(small_px * 1.9)
    local head = HorizontalGroup:new{}
    for i = 1, 7 do
        table.insert(head, CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = head_h },
            text(WDAY[i], small_px, { bold = true, color = (i == 1 or i == 7) and GRAY or BLACK }),
        })
    end
    table.insert(page, VerticalSpan:new{ width = math.floor(small_px * 0.5) })
    table.insert(page, head)
    top = top + math.floor(small_px * 0.5) + head_h

    ------------------------------------------------ grid
    local first = ICS.timegm(year, month, 1)
    local first_wd = ICS.weekday(first)
    local dim = ICS.daysInMonth(year, month)
    local rows = math.ceil((first_wd + dim) / 7)
    local sep = 1
    local cell_h = math.floor((H - pad - top - sep * rows) / rows)
    local num_px = math.min(small_px * 1.15, cell_h * 0.2)
    local num_h = math.floor(text("0", num_px):getSize().h * 1.05)
    local cell_lines = math.max(1, math.floor((cell_h - num_h - 4) / line_h))
    local show_time = cell_w > ev_px * 8.5
    local inset = 3
    local bar_h = line_h - 3

    -- bar-type events (all-day or spanning several days) in the month
    local month_end = first + dim * DAY
    local spans = {}
    for _, o in ipairs(store.occurrences or {}) do
        local sday = ICS.dayStart(o.start)
        local eday = ICS.dayStart(math.max(o.start, o.stop - 1))
        if (o.allday or eday > sday) and o.stop > first and o.start < month_end then
            table.insert(spans, { s = sday, e = eday, title = o.summary })
        end
    end
    table.sort(spans, function(a, b)
        if a.s ~= b.s then return a.s < b.s end
        return (a.e - a.s) > (b.e - b.s)
    end)

    self.cell_rects = {}
    for r = 0, rows - 1 do
        table.insert(page, LineWidget:new{ background = LIGHT, dimen = Geom:new{ w = cell_w * 7, h = sep } })
        local week_start = first + (r * 7 - first_wd) * DAY
        local week_end = week_start + 6 * DAY
        -- lane assignment within this week
        local lanes = {}      -- lane -> list of spans
        local lane_of = {}    -- span -> lane
        local hidden = {}     -- day -> number of bars without a lane
        for _, sp in ipairs(spans) do
            if sp.e >= week_start and sp.s <= week_end then
                local placed
                for l = 1, cell_lines do
                    local free = true
                    for _, other in ipairs(lanes[l] or {}) do
                        if not (sp.e < other.s or sp.s > other.e) then free = false break end
                    end
                    if free then
                        lanes[l] = lanes[l] or {}
                        table.insert(lanes[l], sp)
                        lane_of[sp] = l
                        placed = true
                        break
                    end
                end
                if not placed then
                    for dd = math.max(sp.s, week_start), math.min(sp.e, week_end), DAY do
                        hidden[dd] = (hidden[dd] or 0) + 1
                    end
                end
            end
        end

        local row = HorizontalGroup:new{ align = "top" }
        for c = 0, 6 do
            local day = week_start + c * DAY
            local dn = r * 7 + c - first_wd + 1
            local cell = VerticalGroup:new{ align = "left" }
            if dn >= 1 and dn <= dim then
                table.insert(self.cell_rects, {
                    x = pad + c * cell_w,
                    y = top + r * (cell_h + sep) + sep,
                    w = cell_w, h = cell_h, day = day,
                })
                local holiday = store:holidaysOnDay(day)
                local weekend = c == 0 or c == 6
                local num
                if day == today then
                    local t_ = text(tostring(dn), num_px, { bold = true, color = WHITE })
                    local ts = t_:getSize()
                    local px_ = math.floor(num_px * 0.35)
                    num = FrameContainer:new{
                        bordersize = 0, margin = 0, radius = math.floor(ts.h / 2), background = BLACK,
                        padding = 0, padding_left = px_, padding_right = px_,
                        width = ts.w + 2 * px_, height = ts.h,
                        t_,
                    }
                else
                    num = text(tostring(dn), num_px, { bold = holiday ~= nil,
                        color = (weekend or holiday) and GRAY or BLACK })
                end
                table.insert(cell, CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = num_h }, num })

                -- lines: bars in their lanes, then holiday names, then timed events
                local used = 0
                for l = 1, cell_lines do
                    for _, sp in ipairs(lanes[l] or {}) do
                        if sp.s <= day and sp.e >= day then used = l end
                    end
                end
                for l = 1, used do
                    local sp
                    for _, cand in ipairs(lanes[l] or {}) do
                        if cand.s <= day and cand.e >= day then sp = cand end
                    end
                    if sp then
                        local left = (sp.s < day and c > 0) and 0 or inset
                        local right = (sp.e > day and c < 6) and 0 or inset
                        local bw = math.max(2, cell_w - left - right)
                        local label = VerticalSpan:new{ width = 0 }
                        if sp.s == day or c == 0 then
                            label = text(sp.title, ev_px, { bold = true, color = WHITE, max_width = bw - 8 })
                        end
                        -- NOTE: FrameContainer width/height do not count in layout;
                        -- the bar's size must come from a widget that really has it.
                        table.insert(cell, HorizontalGroup:new{ align = "top",
                            HorizontalSpan:new{ width = left },
                            OverlapGroup:new{
                                dimen = Geom:new{ w = bw, h = bar_h },
                                LineWidget:new{ background = BLACK, dimen = Geom:new{ w = bw, h = bar_h } },
                                LeftContainer:new{ dimen = Geom:new{ w = bw, h = bar_h },
                                    HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = 5 }, label } },
                            },
                            HorizontalSpan:new{ width = right },
                        })
                        table.insert(cell, VerticalSpan:new{ width = line_h - bar_h })
                    else
                        table.insert(cell, VerticalSpan:new{ width = line_h })
                    end
                end

                local items = {}
                for _, name in ipairs(holiday or {}) do
                    table.insert(items, { text = name, color = GRAY })
                end
                for _, o in ipairs(store:eventsOnDay(day)) do
                    local sday = ICS.dayStart(o.start)
                    local eday = ICS.dayStart(math.max(o.start, o.stop - 1))
                    if not o.allday and eday == sday then
                        table.insert(items, { text = (show_time and (hm(o.start) .. " ") or "") .. o.summary })
                    end
                end
                local extra = hidden[day] or 0
                local room = cell_lines - used
                local n_show = #items
                if #items + (extra > 0 and 1 or 0) > room then
                    n_show = math.max(0, room - 1)
                end
                for k = 1, n_show do
                    local it = items[k]
                    table.insert(cell, HorizontalGroup:new{ align = "center",
                        HorizontalSpan:new{ width = 4 },
                        text("• " .. it.text, ev_px, { color = it.color or BLACK, max_width = cell_w - 8 }),
                    })
                    table.insert(cell, VerticalSpan:new{ width = math.max(0, line_h - text("•", ev_px):getSize().h) })
                end
                local more = (#items - n_show) + extra
                if more > 0 and room > 0 then
                    table.insert(cell, HorizontalGroup:new{ align = "center",
                        HorizontalSpan:new{ width = 4 },
                        text("+" .. more .. "개 더", ev_px, { color = GRAY }),
                    })
                end
            end
            -- fixed cell size, independent of how much is written in it
            table.insert(row, WidgetContainer:new{
                dimen = Geom:new{ w = cell_w, h = cell_h },
                cell,
            })
        end
        table.insert(page, row)
    end

    return FrameContainer:new{
        bordersize = 0, margin = 0, padding = pad, padding_bottom = 0,
        background = WHITE,
        page,
    }
end

---------------------------------------------------------------- memo screen & input

local function fmtDate(day)
    local d = os.date("!*t", day)
    return string.format("%d/%d(%s)", d.month, d.day, WDAY[d.wday])
end

local function isoDate(day)
    return os.date("!%Y-%m-%d", day)
end

--- Ask for a title, then (if no day given) a date, then all-day or a time;
-- queue the event and send it right away (Wi-Fi on -> send -> sync -> off).
function DeskWidget:askEventTitle(preset_title, day)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = day and (fmtDate(day) .. " 일정 추가") or "일정 추가",
        input = preset_title or "",
        input_hint = "일정 제목",
        buttons = {{
            { text = "취소", id = "close", callback = function() UIManager:close(dialog) end },
            { text = "다음", is_enter_default = true, callback = function()
                local title = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", ""):gsub("\n", " ")
                UIManager:close(dialog)
                if title == "" then return end
                if day then self:askEventTime(title, day) else self:askEventDate(title) end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function DeskWidget:askEventDate(title)
    local DateTimeWidget = require("ui/widget/datetimewidget")
    local t = os.date("!*t", self.store:now())
    UIManager:show(DateTimeWidget:new{
        year = t.year, month = t.month, day = t.day,
        title_text = "날짜 선택", ok_text = "다음",
        callback = function(v)
            self:askEventTime(title, ICS.timegm(v.year, v.month, v.day))
        end,
    })
end

function DeskWidget:askEventTime(title, day)
    local ButtonDialog = require("ui/widget/buttondialog")
    local bd
    bd = ButtonDialog:new{
        title = fmtDate(day) .. "  " .. title,
        buttons = {
            {
                { text = "종일", callback = function()
                    UIManager:close(bd)
                    self:queueEvent{ title = title, date = isoDate(day) }
                end },
                { text = "시간 지정", callback = function()
                    UIManager:close(bd)
                    local DateTimeWidget = require("ui/widget/datetimewidget")
                    UIManager:show(DateTimeWidget:new{
                        hour = 9, min = 0,
                        title_text = "시작 시각 (1시간 일정)", ok_text = "추가",
                        callback = function(v)
                            self:queueEvent{ title = title, date = isoDate(day),
                                time = string.format("%02d:%02d", v.hour, v.min), minutes = 60 }
                        end,
                    })
                end },
            },
            { { text = "취소", callback = function() UIManager:close(bd) end } },
        },
    }
    UIManager:show(bd)
end

function DeskWidget:queueEvent(ev)
    Memo:addEvent(ev)
    self.store:mergeLocal()
    self:refresh(true)
    if not self.store:getPostUrl() then
        UIManager:show(InfoMessage:new{ text =
            "일정을 기기에 저장했습니다.\n구글 캘린더로 보내려면 KOReader 폴더에 deskclock_write.txt(쓰기 주소)를 넣으세요." })
        return
    end
    self:syncNow()
end

function DeskWidget:editMemo(m)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = m and "메모 수정" or "메모 추가",
        input = m and m.text or "",
        input_hint = "메모",
        allow_newline = true,
        buttons = {{
            { text = "취소", id = "close", callback = function() UIManager:close(dialog) end },
            { text = "저장", callback = function()
                local text = dialog:getInputText()
                UIManager:close(dialog)
                if m then Memo:updateMemo(m.id, text) else Memo:addMemo(text) end
                self:refresh(true)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function DeskWidget:onMemoItem(r)
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    if r.kind == "add_memo" then return self:editMemo(nil) end
    if r.kind == "add_event" then return self:askEventTitle(nil, nil) end
    if r.kind == "check" then
        Memo:toggleDone(r.memo.id)
        self:refresh(false)
        return
    end
    if r.kind == "clear_done" then
        local n = Memo:doneCount()
        UIManager:show(ConfirmBox:new{
            text = string.format("완료한 항목 %d개를 지울까요?", n)
                .. (self.store:getSettings().tasks_sync ~= false and self.store:getPostUrl()
                    and "\n(구글 할 일에서도 다음 동기화 때 지워집니다)" or ""),
            ok_text = "지우기",
            ok_callback = function() Memo:clearDone(); self:refresh(true) end,
        })
        return
    end
    local bd
    if r.kind == "memo" then
        local m = r.memo
        bd = ButtonDialog:new{
            title = m.text,
            buttons = {
                {
                    { text = m.done and "완료 취소" or "완료", callback = function()
                        UIManager:close(bd); Memo:toggleDone(m.id); self:refresh(false) end },
                    { text = "수정", callback = function() UIManager:close(bd); self:editMemo(m) end },
                    { text = "일정으로 등록", callback = function()
                        UIManager:close(bd)
                        self:askEventTitle(m.text:match("^[^\n]*"):sub(1, 200), nil)
                    end },
                },
                {
                    { text = "삭제", callback = function()
                        UIManager:close(bd)
                        UIManager:show(ConfirmBox:new{
                            text = "이 메모를 삭제할까요?", ok_text = "삭제",
                            ok_callback = function() Memo:deleteMemo(m.id); self:refresh(true) end,
                        })
                    end },
                    { text = "닫기", callback = function() UIManager:close(bd) end },
                },
            },
        }
    elseif r.kind == "event" then
        local it = r.item
        local rows = {}
        if it.state ~= "sent" then
            table.insert(rows, { { text = "지금 보내기", callback = function()
                UIManager:close(bd); self:syncNow() end } })
        end
        table.insert(rows, {
            { text = it.state == "sent" and "목록에서 지우기" or "보내지 않고 삭제", callback = function()
                UIManager:close(bd)
                Memo:removeEvent(it.uid)
                self.store:mergeLocal()
                self:refresh(true)
            end },
            { text = "닫기", callback = function() UIManager:close(bd) end },
        })
        bd = ButtonDialog:new{ title = it.title, buttons = rows }
    end
    if bd then UIManager:show(bd) end
end

function DeskWidget:buildMemo(W, H)
    local now = self.store:now()
    local td = os.date("!*t", now)
    local m = math.min(W, H)
    local pad = math.floor(m * 0.03)
    local title_px = m * 0.044
    local small_px = m * 0.022
    local item_px = m * 0.03
    local cw = W - 2 * pad

    ------------------------------------------------ header (same pattern as month)
    local title = text("메모", title_px, { bold = true })
    local time_w = text(string.format("%02d:%02d", td.hour, td.min), title_px * 0.8)
    local gap = math.floor(small_px * 1.2)
    local status_max = math.floor(W * 0.5)
    local ps = self:statusBar(small_px, status_max, 0, 0):getSize()
    local header_h = math.max(title:getSize().h, time_w:getSize().h, ps.h)
    local right_w = time_w:getSize().w + gap + ps.w
    local sb_x = W - pad - right_w + time_w:getSize().w + gap
    local sbar = self:statusBar(small_px, status_max, sb_x, pad + math.floor((header_h - ps.h) / 2))
    local header = OverlapGroup:new{
        dimen = Geom:new{ w = cw, h = header_h },
        LeftContainer:new{ dimen = Geom:new{ w = cw, h = header_h }, title },
        RightContainer:new{ dimen = Geom:new{ w = cw, h = header_h },
            HorizontalGroup:new{ align = "center", time_w, HorizontalSpan:new{ width = gap }, sbar } },
    }
    local page = VerticalGroup:new{ align = "left", header }
    local y = pad + header_h

    ------------------------------------------------ action buttons
    local function button(label)
        local t = text(label, item_px, { bold = true })
        local ts = t:getSize()
        local px_, py_ = math.floor(item_px * 0.6), math.floor(item_px * 0.25)
        return FrameContainer:new{
            bordersize = 2, margin = 0, radius = 0, color = BLACK, background = WHITE,
            padding = 0, padding_left = px_, padding_right = px_, padding_top = py_, padding_bottom = py_,
            t,
        }, ts.w + 2 * px_ + 4, ts.h + 2 * py_ + 4
    end
    local b1, b1w, bh = button("+ 메모")
    local b2, b2w = button("+ 일정")
    local bgap = math.floor(item_px * 0.8)
    y = y + math.floor(item_px * 0.7)
    table.insert(page, VerticalSpan:new{ width = math.floor(item_px * 0.7) })
    local done_n = Memo:doneCount()
    local open_n = Memo:openCount()
    local brow = HorizontalGroup:new{ align = "center", b1, HorizontalSpan:new{ width = bgap }, b2 }
    local b3, b3w
    if done_n > 0 then
        b3, b3w = button("완료 지우기")
        table.insert(brow, HorizontalSpan:new{ width = bgap })
        table.insert(brow, b3)
    end
    -- counts on the right of the button row
    local counts = text(string.format("할 일 %d · 완료 %d", open_n, done_n), small_px, { color = GRAY })
    table.insert(page, OverlapGroup:new{
        dimen = Geom:new{ w = cw, h = bh },
        LeftContainer:new{ dimen = Geom:new{ w = cw, h = bh }, brow },
        RightContainer:new{ dimen = Geom:new{ w = cw, h = bh }, counts },
    })
    local slack = math.floor(item_px * 0.4)
    table.insert(self.memo_rects, { kind = "add_memo", x = pad - slack, y = y - slack, w = b1w + 2 * slack, h = bh + 2 * slack })
    table.insert(self.memo_rects, { kind = "add_event", x = pad + b1w + bgap - slack, y = y - slack, w = b2w + 2 * slack, h = bh + 2 * slack })
    if b3 then
        table.insert(self.memo_rects, { kind = "clear_done", x = pad + b1w + b2w + 2 * bgap - slack, y = y - slack,
            w = b3w + 2 * slack, h = bh + 2 * slack })
    end
    y = y + bh

    ------------------------------------------------ rows (outbox, then memos), paged
    local rows = {}
    local outbox = Memo:outbox()
    for _, it in ipairs(outbox) do
        local yy, mo, dd = it.date:match("^(%d+)-(%d+)-(%d+)$")
        local day = ICS.timegm(tonumber(yy), tonumber(mo), tonumber(dd))
        local state = it.state == "sent" and "보냄 · 구글 반영 대기"
            or (it.error and ("보내기 실패: " .. it.error) or "보내기 대기")
        table.insert(rows, { kind = "event", item = it,
            main = "◇ " .. fmtDate(day) .. " " .. (it.time or "종일") .. "  " .. it.title,
            sub = state, sub_color = (it.error and it.state ~= "sent") and BLACK or GRAY })
    end
    local tasks_on = self.store:getSettings().tasks_sync ~= false and self.store:getPostUrl()
    for _, mm in ipairs(Memo:memos()) do
        -- preview: line breaks shown as " · " so a multi-line memo is not cut at its first line
        local when = mm.done and mm.done_at and ("완료 " .. os.date("!%m/%d %H:%M", mm.done_at + self.store:offset()))
            or os.date("!%m/%d %H:%M", (mm.edited or mm.created) + self.store:offset())
        table.insert(rows, { kind = "memo", memo = mm, main = (mm.text:gsub("%s*\n+%s*", " · ")),
            done = mm.done,
            sub = when .. ((tasks_on and Memo:isUnsynced(mm)) and " · 구글 할 일 반영 전" or "") })
    end

    local avail = H - pad - y - math.floor(item_px * 2.2)
    local pages, cur, used = {}, {}, 0
    local built = {}
    -- check box column for memos
    local box = math.floor(item_px * 0.95)
    local box_gap = math.floor(item_px * 0.55)
    local tw_memo = cw - box - box_gap
    for i, r in ipairs(rows) do
        local is_memo = r.kind == "memo"
        local bw = is_memo and tw_memo or cw
        local body = wrapText(r.main, item_px, bw, is_memo and 3 or 2,
            r.done and { color = GRAY, strike = true } or nil)
        local sub = text(r.sub, small_px, { color = r.sub_color or GRAY, max_width = bw })
        local bsz, ssz = body:getSize(), sub:getSize()
        local h = math.floor(item_px * 0.6) + bsz.h + ssz.h + math.floor(item_px * 0.3) + 1
        local row
        if is_memo then
            local th = math.floor(item_px * 1.362 + 0.5)
            local mark = r.done and text("✓", item_px * 0.85, { bold = true, color = GRAY }) or VerticalSpan:new{ width = 0 }
            local checkbox = FrameContainer:new{
                bordersize = math.max(2, math.floor(item_px / 16)), radius = 0, margin = 0, padding = 0,
                color = r.done and GRAY or BLACK, background = WHITE,
                CenterContainer:new{ dimen = Geom:new{ w = box - 2 * math.max(2, math.floor(item_px / 16)),
                    h = box - 2 * math.max(2, math.floor(item_px / 16)) }, mark },
            }
            row = HorizontalGroup:new{ align = "top",
                VerticalGroup:new{ align = "left", VerticalSpan:new{ width = math.max(0, math.floor((th - box) / 2)) }, checkbox },
                HorizontalSpan:new{ width = box_gap },
                VerticalGroup:new{ align = "left", body, sub },
            }
        else
            row = VerticalGroup:new{ align = "left", body, sub }
        end
        built[i] = { row = row, h = h }
        if used + h > avail and #cur > 0 then
            table.insert(pages, cur); cur, used = {}, 0
        end
        table.insert(cur, i); used = used + h
    end
    if #cur > 0 then table.insert(pages, cur) end
    local npages = math.max(1, #pages)
    self.memo_page = math.min(math.max(1, self.memo_page or 1), npages)

    if #rows == 0 then
        table.insert(page, VerticalSpan:new{ width = math.floor(item_px * 1.5) })
        table.insert(page, text("메모가 없습니다. [+ 메모]로 추가하세요.", item_px, { color = GRAY, max_width = cw }))
    else
        y = y + math.floor(item_px * 0.5)
        table.insert(page, VerticalSpan:new{ width = math.floor(item_px * 0.5) })
        for _, i in ipairs(pages[self.memo_page] or {}) do
            local r, b = rows[i], built[i]
            table.insert(page, LineWidget:new{ background = LIGHT, dimen = Geom:new{ w = cw, h = 1 } })
            table.insert(page, VerticalSpan:new{ width = math.floor(item_px * 0.6) })
            table.insert(page, b.row)
            table.insert(page, VerticalSpan:new{ width = math.floor(item_px * 0.3) })
            if r.kind == "memo" then
                -- the box (with a generous margin) toggles done; the rest opens the menu
                local cwid = box + box_gap
                table.insert(self.memo_rects, { kind = "check", memo = r.memo,
                    x = pad - math.floor(pad * 0.8), y = y, w = cwid + math.floor(pad * 0.8), h = b.h })
                table.insert(self.memo_rects, { kind = "memo", memo = r.memo,
                    x = pad + cwid, y = y, w = cw - cwid, h = b.h })
            else
                table.insert(self.memo_rects, { kind = r.kind, memo = r.memo, item = r.item,
                    x = pad, y = y, w = cw, h = b.h })
            end
            y = y + b.h
        end
    end

    local footer = text(npages > 1 and string.format("%d / %d 쪽 · 좌우로 쓸어 넘기기", self.memo_page, npages)
        or "네모 칸: 완료 표시 · 글: 수정·삭제·일정 등록", small_px, { color = GRAY })
    return OverlapGroup:new{
        dimen = Geom:new{ w = W, h = H },
        FrameContainer:new{ bordersize = 0, margin = 0, padding = pad, padding_bottom = 0, background = WHITE, page },
        BottomContainer:new{ dimen = Geom:new{ w = W, h = H - pad }, footer },
    }
end

function DeskWidget:showTodoPopup()
    if self.todo_popup then return end
    self.todo_popup = require("dc_todopopup"):new{ parent = self }
    UIManager:show(self.todo_popup)
end


---------------------------------------------------------------- assemble

function DeskWidget:rebuild()
    self.event_rects = {}
    self.memo_rects = {}
    self.clock_todo_rects = {}
    self.sync_button = nil
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    local content
    local ok, res = pcall(function()
        -- Asleep, a frozen big clock would be misleading: always show the calendar.
        if self.mode == "month" then
            return self:buildMonth(W, H)
        end
        if self.mode == "memo" and not self.sleeping then
            return self:buildMemo(W, H)
        end
        if self.mode == "calendar" or self.sleeping then
            return self:buildCalendar(W, H)
        end
        return self:buildClock(W, H)
    end)
    if ok then
        content = res
    else
        require("logger").err("deskclock: render error", res)
        content = CenterContainer:new{ dimen = Geom:new{ w = W, h = H },
            text("화면 그리기 오류: " .. tostring(res), 24, { max_width = W - 40 }) }
    end
    self[1] = FrameContainer:new{
        bordersize = 0, margin = 0, padding = 0,
        background = WHITE,
        width = W, height = H,
        content,
    }
end

return DeskWidget
