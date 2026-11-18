--[[--
Lasso tool: select strokes with a loop, move or delete the selection.

@module pencil.lasso
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local PencilGeometry = require("lib/geometry")
local Screen = Device.screen
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local Common = require("pencil/common")
local rectsOverlap = Common.rectsOverlap
local strokeBBox = Common.strokeBBox
local snapshotFits = Common.snapshotFits
local unionRect = Common.unionRect

local Pencil = {}

-- ---------------------------------------------------------------------------
-- Lasso: draw a loop around strokes to select them (strokes with at least
-- half of their points inside). Drag inside the selection to move it; delete
-- it with the "Löschen" chip next to it or "Auswahl löschen" in the eraser
-- menu. Moves and deletes are undoable.
-- ---------------------------------------------------------------------------

local LASSO_DASH = 10
local LASSO_MIN_STEP = 3
local LASSO_REFRESH_MS = 30

function Pencil:hasLassoSelection()
    local sel = self.lasso_selection
    return sel ~= nil and sel.page == self:getCurrentPage() and #sel.strokes > 0
end

function Pencil:clearLassoSelection()
    local sel = self.lasso_selection
    if not sel then return end
    self.lasso_selection = nil
    local r = self:getLassoOverlayRect(sel)
    if r then
        UIManager:setDirty(self.ui.dialog or self.ui, function()
            return "ui", Geom:new(r)
        end)
    end
end

function Pencil:shiftStrokes(strokes, dx, dy)
    for _, stroke in ipairs(strokes) do
        stroke._bbox = nil
        for _, pt in ipairs(stroke.points or {}) do
            pt.x = pt.x + dx
            pt.y = pt.y + dy
        end
        if stroke.anchor and stroke.dpts then
            local z = stroke._pz or 1
            for _, d in ipairs(stroke.dpts) do
                d.x = d.x + dx / z
                d.y = d.y + dy / z
            end
        end
    end
end

-- Bounding box of a set of strokes, padded
function Pencil:strokesBBox(strokes, pad)
    local x0, y0, x1, y1
    for _, stroke in ipairs(strokes) do
        local sx, sy, sw, sh = strokeBBox(stroke)
        if sx then
            x0 = x0 and math.min(x0, sx) or sx
            y0 = y0 and math.min(y0, sy) or sy
            x1 = x1 and math.max(x1, sx + sw) or sx + sw
            y1 = y1 and math.max(y1, sy + sh) or sy + sh
        end
    end
    if not x0 then return nil end
    pad = pad or 0
    return { x = x0 - pad, y = y0 - pad, w = (x1 - x0) + 2 * pad, h = (y1 - y0) + 2 * pad }
end

-- "Löschen" chip above the selection's top-right corner (below if no room)
-- The chip's label is rendered once and kept (it was re-rendered for every
-- size query and every paint, i.e. many times per drag frame)
function Pencil:getChipText()
    if not self._chip_tw then
        self._chip_tw = TextWidget:new{
            text = "Löschen",
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_WHITE,
        }
    end
    return self._chip_tw
end

function Pencil:getLassoChipRect(sel)
    local box = sel.box
    if not box then return nil end
    local ts = self:getChipText():getSize()
    local pad = Screen:scaleBySize(8)
    local w, h = ts.w + 2 * pad, math.max(ts.h + pad, Screen:scaleBySize(32))
    local x = math.max(0, math.min(box.x + box.w - w, Screen:getWidth() - w))
    local y = box.y - h - Screen:scaleBySize(4)
    if y < 0 then y = math.min(box.y + box.h + Screen:scaleBySize(4), Screen:getHeight() - h) end
    return { x = x, y = y, w = w, h = h }
end

-- Everything the selection overlay paints (box + chip), for refreshes
function Pencil:getLassoOverlayRect(sel)
    if not sel or not sel.box then return nil end
    local pad = Screen:scaleBySize(4)
    local r = { x = sel.box.x - pad, y = sel.box.y - pad, w = sel.box.w + 2 * pad, h = sel.box.h + 2 * pad }
    local chip = self:getLassoChipRect(sel)
    if chip then r = unionRect(r, chip) end
    return r
end

local function inRect(x, y, r)
    return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

-- Dashed line; `start` is the running length so dashes continue across segments
function Pencil:drawDashedSegment(bb, x1, y1, x2, y2, start)
    local dx, dy = x2 - x1, y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    local steps = math.max(1, math.ceil(dist))
    local w = math.max(2, Screen:scaleBySize(1.5))
    for i = 0, steps do
        if ((start + dist * i / steps) % (2 * LASSO_DASH)) < LASSO_DASH then
            local x = math.floor(x1 + dx * i / steps)
            local y = math.floor(y1 + dy * i / steps)
            bb:paintRect(x, y, w, w, Blitbuffer.COLOR_BLACK)
        end
    end
    return start + dist
end

function Pencil:paintLassoOverlay(bb, page)
    -- Loop being drawn
    local path = self.lasso_path
    if path and #path > 1 then
        local len = 0
        for i = 2, #path do
            len = self:drawDashedSegment(bb, path[i - 1].x, path[i - 1].y, path[i].x, path[i].y, len)
        end
    end
    -- Selection: dashed box + "Löschen" chip
    local sel = self.lasso_selection
    if sel and sel.page == page and sel.box then
        local b, len = sel.box, 0
        len = self:drawDashedSegment(bb, b.x, b.y, b.x + b.w, b.y, len)
        len = self:drawDashedSegment(bb, b.x + b.w, b.y, b.x + b.w, b.y + b.h, len)
        len = self:drawDashedSegment(bb, b.x + b.w, b.y + b.h, b.x, b.y + b.h, len)
        self:drawDashedSegment(bb, b.x, b.y + b.h, b.x, b.y, len)
        local chip = self:getLassoChipRect(sel)
        if chip then
            bb:paintRoundedRect(chip.x, chip.y, chip.w, chip.h, Blitbuffer.COLOR_BLACK, Screen:scaleBySize(6))
            local tw = self:getChipText()
            local ts = tw:getSize()
            tw:paintTo(bb, chip.x + math.floor((chip.w - ts.w) / 2), chip.y + math.floor((chip.h - ts.h) / 2))
        end
    end
end

function Pencil:handleLassoSlot(slot)
    local contact = slot.id ~= nil and slot.id >= 0
    if contact then
        if slot.x == nil or slot.y == nil then return true end
        local x, y = self:transformCoordinates(slot.x, slot.y)
        if not self.lasso_active then
            -- Touch-down
            self.lasso_active = true
            local sel = self.lasso_selection
            if sel and sel.page == self:getCurrentPage() then
                if inRect(x, y, self:getLassoChipRect(sel)) then
                    self.lasso_active = "chip"
                    self:defer(function() self:deleteLassoSelection() end)
                    return true
                end
                if inRect(x, y, sel.box) then
                    self.lasso_move = { sx = x, sy = y, dx = 0, dy = 0 }
                    return true
                end
            end
            if sel then self:clearLassoSelection() end
            self.lasso_path = { { x = x, y = y } }
            self.lasso_len = 0
            self.lasso_refresh = nil
            return true
        end
        if self.lasso_move then
            self:updateLassoMove(x, y)
        elseif self.lasso_path then
            local path = self.lasso_path
            local last = path[#path]
            local dx, dy = x - last.x, y - last.y
            if dx * dx + dy * dy >= LASSO_MIN_STEP * LASSO_MIN_STEP then
                table.insert(path, { x = x, y = y })
                self.lasso_len = self:drawDashedSegment(Screen.bb, last.x, last.y, x, y, self.lasso_len)
                local pad = 4
                local r = {
                    x = math.min(last.x, x) - pad, y = math.min(last.y, y) - pad,
                    w = math.abs(x - last.x) + 2 * pad, h = math.abs(y - last.y) + 2 * pad,
                }
                self.lasso_refresh = unionRect(self.lasso_refresh, r)
                local now = time.now()
                if not self.lasso_refresh_time or time.to_ms(now - self.lasso_refresh_time) >= LASSO_REFRESH_MS then
                    local rr = self.lasso_refresh
                    self.lasso_refresh = nil
                    self.lasso_refresh_time = now
                    Screen:refreshFast(rr.x, rr.y, rr.w, rr.h)
                end
            end
        end
        return true
    end
    -- Lift
    if self.lasso_active then
        self.lasso_active = nil
        if self.lasso_move then
            local m = self.lasso_move
            self.lasso_move = nil
            self:defer(function() self:finishLassoMove(m) end)
        elseif self.lasso_path then
            local path = self.lasso_path
            self:defer(function() self:finishLassoPath(path) end)
        end
    end
    return true
end

function Pencil:finishLassoPath(path)
    self.lasso_path = nil
    local page = self:getCurrentPage()
    -- Area of the dashed loop, to clean up
    local x0, y0, x1, y1 = path[1].x, path[1].y, path[1].x, path[1].y
    for _, pt in ipairs(path) do
        x0, y0 = math.min(x0, pt.x), math.min(y0, pt.y)
        x1, y1 = math.max(x1, pt.x), math.max(y1, pt.y)
    end
    local pad = Screen:scaleBySize(4)
    local region = { x = x0 - pad, y = y0 - pad, w = (x1 - x0) + 2 * pad, h = (y1 - y0) + 2 * pad }

    local selected, set = {}, {}
    if #path >= 3 then
        for _, idx in ipairs(self:pageIndices(page)) do
            local stroke = self.strokes[idx]
            local pts = stroke and stroke.points
            -- Skip strokes whose box lies outside the loop's box
            local sx, sy, sw, sh = nil, nil, nil, nil
            if pts and #pts > 0 then
                sx, sy, sw, sh = strokeBBox(stroke)
            end
            if sx and not rectsOverlap(x0, y0, x1 - x0 + 1, y1 - y0 + 1, sx, sy, sw, sh) then
                pts = nil
            end
            if pts and #pts > 0 then
                local inside = 0
                for _, pt in ipairs(pts) do
                    if PencilGeometry.pointInPolygon(pt.x, pt.y, path) then
                        inside = inside + 1
                    end
                end
                if inside * 2 >= #pts then
                    table.insert(selected, stroke)
                    set[stroke] = true
                end
            end
        end
    end
    if #selected > 0 then
        local sel = { page = page, strokes = selected, set = set }
        sel.box = self:strokesBBox(selected, Screen:scaleBySize(6))
        self.lasso_selection = sel
        region = unionRect(region, self:getLassoOverlayRect(sel))
    else
        self.lasso_selection = nil
    end
    UIManager:setDirty(self.ui.dialog or self.ui, function()
        return "ui", Geom:new(region)
    end)
end

function Pencil:updateLassoMove(x, y)
    local m = self.lasso_move
    local sel = self.lasso_selection
    if not m or not sel then return end
    m.dx, m.dy = x - m.sx, y - m.sy
    if not m.started then
        local thr = Screen:scaleBySize(6)
        if m.dx * m.dx + m.dy * m.dy < thr * thr then return end
        m.started = true
        m.start_rect = self:getLassoOverlayRect(sel)
        m.last_rect = m.start_rect
        -- Page + all other strokes, without the selection and the toolbar
        self._hide_selection = true
        m.snap = self:renderPageSnapshot(true)
        self._hide_selection = false
    end
    local now = time.now()
    if m.last and time.to_ms(now - m.last) < LASSO_REFRESH_MS then return end
    m.last = now
    self:drawLassoMove(m)
end

-- Draw the selection at its current drag offset (without committing it)
function Pencil:drawLassoMove(m)
    local sel = self.lasso_selection
    local box = sel.box
    local moved_box = { x = box.x + m.dx, y = box.y + m.dy, w = box.w, h = box.h }
    local preview = { box = moved_box }
    local new_rect = self:getLassoOverlayRect(preview)
    local u = unionRect(m.last_rect, new_rect)
    m.last_rect = new_rect
    m.total = unionRect(m.total or m.start_rect, new_rect)
    if not snapshotFits(m.snap) then return end
    Screen.bb:blitFrom(m.snap, u.x, u.y, u.x, u.y, u.w, u.h)
    for _, stroke in ipairs(sel.strokes) do
        self:renderStrokeOffset(Screen.bb, stroke, m.dx, m.dy, Device:isKindle())
    end
    local saved = self.lasso_selection
    self.lasso_selection = { page = sel.page, strokes = sel.strokes, set = sel.set, box = moved_box }
    self:paintLassoOverlay(Screen.bb, sel.page)
    self.lasso_selection = saved
    if self:isToolbarVisible() then
        local tr = self.toolbar:getRect()
        if rectsOverlap(u.x, u.y, u.w, u.h, tr.x, tr.y, tr.w, tr.h) then
            self.toolbar:paintTo(Screen.bb)
        end
    end
    Screen:refreshFast(u.x, u.y, u.w, u.h)
end

function Pencil:finishLassoMove(m)
    local sel = self.lasso_selection
    if m.snap then
        self:releaseSnapshotBuffer(m.snap)
        m.snap = nil
    end
    if not sel or not m.started or (m.dx == 0 and m.dy == 0) then
        return   -- a tap inside the selection: keep it as it is
    end
    self:shiftStrokes(sel.strokes, m.dx, m.dy)
    self:pushUndo({ type = "move", strokes = sel.strokes, dx = m.dx, dy = m.dy })
    sel.box = self:strokesBBox(sel.strokes, Screen:scaleBySize(6))
    self:rebuildPageIndex()
    self:rebuildAnnotationGroups()
    self:scheduleDeferredWork()
    local region = unionRect(m.total or m.start_rect, self:getLassoOverlayRect(sel))
    UIManager:setDirty(self.ui.dialog or self.ui, function()
        return "ui", Geom:new(region)
    end)
end

function Pencil:deleteLassoSelection()
    local sel = self.lasso_selection
    if not sel or #sel.strokes == 0 then return end
    local region = self:getLassoOverlayRect(sel)
    for i = #self.strokes, 1, -1 do
        if sel.set[self.strokes[i]] then
            table.remove(self.strokes, i)
        end
    end
    self:pushUndo({ type = "delete", strokes = sel.strokes })
    self.lasso_selection = nil
    self:rebuildPageIndex()
    self:rebuildAnnotationGroups()
    self:scheduleDeferredWork()
    UIManager:setDirty(self.ui.dialog or self.ui, function()
        return "ui", Geom:new(region)
    end)
end

return Pencil
