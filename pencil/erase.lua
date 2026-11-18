--[[--
Eraser: hit tests, partial erasing, snapshot-based fast screen updates.

@module pencil.erase
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local PencilGeometry = require("lib/geometry")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local Common = require("pencil/common")
local TOOL_HIGHLIGHTER = Common.TOOL_HIGHLIGHTER
local TOOL_ERASER = Common.TOOL_ERASER
local rectsOverlap = Common.rectsOverlap
local strokeDrawWidth = Common.strokeDrawWidth
local strokeBBox = Common.strokeBBox
local snapshotFits = Common.snapshotFits

local Pencil = {}

-- Erase strokes at a given point
-- Returns array of deleted strokes (for undo), or nil if none
-- Eraser screen updates. Re-rendering the page (CREngine) for every update
-- is what made erasing crawl. Instead, at the first hit of an eraser gesture
-- the page is rendered ONCE without our strokes into a snapshot buffer;
-- after that an erased area is restored by blitting it back from the
-- snapshot (a memory copy), redrawing only the strokes that overlap it, and
-- refreshing just that area with the fast waveform. On lift, the whole
-- erased area gets one gray-capable refresh and the snapshot is freed.
local ERASE_REFRESH_MS = 40

-- ---------------------------------------------------------------------------
-- Offscreen page snapshots (eraser, toolbar drag, lasso move). A full-screen
-- buffer is ~4.6 MB on the Scribe (18 MB in color). Instead of allocating and
-- freeing one per gesture, one buffer is kept and reused, and released after
-- SNAPSHOT_IDLE_S without use (and on suspend, close and screen changes).
-- ---------------------------------------------------------------------------

local SNAPSHOT_IDLE_S = 30

function Pencil:acquireSnapshotBuffer()
    if not Screen.bb then return nil end
    local W, H, T = Screen:getWidth(), Screen:getHeight(), Screen.bb:getType()
    local c = self._snap_cache
    if c and not c.in_use then
        if c.w == W and c.h == H and c.type == T then
            c.in_use = true
            if self._snap_idle_fn then
                UIManager:unschedule(self._snap_idle_fn)
                self._snap_idle_fn = nil
            end
            return c.bb
        end
        self:freeSnapshotCache()   -- wrong size (rotation): replace
        c = nil
    end
    local ok, bb = pcall(Blitbuffer.new, W, H, T)
    if not ok or not bb then return nil end
    if not c then
        self._snap_cache = { bb = bb, w = W, h = H, type = T, in_use = true }
    end
    -- else: the cached buffer is busy (two gestures at once); this one is
    -- temporary and freed on release
    return bb
end

function Pencil:releaseSnapshotBuffer(bb)
    if not bb then return end
    local c = self._snap_cache
    if c and c.bb == bb then
        c.in_use = false
        if not self._snap_idle_fn then
            self._snap_idle_fn = function()
                self._snap_idle_fn = nil
                local cc = self._snap_cache
                if cc and not cc.in_use then self:freeSnapshotCache() end
            end
            UIManager:scheduleIn(SNAPSHOT_IDLE_S, self._snap_idle_fn)
        end
    else
        bb:free()
    end
end

function Pencil:freeSnapshotCache()
    if self._snap_idle_fn then
        UIManager:unschedule(self._snap_idle_fn)
        self._snap_idle_fn = nil
    end
    local c = self._snap_cache
    if c and not c.in_use then
        c.bb:free()
        self._snap_cache = nil
    end
end

-- Page as rendered without our strokes/toolbar. nil where we can't safely
-- blit (night mode inverts the framebuffer; Sony uses its own overlay).
function Pencil:ensureEraseSnapshot()
    if self.erase_snapshot and not snapshotFits(self.erase_snapshot) then
        self:freeEraseSnapshot()
    end
    if not self.erase_snapshot then
        self.erase_snapshot = self:renderPageSnapshot(false)
    end
    return self.erase_snapshot
end

function Pencil:freeEraseSnapshot()
    if self.erase_snapshot then
        self:releaseSnapshotBuffer(self.erase_snapshot)
        self.erase_snapshot = nil
    end
end

-- Called by eraseAtPoint for every hit: grow the area that needs restoring.
-- A partial erase only changes the pixels under the eraser, so that circle is
-- enough; a whole-stroke erase needs the stroke's full bounding box.
function Pencil:addEraseArea(x0, y0, x1, y1)
    local r = self.erase_region
    if not r then
        self.erase_region = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
    else
        if x0 < r.x0 then r.x0 = x0 end
        if y0 < r.y0 then r.y0 = y0 end
        if x1 > r.x1 then r.x1 = x1 end
        if y1 > r.y1 then r.y1 = y1 end
    end
end

function Pencil:queueEraseRefresh(deleted)
    for _, stroke in ipairs(deleted or {}) do
        if stroke.tool == TOOL_HIGHLIGHTER then
            self.erase_total_gray = true
        end
    end
    local now = time.now()
    if not self.last_erase_refresh
            or time.to_ms(now - self.last_erase_refresh) >= ERASE_REFRESH_MS then
        self:flushEraseRefresh()
    elseif not self.erase_flush_scheduled then
        -- Throttled: make sure this erase still shows up even if no further
        -- hit follows before the pen is lifted.
        self.erase_flush_scheduled = function()
            self.erase_flush_scheduled = nil
            local ok, err = pcall(self.flushEraseRefresh, self)
            if not ok then self:reportError("erase refresh", err) end
        end
        UIManager:scheduleIn(ERASE_REFRESH_MS / 1000, self.erase_flush_scheduled)
    end
end

-- Restore a rect from the page snapshot and redraw what lies on top of it.
-- live = true while the eraser is down: on Kindle, markers are then drawn as
-- the A2/DU-friendly dot pattern, which is cheap and survives the fast
-- refresh; the final pass on lift draws them in real gray.
-- Returns whether a marker was redrawn.
function Pencil:repaintEraseArea(snap, x, y, w, h, live)
    Screen.bb:blitFrom(snap, x, y, x, y, w, h)
    local preview = live and Device:isKindle()
    local gray = false
    local page = self:getCurrentPage()
    for _, idx in ipairs(self:pageIndices(page)) do
        local stroke = self.strokes[idx]
        if stroke then
            local sx, sy, sw, sh = strokeBBox(stroke)
            if sx and rectsOverlap(x, y, w, h, sx, sy, sw, sh) then
                self:renderStroke(Screen.bb, stroke, preview)
                if stroke.tool == TOOL_HIGHLIGHTER then gray = true end
            end
        end
    end
    if self:isToolbarVisible() then
        local tr = self.toolbar:getRect()
        if rectsOverlap(x, y, w, h, tr.x, tr.y, tr.w, tr.h) then
            self.toolbar:paintTo(Screen.bb)
        end
    end
    return gray
end

local function clampRect(r)
    local x = math.max(0, math.floor(r.x0))
    local y = math.max(0, math.floor(r.y0))
    local w = math.min(Screen:getWidth(), math.ceil(r.x1)) - x
    local h = math.min(Screen:getHeight(), math.ceil(r.y1)) - y
    return x, y, w, h
end

function Pencil:flushEraseRefresh()
    local r = self.erase_region
    if not r then return end
    if self:isOverlayActive() then
        -- Never paint the page over a menu; UIManager repaints in stack order
        self.erase_region = nil
        UIManager:setDirty(self.ui.dialog or self.ui, "ui")
        return
    end
    self.erase_region = nil
    self.last_erase_refresh = time.now()
    local x, y, w, h = clampRect(r)
    if w <= 0 or h <= 0 then return end

    -- Remember the total area for the final pass on lift
    local t = self.erase_total
    if not t then
        self.erase_total = { x0 = x, y0 = y, x1 = x + w, y1 = y + h }
    else
        t.x0, t.y0 = math.min(t.x0, x), math.min(t.y0, y)
        t.x1, t.y1 = math.max(t.x1, x + w), math.max(t.y1, y + h)
    end

    local snap = self:ensureEraseSnapshot()
    if not snapshotFits(snap) then
        -- Fallback: full repaint (ReaderView:paintTo also paints our module)
        self.view:paintTo(Screen.bb, 0, 0)
        Screen:refreshUI(x, y, w, h)
        return
    end
    if self:repaintEraseArea(snap, x, y, w, h, true) then
        self.erase_total_gray = true
    end
    if Device:isKindle() then
        -- Fast DU refresh; markers are dots right now, so they stay visible.
        -- (One REAGL per update queued up and lagged for seconds.)
        Screen:refreshFast(x, y, w, h)
    else
        Screen:refreshUI(x, y, w, h)
    end
end

-- An erase gesture was interrupted (page turn, overlay, error, sleep). Its
-- snapshot may belong to another page, so nothing is painted from it; the
-- strokes already erased stay erased and get their undo entry; the screen is
-- left to a normal repaint.
function Pencil:abortErase()
    if self.erase_flush_scheduled then
        UIManager:unschedule(self.erase_flush_scheduled)
        self.erase_flush_scheduled = nil
    end
    self.erase_region, self.erase_total = nil, nil
    self.erase_gray, self.erase_total_gray = false, false
    self.last_erase_refresh = nil
    self.erase_prev_x, self.erase_prev_y = nil, nil
    self:freeEraseSnapshot()
    for _, key in ipairs({ "eraser_deleted", "eraser_button_deleted" }) do
        local deleted = self[key]
        if deleted and #deleted > 0 then
            self:pushUndo({ type = "delete", strokes = deleted })
            self:scheduleDeferredWork()
        end
        -- The eraser end / side button may still be in use: keep a list ready
        self[key] = (key == "eraser_button_deleted") and {} or nil
    end
    if self.erase_groups_dirty then
        self.erase_groups_dirty = false
        pcall(self.rebuildAnnotationGroups, self)
    end
    UIManager:setDirty(self.ui.dialog or self.ui, "ui")
end

-- Eraser lifted: flush the pending update, then ONE final pass over the
-- whole erased area (markers in real gray, one REAGL refresh if a marker was
-- involved), free the snapshot, rebuild groups once.
function Pencil:finishErase()
    self.erase_prev_x, self.erase_prev_y = nil, nil
    if self.erase_flush_scheduled then
        UIManager:unschedule(self.erase_flush_scheduled)
        self.erase_flush_scheduled = nil
    end
    self:flushEraseRefresh()
    self.last_erase_refresh = nil
    local t = self.erase_total
    self.erase_total = nil
    if t and (self:isOverlayActive() or not snapshotFits(self.erase_snapshot)) then
        -- Can't paint directly: let UIManager repaint in stack order
        UIManager:setDirty(self.ui.dialog or self.ui, self.erase_total_gray and "partial" or "ui")
        t = nil
    end
    if t then
        local x, y, w, h = clampRect(t)
        if w > 0 and h > 0 then
            if self.erase_snapshot then
                self:repaintEraseArea(self.erase_snapshot, x, y, w, h, false)
            end
            if self.erase_total_gray then
                Screen:refreshPartial(x, y, w, h)
            else
                Screen:refreshUI(x, y, w, h)
            end
        end
    end
    self.erase_total_gray = false
    self:freeEraseSnapshot()
    if self.erase_groups_dirty then
        self.erase_groups_dirty = false
        self:rebuildAnnotationGroups()
    end
end

function Pencil:eraseAtPoint(x, y, page)
    -- Only erase strokes on the current page
    if self.input_debug_mode then
        self:writeDebugLog(string.format("ERASE: searching %d strokes at (%d, %d)",
            #self.strokes, x, y))
    end

    if #self.strokes == 0 then
        if self.input_debug_mode then
            self:writeDebugLog("ERASE: no strokes exist")
        end
        return nil
    end

    local eraser_width = self:getEraserRadius()
    local deleted = {}
    local indices_to_remove = {}
    local added_pieces = {}

    -- Iterate only strokes on the current page via the page index. Keeps the
    -- per-sample erase cost O(strokes-on-page) instead of O(total-strokes).
    local page_indices = self.page_strokes and self:pageIndices(page) or nil
    if page_indices then
        for _, i in ipairs(page_indices) do
            local stroke = self.strokes[i]
            if stroke then
                if self.input_debug_mode and stroke.points and #stroke.points > 0 then
                    local min_x, max_x, min_y, max_y = stroke.points[1].x, stroke.points[1].x, stroke.points[1].y, stroke.points[1].y
                    for _, pt in ipairs(stroke.points) do
                        if pt.x < min_x then min_x = pt.x end
                        if pt.x > max_x then max_x = pt.x end
                        if pt.y < min_y then min_y = pt.y end
                        if pt.y > max_y then max_y = pt.y end
                    end
                    self:writeDebugLog(string.format("ERASE: stroke %d bounds: (%d-%d, %d-%d), eraser at (%d,%d) threshold=%d",
                        i, min_x, max_x, min_y, max_y, x, y, eraser_width))
                end
                local pieces, hit
                -- The points are the stroke's centre line, but its ink
                -- reaches half the drawn width beyond them. Measuring
                -- against the bare eraser radius missed thick strokes
                -- (highlighter, marker, fountain pen) that the eraser
                -- visibly touched, and a partial cut left a stub of ink of
                -- half the stroke width inside the eraser circle.
                local half_w = math.floor(strokeDrawWidth(stroke) / 2)
                local reach_r = eraser_width + half_w
                -- Cheap reject first: eraser circle far from the stroke's box
                -- (the box already includes the stroke's half width)
                local bx, by, bw, bh = strokeBBox(stroke)
                local near = bx and x >= bx - eraser_width and x <= bx + bw + eraser_width
                    and y >= by - eraser_width and y <= by + bh + eraser_width
                if near and self:isPointNearStroke(x, y, stroke, reach_r) then
                    hit = true
                    if self.partial_eraser then
                        -- Partial erase: keep the parts of the stroke outside
                        -- the eraser radius as new strokes. If the circle only
                        -- grazes the line without removing a point, it's a miss
                        -- (otherwise the stroke would be "deleted" and re-added
                        -- unchanged, polluting undo).
                        local cut
                        pieces, cut = self:splitStrokeAtPoint(stroke, x, y, reach_r)
                        hit = cut
                    end
                end
                if hit then
                    table.insert(deleted, stroke)
                    table.insert(indices_to_remove, i)
                    -- Area to restore on screen: just the eraser circle for a
                    -- partial cut (the rest of the stroke is unchanged), the
                    -- whole stroke otherwise.
                    if pieces then
                        local reach = reach_r + half_w + 4
                        self:addEraseArea(x - reach, y - reach, x + reach, y + reach)
                    else
                        local sx, sy, sw, sh = strokeBBox(stroke)
                        if sx then self:addEraseArea(sx - 4, sy - 4, sx + sw + 4, sy + sh + 4) end
                    end
                    if pieces then
                        -- The original is remembered (with its pieces) so
                        -- undo can restore it.
                        stroke._split_into = pieces
                        for _, piece in ipairs(pieces) do
                            table.insert(added_pieces, piece)
                        end
                    end
                    if self.input_debug_mode then
                        self:writeDebugLog(string.format("ERASE: found stroke %d to delete", i))
                    end
                end
            end
        end
    end

    -- Remove strokes (in reverse order to maintain indices)
    if #indices_to_remove > 0 then
        table.sort(indices_to_remove, function(a, b) return a > b end)
        for _, idx in ipairs(indices_to_remove) do
            table.remove(self.strokes, idx)
        end
        for _, piece in ipairs(added_pieces) do
            table.insert(self.strokes, piece)
        end
        self:rebuildPageIndex()
        -- Group rebuild re-syncs bookmarks and scans the image folder: far
        -- too slow to run on every eraser sample. Done once on eraser lift
        -- (finishErase); paintTo only needs the page index rebuilt above.
        self.erase_groups_dirty = true
        if self.input_debug_mode then
            self:writeDebugLog(string.format("ERASE: deleted %d strokes, kept %d pieces",
                #deleted, #added_pieces))
        end
        return deleted
    end

    return nil
end

-- Split a stroke into the runs of points that lie outside the eraser circle.
-- Runs with fewer than 2 points are dropped. Returns new stroke tables that
-- copy every field of the original except points.
-- Returns the pieces of `stroke` outside the eraser circle, and whether
-- anything was actually cut away. Points are densified first, so a segment
-- crossing the circle is cut even when its endpoints both lie outside it.
function Pencil:splitStrokeAtPoint(stroke, x, y, radius)
    local r_sq = radius * radius
    local pieces = {}
    local run = {}
    local cut = false
    local function flush()
        if #run >= 2 then
            local piece = {}
            for k, v in pairs(stroke) do
                if k ~= "points" and k ~= "_split_into" and k ~= "dpts" and k ~= "_bbox" then
                    piece[k] = v
                end
            end
            piece.points = run
            if piece.anchor then
                self:syncDocPoints(piece)
            end
            table.insert(pieces, piece)
        end
        run = {}
    end
    local step = math.max(1, math.floor(radius / 3))
    for _, pt in ipairs(PencilGeometry.densifyPoints(stroke.points or {}, step)) do
        local dx, dy = pt.x - x, pt.y - y
        if dx * dx + dy * dy <= r_sq then
            cut = true
            flush()
        else
            table.insert(run, pt)
        end
    end
    flush()
    return pieces, cut
end

-- Eraser radius in screen pixels. The stored width (20) was in raw pixels,
-- which is only ~1.7 mm on the Scribe's 300 ppi panel; scale it like the
-- rest of the UI so the eraser is a usable size on high-DPI screens.
function Pencil:getEraserRadius()
    return Screen:scaleBySize(self.tool_settings[TOOL_ERASER].width or 20) * 0.8
end

-- Erase along the eraser's path from its previous sample to the current one,
-- so a fast swipe can't jump over a thin stroke between two samples.
-- Returns the merged list of deleted strokes, or nil.
function Pencil:eraseAlong(x0, y0, x1, y1, page)
    local all
    local function add(deleted)
        if deleted then
            all = all or {}
            for _, s in ipairs(deleted) do table.insert(all, s) end
        end
    end
    if x0 and y0 then
        local dx, dy = x1 - x0, y1 - y0
        local dist = math.sqrt(dx * dx + dy * dy)
        local step = math.max(1, self:getEraserRadius() / 2)
        local k = math.floor(dist / step)
        for j = 1, k do
            local t = j / (k + 1)
            add(self:eraseAtPoint(math.floor(x0 + dx * t + 0.5), math.floor(y0 + dy * t + 0.5), page))
        end
    end
    add(self:eraseAtPoint(x1, y1, page))
    return all
end

return Pencil
