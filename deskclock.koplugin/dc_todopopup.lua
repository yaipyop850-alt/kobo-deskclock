--[[--
To-do popup: opened from the "할 일 N" badge on the clock/calendar/month screens.
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
local UI = require("dc_ui")
local Screen = Device.screen
local text, wrapText, inRect = UI.text, UI.wrapText, UI.inRect
local BLACK, WHITE, GRAY, LIGHT = UI.BLACK, UI.WHITE, UI.GRAY, UI.LIGHT


--- A small window over any screen listing the open to-dos; tapping an item
-- ticks it (and back). Items ticked while it is open stay listed (struck
-- through) so a mistaken tap can be undone; they go away on the next opening.
local TodoPopup = InputContainer:extend{
    name = "DeskClockTodos",
    parent = nil,     -- DeskWidget
    ids = nil,        -- memo ids shown (snapshot when opened)
    page = 1,
}

function TodoPopup:init()
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
    if not self.ids then
        self.ids = {}
        for _, m in ipairs(Memo:memos()) do
            if not m.done then self.ids[#self.ids + 1] = m.id end
        end
    end
    self:build()
end

function TodoPopup:items()
    local by_id = {}
    for _, m in ipairs(Memo:memos()) do by_id[m.id] = m end
    local list = {}
    for _, id in ipairs(self.ids) do
        if by_id[id] then list[#list + 1] = by_id[id] end
    end
    return list
end

function TodoPopup:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local m = math.min(W, H)
    local pw = math.floor(W > H and W * 0.62 or W * 0.88)
    local pad = math.floor(m * 0.035)
    local iw = pw - 2 * pad
    local item_px = m * 0.034
    local small_px = m * 0.024
    local bth = math.max(2, math.floor(m / 400))
    self.rects = {}

    local items = self:items()
    local open_n = 0
    for _, it in ipairs(items) do if not it.done then open_n = open_n + 1 end end

    -- header
    local head_h = text("가", item_px * 1.1, { bold = true }):getSize().h
    local header = OverlapGroup:new{
        dimen = Geom:new{ w = iw, h = head_h },
        LeftContainer:new{ dimen = Geom:new{ w = iw, h = head_h },
            text(string.format("할 일 %d", open_n), item_px * 1.1, { bold = true }) },
        RightContainer:new{ dimen = Geom:new{ w = iw, h = head_h },
            text("항목을 누르면 완료 / 되돌리기", small_px, { color = GRAY }) },
    }

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

    -- rows, paged to fit
    local box = math.floor(item_px * 0.9)
    local bgap = math.floor(item_px * 0.5)
    local tw = iw - box - bgap
    local row_pad = math.floor(item_px * 0.45)
    local max_list = math.floor(H * 0.78) - 2 * pad - head_h - btn_h - math.floor(item_px * 1.6)
    local built, pages, cur, used = {}, {}, {}, 0
    for i, it in ipairs(items) do
        local body = wrapText((it.text:gsub("%s*\n+%s*", " · ")), item_px, tw, 2,
            it.done and { color = GRAY, strike = true } or nil)
        local bh = body:getSize().h
        local h = bh + 2 * row_pad + 1
        built[i] = { body = body, h = h, bh = bh }
        if used + h > max_list and #cur > 0 then
            table.insert(pages, cur); cur, used = {}, 0
        end
        table.insert(cur, i); used = used + h
    end
    if #cur > 0 then table.insert(pages, cur) end
    local npages = math.max(1, #pages)
    self.page = math.min(math.max(1, self.page), npages)

    local content = VerticalGroup:new{ align = "left", header,
        VerticalSpan:new{ width = math.floor(item_px * 0.5) } }
    local y = pad + head_h + math.floor(item_px * 0.5) -- relative to the frame's top-left
    local row_rects = {}
    if #items == 0 then
        table.insert(content, text("할 일이 없습니다", item_px, { color = GRAY }))
        y = y + text("가", item_px):getSize().h
    end
    for _, i in ipairs(pages[self.page] or {}) do
        local it, b = items[i], built[i]
        local th = math.floor(item_px * 1.362 + 0.5)
        local mark = it.done and text("✓", item_px * 0.8, { bold = true, color = GRAY }) or VerticalSpan:new{ width = 0 }
        local checkbox = FrameContainer:new{
            bordersize = bth, radius = 0, margin = 0, padding = 0,
            color = it.done and GRAY or BLACK, background = WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = box - 2 * bth, h = box - 2 * bth }, mark },
        }
        table.insert(content, LineWidget:new{ background = LIGHT, dimen = Geom:new{ w = iw, h = 1 } })
        table.insert(content, VerticalSpan:new{ width = row_pad })
        table.insert(content, HorizontalGroup:new{ align = "top",
            VerticalGroup:new{ align = "left", VerticalSpan:new{ width = math.max(0, math.floor((th - box) / 2)) }, checkbox },
            HorizontalSpan:new{ width = bgap },
            b.body,
        })
        table.insert(content, VerticalSpan:new{ width = row_pad })
        table.insert(row_rects, { y = y, h = b.h, id = it.id })
        y = y + b.h
    end
    table.insert(content, LineWidget:new{ background = LIGHT, dimen = Geom:new{ w = iw, h = 1 } })
    table.insert(content, VerticalSpan:new{ width = math.floor(item_px * 0.6) })
    y = y + 1 + math.floor(item_px * 0.6)

    -- bottom row: [◀ 1/2 ▶] on the left, [메모 화면] [닫기] on the right
    local brow_l = HorizontalGroup:new{ align = "center" }
    local brow_r = HorizontalGroup:new{ align = "center" }
    local btns = {}
    if npages > 1 then
        local prev, pw_, _ = button("◀", bpx)
        local nxt, nw_ = button("▶", bpx)
        local pg = text(string.format("%d / %d", self.page, npages), small_px * 1.1, { color = GRAY })
        local sp = math.floor(item_px * 0.4)
        table.insert(brow_l, prev); table.insert(brow_l, HorizontalSpan:new{ width = sp })
        table.insert(brow_l, pg); table.insert(brow_l, HorizontalSpan:new{ width = sp })
        table.insert(brow_l, nxt)
        table.insert(btns, { kind = "prev", x = 0, w = pw_ })
        table.insert(btns, { kind = "next", x = pw_ + 2 * sp + pg:getSize().w, w = nw_ })
    end
    local mb, mw = button("메모 화면", bpx)
    local cb, cw_ = button("닫기", bpx)
    local rg = math.floor(item_px * 0.5)
    table.insert(brow_r, mb); table.insert(brow_r, HorizontalSpan:new{ width = rg }); table.insert(brow_r, cb)
    table.insert(btns, { kind = "memo", x = iw - cw_ - rg - mw, w = mw })
    table.insert(btns, { kind = "close", x = iw - cw_, w = cw_ })
    table.insert(content, OverlapGroup:new{
        dimen = Geom:new{ w = iw, h = btn_h },
        LeftContainer:new{ dimen = Geom:new{ w = iw, h = btn_h }, brow_l },
        RightContainer:new{ dimen = Geom:new{ w = iw, h = btn_h }, brow_r },
    })
    local btn_y = y
    y = y + btn_h + pad

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
function TodoPopup:refreshArea()
    local r, e = self.frame_rect, 4
    return Geom:new{ x = math.max(0, r.x - e), y = math.max(0, r.y - e), w = r.w + 2 * e, h = r.h + 2 * e }
end

function TodoPopup:repaint()
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

function TodoPopup:onShow()
    local area = self:refreshArea()
    UIManager:setDirty(self, function() return "ui", area end)
    return true
end

function TodoPopup:onClose()
    UIManager:close(self)
    if self.parent then
        self.parent.todo_popup = nil
        self.parent:refresh(false)
    end
    return true
end

function TodoPopup:onTapPopup(_, ges)
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

function TodoPopup:onHoldPopup() return true end
function TodoPopup:onSwipePopup(_, ges)
    if ges and (ges.direction == "west" or ges.direction == "east") then
        local n = self.page + (ges.direction == "west" and 1 or -1)
        if n >= 1 then self.page = n; self:repaint() end
    end
    return true
end

return TodoPopup
