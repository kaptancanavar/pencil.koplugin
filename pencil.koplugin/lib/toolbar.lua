--[[--
Floating pen toolbar for the Pencil plugin (Kindle Scribe style).

Layout, top to bottom:
  - the round "handle": tap = collapse/expand, drag = move the toolbar
  - the bar with the tool buttons (Toolbar.LAYOUT)
  - optionally a "flyout" panel next to the bar (widths, pen types, more…)

Painted by the plugin's view module (Pencil:paintTo) on top of the page,
so it needs no widget of its own on the UIManager stack and never blocks
input to the reader. Hit-testing is done by the plugin for both pen
(stylus callback) and finger (touch zones). Flyout contents come from the
plugin via a provider function, so this module only knows about layout.

@module pencil.lib.toolbar
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local ImageWidget = require("ui/widget/imagewidget")
local TextWidget = require("ui/widget/textwidget")

local Toolbar = {}
Toolbar.__index = Toolbar

-- Buttons of the bar, top to bottom. "sep" draws a divider.
Toolbar.LAYOUT = {
    "pen",
    "highlighter",
    "eraser",
    "lasso",
    "pointer",
    "sep",
    "note",
    "undo",
    "redo",
    "more",
}

-- Buttons that represent a selectable mode (drawn inverted when active).
local MODE_BUTTONS = {
    pen = true,
    highlighter = true,
    eraser = true,
    lasso = true,
    pointer = true,
    note = true,
}

--- Create a toolbar.
-- @param screen KOReader Screen (Device.screen)
-- @param icon_dir Absolute path to the plugin's icons folder
function Toolbar.new(screen, icon_dir)
    local self = setmetatable({}, Toolbar)
    self.screen = screen
    self.icon_dir = icon_dir
    self.expanded = true
    self.active = "pen"     -- one of MODE_BUTTONS
    self.fx, self.fy = nil, nil  -- handle position as screen fractions (nil = default)
    self.flyout = nil       -- { kind = "pen"|"highlighter"|"eraser"|"more", anchor = button id }
    self.flyout_provider = nil   -- function(kind) -> rows (see paintFlyout)
    self.transparent_handle = true  -- collapsed: only ring + icon, text shows through
    self.layout = Toolbar.LAYOUT -- buttons actually shown (plugin may trim it)
    self.icons = {}
    self.texts = {}
    self:computeMetrics()
    return self
end

-- Size of handle and bar relative to the original design (flyout menus keep
-- their size so the text stays readable).
Toolbar.SCALE = 2 / 3

function Toolbar:computeMetrics()
    local s = self.screen
    local k = Toolbar.SCALE
    self.cell = s:scaleBySize(46 * k)        -- square cell edge
    self.icon_size = s:scaleBySize(28 * k)   -- icon edge inside a cell
    self.border = math.max(1, s:scaleBySize(1.5))
    self.radius = s:scaleBySize(10 * k)
    self.sep_h = s:scaleBySize(9 * k)        -- height of the divider row
    self.margin = s:scaleBySize(6)           -- default distance from the screen edge
    self.gap = s:scaleBySize(6 * k)          -- between handle and bar
    self.fly_w = s:scaleBySize(220)      -- flyout width
    self.fly_row = s:scaleBySize(44)     -- flyout row height
    self.fly_pad = s:scaleBySize(12)
    self.font_size = 18
end

function Toolbar:getIcon(name)
    local w = self.icons[name]
    if not w then
        w = ImageWidget:new{
            file = self.icon_dir .. "/" .. name .. ".svg",
            width = self.icon_size,
            height = self.icon_size,
            alpha = true,
        }
        self.icons[name] = w
    end
    return w
end

function Toolbar:getText(text)
    local w = self.texts[text]
    if not w then
        w = TextWidget:new{
            text = text,
            face = Font:getFace("cfont", self.font_size),
        }
        self.texts[text] = w
    end
    return w
end

--- Drop cached renders (call after rotation / screen size change).
function Toolbar:reset()
    for _, w in pairs(self.icons) do
        if w.free then w:free() end
    end
    for _, w in pairs(self.texts) do
        if w.free then w:free() end
    end
    self.icons, self.texts = {}, {}
    self:computeMetrics()
end

-- ---------------------------------------------------------------------------
-- Position
-- ---------------------------------------------------------------------------

-- Height of handle + (expanded) bar
function Toolbar:getStackHeight()
    local h = self.cell
    if self.expanded then
        h = h + self.gap
        for _, id in ipairs(self.layout) do
            h = h + (id == "sep" and self.sep_h or self.cell)
        end
    end
    return h
end

-- Clamp a handle position so handle + bar stay fully on screen.
function Toolbar:clamp(x, y)
    local W, H = self.screen:getWidth(), self.screen:getHeight()
    local pad = self.border + 2
    x = math.max(pad, math.min(x, W - self.cell - pad))
    y = math.max(pad, math.min(y, H - self:getStackHeight() - pad))
    return math.floor(x), math.floor(y)
end

-- Top-left corner of the handle. Stored as screen fractions, so the
-- toolbar stays in a sensible place after rotation.
function Toolbar:origin()
    local W, H = self.screen:getWidth(), self.screen:getHeight()
    local x, y
    if self.fx and self.fy then
        x, y = self.fx * W, self.fy * H
    else
        x, y = self.margin, H * 0.12
    end
    return self:clamp(x, y)
end

--- Move the handle's top-left corner to (x, y) (screen pixels).
function Toolbar:moveTo(x, y)
    x, y = self:clamp(x, y)
    self.fx = x / self.screen:getWidth()
    self.fy = y / self.screen:getHeight()
end

function Toolbar:resetPosition()
    self.fx, self.fy = nil, nil
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

--- Hit rects of handle and bar for the current state.
-- @return table of { id = string, x, y, w, h }
function Toolbar:getCells()
    local x, y = self:origin()
    local cells = {
        { id = "handle", x = x, y = y, w = self.cell, h = self.cell },
    }
    if not self.expanded then
        return cells
    end
    local cy = y + self.cell + self.gap
    for _, id in ipairs(self.layout) do
        local h = (id == "sep") and self.sep_h or self.cell
        table.insert(cells, { id = id, x = x, y = cy, w = self.cell, h = h })
        cy = cy + h
    end
    return cells
end

-- Rect of the bar only (without handle), or nil when collapsed
function Toolbar:getBarRect()
    local cells = self:getCells()
    if #cells < 2 then return nil end
    local first, last = cells[2], cells[#cells]
    return { x = first.x, y = first.y, w = first.w, h = (last.y + last.h) - first.y }
end

local function findCell(cells, id)
    for _, c in ipairs(cells) do
        if c.id == id then return c end
    end
end

--- Flyout geometry and rows, or nil if none is open.
-- Rows: { id, text, selected, kind = "item"|"sep"|"strip", sample = {...} }
-- A "strip" row holds several horizontal choices: row.items = { {id, sample, selected}, ... }
function Toolbar:getFlyout()
    if not self.flyout or not self.expanded or not self.flyout_provider then
        return nil
    end
    -- Rows are built once per opened flyout (hit tests, refresh regions and
    -- painting all ask for them); any change replaces self.flyout, which
    -- drops the cache.
    local rows = self.flyout.rows
    if not rows then
        rows = self.flyout_provider(self.flyout.kind) or {}
        self.flyout.rows = rows
    end
    if #rows == 0 then return nil end
    local cells = self:getCells()
    local anchor = findCell(cells, self.flyout.anchor) or cells[2]
    local h = 0
    for _, r in ipairs(rows) do
        h = h + (r.kind == "sep" and self.sep_h or self.fly_row)
    end
    local W, H = self.screen:getWidth(), self.screen:getHeight()
    -- Open towards the side with more room
    local x
    if anchor.x + self.cell / 2 < W / 2 then
        x = anchor.x + self.cell + self.gap
    else
        x = anchor.x - self.gap - self.fly_w
    end
    x = math.max(0, math.min(x, W - self.fly_w))
    local y = math.max(0, math.min(anchor.y, H - h))
    local laid = {}
    local cy = y
    for _, r in ipairs(rows) do
        local rh = (r.kind == "sep") and self.sep_h or self.fly_row
        table.insert(laid, { row = r, x = x, y = cy, w = self.fly_w, h = rh })
        cy = cy + rh
    end
    return { x = x, y = y, w = self.fly_w, h = h, rows = laid }
end

--- Bounding rect of everything currently drawn (for refresh regions).
function Toolbar:getRect()
    local cells = self:getCells()
    local x0, y0 = cells[1].x, cells[1].y
    local last = cells[#cells]
    local x1, y1 = x0 + self.cell, last.y + last.h
    local fly = self:getFlyout()
    if fly then
        x0, y0 = math.min(x0, fly.x), math.min(y0, fly.y)
        x1, y1 = math.max(x1, fly.x + fly.w), math.max(y1, fly.y + fly.h)
    end
    local pad = self.border + 2
    x0, y0 = math.max(0, x0 - pad), math.max(0, y0 - pad)
    return { x = x0, y = y0, w = (x1 + pad) - x0, h = (y1 + pad) - y0 }
end

--- What is at (x, y)?
-- @return "handle", a button id, "sep", "fly:<row id>" for a flyout row,
--         "fly:" for a non-clickable part of the flyout, or nil when outside.
function Toolbar:hitTest(x, y)
    if not x or not y then return nil end
    local fly = self:getFlyout()
    if fly and x >= fly.x and x < fly.x + fly.w and y >= fly.y and y < fly.y + fly.h then
        for _, lr in ipairs(fly.rows) do
            if y >= lr.y and y < lr.y + lr.h then
                local r = lr.row
                if r.kind == "strip" then
                    local n = #r.items
                    local iw = lr.w / n
                    local i = math.min(n, math.max(1, math.floor((x - lr.x) / iw) + 1))
                    return "fly:" .. r.items[i].id
                elseif r.kind ~= "sep" and r.id then
                    return "fly:" .. r.id
                end
            end
        end
        return "fly:"
    end
    -- A little slack around the bar makes it easier to hit with a finger.
    local slack = self.screen:scaleBySize(4)
    for _, c in ipairs(self:getCells()) do
        if x >= c.x - slack and x < c.x + c.w + slack
                and y >= c.y and y < c.y + c.h then
            return c.id
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Painting
-- ---------------------------------------------------------------------------

function Toolbar:paintIcon(bb, name, cx, cy, inverted)
    local icon = self:getIcon(name)
    local ix = cx + math.floor((self.cell - self.icon_size) / 2)
    local iy = cy + math.floor((self.cell - self.icon_size) / 2)
    icon:paintTo(bb, ix, iy)
    if inverted then
        local inset = self.border + 1
        bb:invertRect(cx + inset, cy + inset, self.cell - 2 * inset, self.cell - 2 * inset)
    end
end

-- Width sample for a flyout row: "line" (pen), "bar" (gray marker), "ring" (eraser)
function Toolbar:paintSample(bb, sample, x, y, w, h)
    local sw = math.max(1, math.min(sample.width or 2, h - 4))
    local cy = y + math.floor((h - sw) / 2)
    if sample.type == "bar" then
        bb:paintRoundedRect(x, cy, w, sw, Blitbuffer.Color8(0xDD), math.floor(sw / 2))
    elseif sample.type == "ring" then
        bb:paintBorder(x, cy, w, sw, math.max(1, self.border), Blitbuffer.COLOR_BLACK, math.floor(sw / 2))
    else
        bb:paintRoundedRect(x, cy, w, sw, Blitbuffer.COLOR_BLACK, math.floor(sw / 2))
    end
end

function Toolbar:paintFlyout(bb, fly)
    bb:paintRect(fly.x, fly.y, fly.w, fly.h, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(fly.x, fly.y, fly.w, fly.h, self.border, Blitbuffer.COLOR_BLACK)
    local pad = self.fly_pad
    for _, lr in ipairs(fly.rows) do
        local r = lr.row
        if r.kind == "sep" then
            bb:paintRect(lr.x + pad, lr.y + math.floor(lr.h / 2), lr.w - 2 * pad, self.border, Blitbuffer.COLOR_DARK_GRAY)
        elseif r.kind == "strip" then
            local n = #r.items
            local iw = math.floor(lr.w / n)
            for i, it in ipairs(r.items) do
                local ix = lr.x + (i - 1) * iw
                local inner = math.floor(iw * 0.6)
                self:paintSample(bb, it.sample, ix + math.floor((iw - inner) / 2), lr.y, inner, lr.h)
                if it.selected then
                    bb:invertRect(ix + 1, lr.y + 1, iw - 2, lr.h - 2)
                end
            end
        else
            local tw = self:getText(r.text or "")
            local ts = tw:getSize()
            tw:paintTo(bb, lr.x + pad, lr.y + math.floor((lr.h - ts.h) / 2))
            if r.sample then
                local sw = math.floor(lr.w * 0.38)
                self:paintSample(bb, r.sample, lr.x + lr.w - pad - sw, lr.y, sw, lr.h)
            end
            if r.selected then
                bb:invertRect(lr.x + 1, lr.y + 1, lr.w - 2, lr.h - 2)
            end
        end
    end
end

--- Paint handle, bar and flyout into a blitbuffer (logical coordinates).
function Toolbar:paintTo(bb)
    local cells = self:getCells()
    local handle = cells[1]

    -- Handle: round button. Expanded: chevron to collapse. Collapsed: the
    -- active tool, so you can see what the pen does.
    local r = math.floor(self.cell / 2)
    local hx, hy = handle.x + r, handle.y + r
    -- Collapsed + transparent: no white fill, so the page text under the
    -- handle stays visible. Expanded the handle sits on the bar: always opaque.
    if self.expanded or not self.transparent_handle then
        bb:paintCircle(hx, hy, r, Blitbuffer.COLOR_WHITE)
    end
    bb:paintCircle(hx, hy, r, Blitbuffer.COLOR_BLACK, self.border)
    self:paintIcon(bb, self.expanded and "collapse" or self.active, handle.x, handle.y, false)
    if not self.expanded then
        return
    end

    local bar = self:getBarRect()
    bb:paintRoundedRect(bar.x, bar.y, bar.w, bar.h, Blitbuffer.COLOR_WHITE, self.radius)
    bb:paintBorder(bar.x, bar.y, bar.w, bar.h, self.border, Blitbuffer.COLOR_BLACK, self.radius)
    for i = 2, #cells do
        local c = cells[i]
        if c.id == "sep" then
            local pad = self.screen:scaleBySize(8)
            bb:paintRect(c.x + pad, c.y + math.floor(c.h / 2), c.w - 2 * pad, self.border, Blitbuffer.COLOR_DARK_GRAY)
        else
            local inverted = (MODE_BUTTONS[c.id] and c.id == self.active)
                or (self.flyout and self.flyout.anchor == c.id and c.id == "more")
            self:paintIcon(bb, c.id, c.x, c.y, inverted)
        end
    end

    local fly = self:getFlyout()
    if fly then
        self:paintFlyout(bb, fly)
    end
end

return Toolbar
