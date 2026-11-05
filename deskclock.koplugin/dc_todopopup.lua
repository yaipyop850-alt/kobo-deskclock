--[[--
List popups drawn by the plugin (not KOReader's text box), so columns line up:
  * to-do popup  — the "할 일 N" badge on the clock/calendar/month screens
  * day popup    — a date tapped on the full-screen month (events, and for
                   today also the open to-dos, which can be ticked there)
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Memo = require("dc_memo")
local ICS = require("dc_ics")
local UI = require("dc_ui")
local Screen = Device.screen
local text, wrapText, inRect = UI.text, UI.wrapText, UI.inRect
local BLACK, WHITE, GRAY, LIGHT = UI.BLACK, UI.WHITE, UI.GRAY, UI.LIGHT


--- Generic list popup. Subclasses provide :title(), :hint() and :rows().
-- Row kinds: { kind="event", time=, title=, past= } · { kind="todo", memo= }
--            { kind="head", text= } · { kind="note", text= }
-- To-dos ticked while it is open stay listed (struck through) so a mistaken
-- tap can be undone; they go away on the next opening.
local ListPopup = InputContainer:extend{
    name = "DeskClockPopup",
    parent = nil,     -- DeskWidget
    ids = nil,        -- memo ids shown (snapshot when opened)
    page = 1,
    memo_button = true,
}

function ListPopup:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    if Device:isTouchDevice() then
        local full = function() return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } end
        self.ges_events = {
            TapPopup = { GestureRange:new{ ges = "tap", range = full } },
            HoldPopup = { GestureRange:new{ ges = "hold", range = full } },
            SwipePopup = { GestureRange:new{ ges = "swipe", range = full } },
        }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { "Back" } }
    end
    if not self.ids then self:snapshot() end
    self:build()
end

--- The to-dos captured when the popup opened, in their current state.
function ListPopup:todos()
    local by_id = {}
    for _, m in ipairs(Memo:memos()) do by_id[m.id] = m end
    local list = {}
    for _, id in ipairs(self.ids) do
        if by_id[id] then list[#list + 1] = by_id[id] end
    end
    return list
end

function ListPopup:openCount()
    local n = 0
    for _, m in ipairs(self:todos()) do if not m.done then n = n + 1 end end
    return n
end

function ListPopup:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local m = math.min(W, H)
    local pw = math.floor(W > H and W * 0.62 or W * 0.88)
    local pad = math.floor(m * 0.035)
    local iw = pw - 2 * pad
    local item_px = m * 0.034
    local small_px = m * 0.024
    local time_px = item_px * 0.85
    local bth = math.max(2, math.floor(m / 400))
    self.rects = {}

    -- header: title on the left, a hint on the right (when it fits)
    local head_h = text("가", item_px * 1.1, { bold = true }):getSize().h
    local title_w = text(self:title(), item_px * 1.1, { bold = true, max_width = iw })
    local header = OverlapGroup:new{
        dimen = Geom:new{ w = iw, h = head_h },
        LeftContainer:new{ dimen = Geom:new{ w = iw, h = head_h }, title_w },
    }
    -- asleep nothing can be tapped: no hint, no buttons
    local asleep = self.parent and self.parent.sleeping
    local hint = not asleep and self:hint() or nil
    if hint then
        local room = iw - title_w:getSize().w - math.floor(item_px)
        local ht = text(hint, small_px, { color = GRAY })
        if ht:getSize().w <= room then
            table.insert(header, RightContainer:new{ dimen = Geom:new{ w = iw, h = head_h }, ht })
        end
    end

    -- buttons (built first: their height limits the list)
    local function button(label, px)
        local t = text(label, px, { bold = true })
        local ts = t:getSize()
        local bx, by = math.floor(px * 0.7), math.floor(px * 0.3)
        return FrameContainer:new{
            bordersize = bth, radius = 0, margin = 0, color = BLACK, background = WHITE,
            padding = 0, padding_left = bx, padding_right = bx, padding_top = by, padding_bottom = by,
            t,
        }, ts.w + 2 * bx + 2 * bth, ts.h + 2 * by + 2 * bth
    end
    local bpx = item_px * 0.85
    local _, _, btn_h = button("가", bpx)

    -- column geometry shared by all rows
    local box = math.floor(item_px * 0.9)
    local bgap = math.floor(item_px * 0.5)
    local line_h = math.floor(item_px * 1.362 + 0.5)
    -- fixed time column: titles always start on the same vertical line
    local time_col = text("00:00–00:00", time_px):getSize().w
    local tgap = math.floor(item_px * 0.9)
    local row_pad = math.floor(item_px * 0.38)
    local max_list = math.floor(H * 0.78) - 2 * pad - head_h - btn_h - math.floor(item_px * 1.6)

    -- build every row once, then page them
    local rows = self:rows()
    local built, pages, cur, used = {}, {}, {}, 0
    for i, r in ipairs(rows) do
        local w, h
        if r.kind == "todo" then
            local done = r.memo.done
            local body = wrapText((r.memo.text:gsub("%s*\n+%s*", " · ")), item_px, iw - box - bgap, 2,
                done and { color = GRAY, strike = true } or nil)
            local cb = UI.checkbox(box, done, item_px * 0.8)
            w = HorizontalGroup:new{ align = "top",
                VerticalGroup:new{ align = "left", VerticalSpan:new{ width = math.max(0, math.floor((line_h - box) / 2)) }, cb },
                HorizontalSpan:new{ width = bgap },
                body,
            }
            h = body:getSize().h
        elseif r.kind == "event" then
            local body = wrapText(r.title, item_px, iw - time_col - tgap, 2, r.past and { color = GRAY } or nil)
            w = HorizontalGroup:new{ align = "top",
                LeftContainer:new{ dimen = Geom:new{ w = time_col, h = line_h },
                    text(r.time, time_px, { color = GRAY, bold = not r.past }) },
                HorizontalSpan:new{ width = tgap },
                body,
            }
            h = body:getSize().h
        elseif r.kind == "head" then
            w = text(r.text, item_px, { bold = true, max_width = iw })
            h = w:getSize().h
        else -- note
            w = text(r.text, item_px, { color = GRAY, max_width = iw })
            h = w:getSize().h
        end
        -- a heading gets extra room above it and no separator line
        local top = r.kind == "head" and math.floor(item_px * 0.9) or row_pad
        local total = top + h + row_pad + (r.kind == "head" and 0 or 1)
        built[i] = { widget = w, h = h, top = top, total = total }
        -- never leave a heading alone at the bottom of a page
        local need = total
        if r.kind == "head" and rows[i + 1] then need = need + line_h + 2 * row_pad end
        if used + need > max_list and #cur > 0 then
            table.insert(pages, cur); cur, used = {}, 0
        end
        table.insert(cur, i); used = used + total
    end
    if #cur > 0 then table.insert(pages, cur) end
    local npages = math.max(1, #pages)
    self.page = math.min(math.max(1, self.page), npages)

    local content = VerticalGroup:new{ align = "left", header,
        VerticalSpan:new{ width = math.floor(item_px * 0.4) } }
    local y = pad + head_h + math.floor(item_px * 0.4) -- relative to the frame's inner top-left
    local row_rects = {}
    for _, i in ipairs(pages[self.page] or {}) do
        local r, b = rows[i], built[i]
        if r.kind ~= "head" then
            table.insert(content, LineWidget:new{ background = LIGHT, dimen = Geom:new{ w = iw, h = 1 } })
        end
        table.insert(content, VerticalSpan:new{ width = b.top })
        table.insert(content, b.widget)
        table.insert(content, VerticalSpan:new{ width = row_pad })
        if r.kind == "todo" then
            table.insert(row_rects, { y = y, h = b.total, id = r.memo.id })
        end
        y = y + b.total
    end
    table.insert(content, LineWidget:new{ background = LIGHT, dimen = Geom:new{ w = iw, h = 1 } })
    table.insert(content, VerticalSpan:new{ width = math.floor(item_px * 0.6) })
    y = y + 1 + math.floor(item_px * 0.6)

    -- bottom row: [◀ 1/2 ▶] on the left, [메모 화면] [닫기] on the right
    local brow_l = HorizontalGroup:new{ align = "center" }
    local brow_r = HorizontalGroup:new{ align = "center" }
    local btns = {}
    if npages > 1 then
        local prev, pw_ = button("◀", bpx)
        local nxt, nw_ = button("▶", bpx)
        local pg = text(string.format("%d / %d", self.page, npages), small_px * 1.1, { color = GRAY })
        local sp = math.floor(item_px * 0.4)
        table.insert(brow_l, prev); table.insert(brow_l, HorizontalSpan:new{ width = sp })
        table.insert(brow_l, pg); table.insert(brow_l, HorizontalSpan:new{ width = sp })
        table.insert(brow_l, nxt)
        table.insert(btns, { kind = "prev", x = 0, w = pw_ })
        table.insert(btns, { kind = "next", x = pw_ + 2 * sp + pg:getSize().w, w = nw_ })
    end
    local cb, cw_ = button("닫기", bpx)
    local rg = math.floor(item_px * 0.5)
    if self.memo_button and #self.ids > 0 then
        local mb, mw = button("메모 화면", bpx)
        table.insert(brow_r, mb); table.insert(brow_r, HorizontalSpan:new{ width = rg })
        table.insert(btns, { kind = "memo", x = iw - cw_ - rg - mw, w = mw })
    end
    table.insert(brow_r, cb)
    table.insert(btns, { kind = "close", x = iw - cw_, w = cw_ })
    if asleep then
        btns = {}
    else
        table.insert(content, OverlapGroup:new{
            dimen = Geom:new{ w = iw, h = btn_h },
            LeftContainer:new{ dimen = Geom:new{ w = iw, h = btn_h }, brow_l },
            RightContainer:new{ dimen = Geom:new{ w = iw, h = btn_h }, brow_r },
        })
    end
    local btn_y = y

    local bw = math.max(3, bth + 1)
    self.frame = FrameContainer:new{
        bordersize = bw, radius = 0, margin = 0, padding = pad,
        color = BLACK, background = WHITE,
        content,
    }
    -- Use the frame's real size (content + padding + border) for the refresh
    -- area: a region that leaves out the border is drawn into memory but not
    -- refreshed on the e-ink panel until some later full-screen update.
    local fs = self.frame:getSize()
    local fx, fy = math.floor((W - fs.w) / 2), math.floor((H - fs.h) / 2)
    self.frame_rect = { x = fx, y = fy, w = fs.w, h = fs.h }
    local slack = math.floor(item_px * 0.3)
    for _, r in ipairs(row_rects) do
        table.insert(self.rects, { kind = "item", id = r.id, x = fx, y = fy + bw + r.y, w = fs.w, h = r.h })
    end
    for _, bt in ipairs(btns) do
        table.insert(self.rects, { kind = bt.kind, x = fx + bw + pad + bt.x - slack, y = fy + bw + btn_y - slack,
            w = bt.w + 2 * slack, h = btn_h + 2 * slack })
    end
    self[1] = OverlapGroup:new{
        dimen = Geom:new{ w = W, h = H },
        CenterContainer:new{ dimen = Geom:new{ w = W, h = H }, self.frame },
    }
end

--- Screen area to refresh: the whole frame plus a small margin.
function ListPopup:refreshArea()
    local r, e = self.frame_rect, 4
    return Geom:new{ x = math.max(0, r.x - e), y = math.max(0, r.y - e), w = r.w + 2 * e, h = r.h + 2 * e }
end

function ListPopup:repaint()
    -- the frame can shrink (e.g. a two-line item on the last page): refresh
    -- the old area too so no stale border is left behind
    local old = self.frame_rect and self:refreshArea()
    self:build()
    local area = self:refreshArea()
    if old and (old.w ~= area.w or old.h ~= area.h) and self.parent then
        -- what the old frame covered must be redrawn from the screen below;
        -- a dirty parent also repaints this popup on top of it
        area = area:combine(old)
        UIManager:setDirty(self.parent, function() return "ui", area end)
    else
        UIManager:setDirty(self, function() return "ui", area end)
    end
end

function ListPopup:onShow()
    local area = self:refreshArea()
    UIManager:setDirty(self, function() return "ui", area end)
    return true
end

function ListPopup:onClose()
    UIManager:close(self)
    if self.parent then
        self.parent.todo_popup = nil
        self.parent:refresh(false)
    end
    return true
end

function ListPopup:onTapPopup(_, ges)
    local pos = ges and ges.pos
    if not inRect(pos, self.frame_rect) then return self:onClose() end
    for _, r in ipairs(self.rects) do
        if inRect(pos, r) then
            if r.kind == "item" then
                Memo:toggleDone(r.id)
                self:repaint()
            elseif r.kind == "prev" then
                self.page = self.page - 1; self:repaint()
            elseif r.kind == "next" then
                self.page = self.page + 1; self:repaint()
            elseif r.kind == "memo" then
                local parent = self.parent
                self:onClose()
                if parent then parent:openMemoScreen() end
            elseif r.kind == "close" then
                self:onClose()
            end
            return true
        end
    end
    return true
end

function ListPopup:onHoldPopup() return true end
function ListPopup:onSwipePopup(_, ges)
    if ges and (ges.direction == "west" or ges.direction == "east") then
        local n = self.page + (ges.direction == "west" and 1 or -1)
        if n >= 1 then self.page = n; self:repaint() end
    end
    return true
end

--- Take the current open to-dos again (done ones drop out) and redraw in
-- memory. The caller repaints the screen (the popup sits on top of it).
function ListPopup:refreshForNow()
    self.ids = nil
    self.page = 1
    self:snapshot()
    self:build()
end

function ListPopup:snapshot()
    self.ids = {}
    for _, m in ipairs(Memo:memos()) do
        if not m.done then self.ids[#self.ids + 1] = m.id end
    end
end

---------------------------------------------------------------- to-do popup

local TodoPopup = ListPopup:extend{ name = "DeskClockTodos" }

function TodoPopup:title() return string.format("할 일 %d", self:openCount()) end
function TodoPopup:hint() return "항목을 누르면 완료 / 되돌리기" end
function TodoPopup:rows()
    local rows = {}
    for _, m in ipairs(self:todos()) do rows[#rows + 1] = { kind = "todo", memo = m } end
    if #rows == 0 then rows[1] = { kind = "note", text = "할 일이 없습니다" } end
    return rows
end

---------------------------------------------------------------- day popup

--- @field day  local-epoch day start  @field with_todos  true for today
-- Events and the title come from the screen (parent:dayEvents / dayLabel),
-- so the popup can be rebuilt with fresh data (e.g. after a timed wake-up).
local DayPopup = ListPopup:extend{ name = "DeskClockDay", day = nil, with_todos = false }

function DayPopup:init()
    if not self.with_todos then self.ids = {} end
    ListPopup.init(self)
end

function DayPopup:snapshot()
    if self.with_todos then ListPopup.snapshot(self) else self.ids = {} end
end

--- Today's popup follows "today": after midnight it shows the new day.
function DayPopup:refreshForNow()
    if self.with_todos and self.parent then
        self.day = ICS.dayStart(self.parent.store:now())
    end
    ListPopup.refreshForNow(self)
end

function DayPopup:title() return self.parent and self.parent:dayLabel(self.day) or "" end
function DayPopup:hint()
    return #self.ids > 0 and "할 일을 누르면 완료" or nil
end
function DayPopup:rows()
    local rows = {}
    for _, e in ipairs(self.parent and self.parent:dayEvents(self.day) or {}) do
        rows[#rows + 1] = { kind = "event", time = e.time, title = e.title, past = e.past }
    end
    if #rows == 0 then rows[1] = { kind = "note", text = "일정 없음" } end
    if #self.ids > 0 then
        rows[#rows + 1] = { kind = "head", text = string.format("할 일 %d", self:openCount()) }
        for _, m in ipairs(self:todos()) do rows[#rows + 1] = { kind = "todo", memo = m } end
    end
    return rows
end

---------------------------------------------------------------- alarm popup

--- @field items  alarm items from dc_alarm (events and timed to-dos), rung together
-- @field lead   minutes before the start
-- Stays on the screen (also asleep) until closed; to-dos in it can be ticked.
local AlarmPopup = ListPopup:extend{ name = "DeskClockAlarm", items = nil, lead = nil, memo_button = false }

function AlarmPopup:snapshot()
    self.ids = {}
    for _, it in ipairs(self.items or {}) do
        if it.kind == "todo" then self.ids[#self.ids + 1] = it.memo_id end
    end
end

-- keeps its own items when the device goes to sleep or wakes for a sync
function AlarmPopup:refreshForNow() self:build() end

function AlarmPopup:title()
    return self.lead and string.format("곧 시작합니다 · %d분 전 알림", self.lead) or "곧 시작합니다"
end
function AlarmPopup:hint()
    return #self.ids > 0 and "할 일을 누르면 완료" or nil
end

local function hm(t) return os.date("!%H:%M", t) end

function AlarmPopup:rows()
    local now = self.parent and self.parent.store:now() or 0
    local by_id = {}
    for _, m in ipairs(self:todos()) do by_id[m.id] = m end
    local rows = {}
    for _, it in ipairs(self.items or {}) do
        if it.kind == "event" then
            local t = hm(it.start)
            if it.stop and it.stop > it.start then t = t .. "–" .. hm(it.stop) end
            rows[#rows + 1] = { kind = "event", time = t, title = it.title,
                past = (it.stop and it.stop > it.start and it.stop or it.start + 60) <= now }
        elseif by_id[it.memo_id] then
            rows[#rows + 1] = { kind = "todo", memo = by_id[it.memo_id] }
        end
    end
    if #rows == 0 then rows[1] = { kind = "note", text = "알림 항목이 없습니다" } end
    return rows
end

TodoPopup.DayPopup = DayPopup
TodoPopup.AlarmPopup = AlarmPopup
TodoPopup.ListPopup = ListPopup
return TodoPopup
