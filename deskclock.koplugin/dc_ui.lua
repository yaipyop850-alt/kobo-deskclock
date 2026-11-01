--[[--
Shared drawing helpers for the desk clock screens and popups.
Pixel sizes are real screen pixels (fonts are converted back from KOReader's
DPI scaling); colours are the four greys the e-ink panel shows well.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_DARK_GRAY
local LIGHT = Blitbuffer.COLOR_LIGHT_GRAY

-- Font:getFace() scales sizes by DPI; convert a wanted pixel size back.
local function fsize(px)
    local scale = Screen:scaleBySize(1000) / 1000
    return math.max(8, math.floor(px / scale + 0.5))
end

local function text(str, px, opts)
    opts = opts or {}
    return TextWidget:new{
        text = str,
        face = Font:getFace("cfont", fsize(px)),
        bold = opts.bold,
        fgcolor = opts.color or BLACK,
        max_width = opts.max_width,
        padding = 0,
    }
end

--- Split `str` into at most `maxlines` lines that fit `maxw` pixels.
-- Breaks at a space when one is reasonably close, otherwise between characters
-- (fine for Korean). The last line is ellipsized by TextWidget if still too long.
local function wrapText(str, px, maxw, maxlines, opts)
    local function width(s) return text(s, px, opts):getSize().w end
    local lines = {}
    local rest = str
    while rest ~= "" and #lines < maxlines do
        if #lines == maxlines - 1 or width(rest) <= maxw then
            table.insert(lines, rest)
            break
        end
        local chars = {}
        for ch in rest:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
        -- largest n with chars[1..n] fitting
        local lo, hi = 1, #chars
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            if width(table.concat(chars, "", 1, mid)) <= maxw then lo = mid else hi = mid - 1 end
        end
        local n = lo
        -- prefer breaking after a space (or '/', ',') in the last 40% of the line
        for i = n, math.max(1, math.floor(n * 0.6)), -1 do
            local c = chars[i]
            if c == " " or c == "/" or c == "," or c == "_" then n = i break end
        end
        local line = table.concat(chars, "", 1, n):gsub("%s+$", "")
        table.insert(lines, line)
        rest = table.concat(chars, "", n + 1):gsub("^%s+", "")
    end
    local group = VerticalGroup:new{ align = "left" }
    for _, l in ipairs(lines) do
        local tw = text(l, px, { color = opts and opts.color, bold = opts and opts.bold, max_width = maxw })
        if opts and opts.strike then
            -- strikethrough: a line across the middle of the text (TextWidget has no such option)
            local ts = tw:getSize()
            local th = math.max(2, math.floor(px / 14))
            tw = OverlapGroup:new{
                dimen = Geom:new{ w = ts.w, h = ts.h },
                tw,
                VerticalGroup:new{ align = "left",
                    VerticalSpan:new{ width = math.floor(ts.h * 0.52) },
                    LineWidget:new{ background = opts.color or BLACK, dimen = Geom:new{ w = ts.w, h = th } } },
            }
        end
        table.insert(group, tw)
    end
    return group
end


local function inRect(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

--- An empty or ticked square check box, `size` pixels wide.
local function checkbox(size, done, px)
    local bth = math.max(2, math.floor(size / 16))
    local mark = done and text("✓", px or size * 0.9, { bold = true, color = GRAY }) or VerticalSpan:new{ width = 0 }
    return FrameContainer:new{
        bordersize = bth, radius = 0, margin = 0, padding = 0,
        color = done and GRAY or BLACK, background = WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = size - 2 * bth, h = size - 2 * bth }, mark },
    }
end

--- One-line to-do rows (open items) for compact lists: "☐ text".
-- Rows are added while they fit in `budget` px; if some do not fit, the last
-- line says how many more there are. @return group, used height, rows {y, h, memo}
local function todoRows(memos, px, width, budget, no_more_line)
    local col = VerticalGroup:new{ align = "left" }
    local used, rows = 0, {}
    local row_h = text("가", px):getSize().h
    local gap = math.floor(px * 0.28)
    local box = math.floor(px * 0.8)
    local bgap = math.floor(px * 0.45)
    for i, m in ipairs(memos) do
        local tail = (i < #memos and not no_more_line) and row_h or 0
        if used + row_h + gap + tail > budget then
            if not no_more_line and used + row_h <= budget then
                table.insert(col, text(string.format("…외 %d개", #memos - i + 1), px * 0.85, { color = GRAY }))
                used = used + row_h
            end
            break
        end
        table.insert(col, HorizontalGroup:new{ align = "center",
            checkbox(box, false),
            HorizontalSpan:new{ width = bgap },
            text((m.text:gsub("%s*\n+%s*", " · ")), px, { max_width = width - box - bgap }),
        })
        table.insert(col, VerticalSpan:new{ width = gap })
        table.insert(rows, { y = used, h = row_h, memo = m })
        used = used + row_h + gap
    end
    return col, used, rows
end

return {
    BLACK = BLACK, WHITE = WHITE, GRAY = GRAY, LIGHT = LIGHT,
    fsize = fsize, text = text, wrapText = wrapText, inRect = inRect,
    checkbox = checkbox, todoRows = todoRows,
}
