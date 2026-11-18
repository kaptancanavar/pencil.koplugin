--[[--
Drawing primitives (pen types, highlighter) and the view module's paintTo.

@module pencil.render
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local PencilGeometry = require("lib/geometry")
local Screen = Device.screen
local logger = require("logger")
local Common = require("pencil/common")
local TOOL_PEN = Common.TOOL_PEN
local TOOL_HIGHLIGHTER = Common.TOOL_HIGHLIGHTER
local PEN_TYPE_FOUNTAIN = Common.PEN_TYPE_FOUNTAIN
local PEN_TYPE_PENCIL = Common.PEN_TYPE_PENCIL
local PEN_TYPE_MARKER = Common.PEN_TYPE_MARKER
local MARKER_FACTOR = Common.MARKER_FACTOR
local FOUNTAIN_MIN_FACTOR = Common.FOUNTAIN_MIN_FACTOR
local FOUNTAIN_MAX_FACTOR = Common.FOUNTAIN_MAX_FACTOR
local PENCIL_MIN_DENSITY = Common.PENCIL_MIN_DENSITY
local PENCIL_MAX_DENSITY = Common.PENCIL_MAX_DENSITY

local Pencil = {}

-- Render a line segment using rectangles (since BlitBuffer has no native line drawing)
function Pencil:drawLineSegment(bb, x1, y1, x2, y2, width, color)
    local dx = x2 - x1
    local dy = y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)

    if dist < 1 then
        -- Just draw a single point
        local half_w = math.floor(width / 2)
        bb:paintRectRGB32(x1 - half_w, y1 - half_w, width, width, color)
        return
    end

    -- Step along the line drawing small rectangles. Thin lines step 1px;
    -- very thick ones (fountain pen at full pressure) step 1/8 of their
    -- width: visually identical (edge within 1px of the 1px-step result,
    -- checked against the old renderer) at a fraction of the fills.
    local step = math.max(1, math.floor(width / 8))
    local steps = math.max(1, math.ceil(dist / step))
    local half_w = math.floor(width / 2)

    for i = 0, steps do
        local t = i / steps
        local x = math.floor(x1 + dx * t)
        local y = math.floor(y1 + dy * t)
        bb:paintRectRGB32(x - half_w, y - half_w, width, width, color)
    end
end

-- ---------------------------------------------------------------------------
-- Pen types. Pressure p (0..1) is stored per point for fountain and pencil;
-- strokes from devices/firmware without pressure use 0.5 throughout.
-- ---------------------------------------------------------------------------


-- Deterministic per-pixel noise in [0, 1): the same pixel always gets the
-- same value, so redrawing a pencil stroke gives exactly the same grain.
local GRAIN_MOD = 1000003   -- prime; all products stay well below 2^53
local function grain(x, y)
    local h = (x * 73856093 + y * 19349663) % GRAIN_MOD
    h = (h * h * 37 + h * 13 + 7) % GRAIN_MOD   -- non-linear mix: no visible stripes
    return h / GRAIN_MOD
end

-- One pixel setter per density level (pressure is stored in 1/100 steps),
-- instead of a fresh closure for every segment
local grain_setters = {}
local function grainSetter(density)
    local key = math.floor(density * 100 + 0.5)
    local f = grain_setters[key]
    if not f then
        local d = key / 100
        f = function(b, x, y, c)
            if grain(x, y) < d then
                b:setPixel(x, y, c)
            end
        end
        grain_setters[key] = f
    end
    return f
end

function Pencil:drawGrainSegment(bb, x1, y1, x2, y2, width, color, density)
    local setter = grainSetter(density)
    local dx, dy = x2 - x1, y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    local half_w = math.floor(width / 2)
    -- The grain is a pure function of the pixel, so overlapping squares just
    -- redraw the same pixels: a step of 1/4 of the width keeps the stroke's
    -- full width on diagonals (checked against 1px steps) and is cheaper.
    local steps = math.max(1, math.ceil(dist / math.max(1, math.floor(width / 4))))
    for i = 0, steps do
        local t = i / steps
        local x = math.floor(x1 + dx * t)
        local y = math.floor(y1 + dy * t)
        bb:paintRectRGB32(x - half_w, y - half_w, width, width, color, setter)
    end
end

-- One segment of a pen stroke, honoring the stroke's pen type.
-- (ox, oy) offsets the points, for moved/offset rendering.
function Pencil:drawPenSegment(bb, stroke, p1, p2, ox, oy, width, color)
    local x1, y1, x2, y2 = p1.x + ox, p1.y + oy, p2.x + ox, p2.y + oy
    local pt = stroke.pen_type
    if pt == PEN_TYPE_FOUNTAIN then
        local pr = ((p1.p or 0.5) + (p2.p or 0.5)) / 2
        local f = FOUNTAIN_MIN_FACTOR + (FOUNTAIN_MAX_FACTOR - FOUNTAIN_MIN_FACTOR) * pr
        self:drawLineSegment(bb, x1, y1, x2, y2, math.max(1, math.floor(width * f + 0.5)), color)
    elseif pt == PEN_TYPE_MARKER then
        self:drawLineSegment(bb, x1, y1, x2, y2, math.max(2, math.floor(width * MARKER_FACTOR + 0.5)), color)
    elseif pt == PEN_TYPE_PENCIL then
        local pr = ((p1.p or 0.5) + (p2.p or 0.5)) / 2
        local density = PENCIL_MIN_DENSITY + (PENCIL_MAX_DENSITY - PENCIL_MIN_DENSITY) * pr
        self:drawGrainSegment(bb, x1, y1, x2, y2, math.max(2, width), color, density)
    else
        self:drawLineSegment(bb, x1, y1, x2, y2, width, color)
    end
end

-- Render a highlighter segment (semi-transparent, wider)
-- "Darken" pixel setter: keep whichever is darker, the existing pixel or the
-- highlighter color. Text under the marker stays black, white paper turns
-- gray, and overlapping segments don't build up (unlike multiply). The old
-- opaque fill painted over the text on grayscale screens.
local function setPixelDarken(bb, x, y, color)
    if color:getColor8().a < bb:getPixel(x, y):getColor8().a then
        bb:setPixel(x, y, color)
    end
end

-- Live preview while dragging the highlighter on Kindle: a 25% black dot
-- pattern. Unlike real gray it survives the 1-bit A2/DU fast refresh, so the
-- marker keeps up with the pen. The settle repaint after the stroke replaces
-- it with the real gray (see scheduleDelayedRefresh).
local function setPixelPreviewDots(bb, x, y, _color)
    if x % 2 == 0 and y % 2 == 0 then
        bb:setPixel(x, y, Blitbuffer.COLOR_BLACK)
    end
end

function Pencil:drawHighlighterSegment(bb, x1, y1, x2, y2, width, color, preview)
    local dx = x2 - x1
    local dy = y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)

    -- Highlighter is drawn as a lighter gray to simulate transparency on e-ink
    local highlight_color = color or Blitbuffer.Color8(0xDD)
    local half_w = math.floor(width / 2)
    local setter = preview and setPixelPreviewDots or setPixelDarken

    if dist < 1 then
        bb:paintRectRGB32(x1 - half_w, y1 - half_w, width, width, highlight_color, setter)
        return
    end

    -- Squares half a width apart still cover the path without gaps; with the
    -- idempotent darken setter the overlap is free, so no need for 1px steps.
    local step = math.max(1, half_w)
    local steps = math.ceil(dist / step)

    for i = 0, steps do
        local t = i / steps
        local x = math.floor(x1 + dx * t)
        local y = math.floor(y1 + dy * t)
        bb:paintRectRGB32(x - half_w, y - half_w, width, width, highlight_color, setter)
    end
end

-- Kindle: draw the live highlighter as a dot pattern (see setPixelPreviewDots)
-- and request a settle repaint once writing pauses.
function Pencil:useInkPreview()
    if Device:isKindle() and not self.sony_dhw_active then
        self.settle_repaint = true
        return true
    end
    return false
end

-- Check if a point is near a stroke (for eraser)
function Pencil:isPointNearStroke(px, py, stroke, threshold)
    return PencilGeometry.isPointNearStroke(px, py, stroke, threshold)
end

-- Render a complete stroke
function Pencil:renderStroke(bb, stroke, preview)
    if not stroke.points or #stroke.points < 1 then
        return
    end

    local tool = stroke.tool or TOOL_PEN
    local width = stroke.width or self.tool_settings[tool].width or 3

    -- Get color directly (it's already a Blitbuffer color)
    local color = stroke.color or self.tool_settings[tool].color or Blitbuffer.COLOR_BLACK

    -- Reinvert color in night mode (if it's not black or gray)
    if Screen.night_mode and stroke.color_name ~= "Black" and stroke.color_name ~= "Gray" then
        color = color:invert()
    end

    -- Highlighter uses lighter color
    local is_highlighter = (tool == TOOL_HIGHLIGHTER)
    if is_highlighter then
        -- For highlighter, use stored color or default gray
        color = stroke.color or Blitbuffer.Color8(0xDD)
    end

    if #stroke.points == 1 then
        -- Single point (dot)
        local p = stroke.points[1]
        local half_w = math.floor(width / 2)
        if is_highlighter then
            self:drawHighlighterSegment(bb, p.x, p.y, p.x, p.y, width, color, preview)
        elseif stroke.pen_type then
            self:drawPenSegment(bb, stroke, p, p, 0, 0, width, color)
        else
            bb:paintRectRGB32(p.x - half_w, p.y - half_w, width, width, color)
        end
    else
        -- Multiple points - draw line segments
        for i = 2, #stroke.points do
            local p1 = stroke.points[i - 1]
            local p2 = stroke.points[i]
            if is_highlighter then
                self:drawHighlighterSegment(bb, p1.x, p1.y, p2.x, p2.y, width, color, preview)
            else
                self:drawPenSegment(bb, stroke, p1, p2, 0, 0, width, color)
            end
        end
    end
end

-- View module paintTo method - called by ReaderView during repaints.
-- When the captureGroupImage routine asks ReaderView to repaint into our
-- offscreen buffer, this method is invoked recursively as part of the view
-- module loop; the _capturing guard suppresses re-entry so we can paint the
-- group's strokes deliberately onto the captured page background.
-- Called by ReaderView on every repaint. A Lua error here would abort the
-- whole repaint (and crash KOReader on every page draw), so it is isolated:
-- on error the page itself is still shown, just without our overlay.
function Pencil:paintTo(bb, x, y)
    local ok, err = pcall(self.paintToUnsafe, self, bb, x, y)
    if not ok then
        self:reportError("paint", err)
    end
end

function Pencil:paintToUnsafe(bb, x, y)
    if self._capturing or self._snapshot_mode then return end

    local page = self:getCurrentPage()
    local current_rot = Screen:getRotationMode()

    -- Backfill XPointers for legacy groups before we filter, so the
    -- rotation-aware page resolution below sees them.
    self:backfillGroupXPointers()

    -- Identify groups whose captured-image rotation no longer matches the
    -- current screen rotation. Their strokes will draw in the wrong place,
    -- so we skip them and draw a badge instead. For EPUB we match by the
    -- group's XPointer re-resolved to the current pagination, since the
    -- saved group.page would be stale across rotations.
    --
    -- Suppression: if any group on this page renders natively at the
    -- current rotation (i.e. matches current_rot, or pre-dates the feature
    -- entirely), we hide badges for OTHER stale groups on the same page so
    -- the view isn't cluttered with badges next to a visible annotation.
    -- Re-rotate to see the suppressed annotation.
    local stale_indices = nil
    local stale_groups = nil
    local groups_on_page = 0
    local groups_with_image = 0
    local has_native_annotation = false
    for _, group in ipairs(self.annotation_groups) do
        local gpage = self:getGroupCurrentPage(group)
        if gpage == page then
            groups_on_page = groups_on_page + 1
            if group.image_path then
                groups_with_image = groups_with_image + 1
            end
            if group.image_rotation == nil
                    or group.image_rotation == current_rot then
                -- Renders natively (same rotation as capture, or legacy group
                -- without rotation info — render strokes as-is).
                has_native_annotation = true
            elseif group.image_path then
                stale_groups = stale_groups or {}
                stale_groups[#stale_groups + 1] = group
                stale_indices = stale_indices or {}
                for _, idx in ipairs(group.stroke_indices or {}) do
                    stale_indices[idx] = true
                end
            end
        end
    end
    if has_native_annotation then
        -- Drop badges entirely; native-rotation strokes will render below.
        stale_groups = nil
        stale_indices = nil
    end
    local stale_count = stale_groups and #stale_groups or 0
    if not self._last_paint_log
            or self._last_paint_log.page ~= page
            or self._last_paint_log.rot ~= current_rot
            or self._last_paint_log.on_page ~= groups_on_page
            or self._last_paint_log.with_image ~= groups_with_image
            or self._last_paint_log.stale ~= stale_count
            or self._last_paint_log.native ~= has_native_annotation then
        logger.info("Pencil: paintTo page=", page, " rot=", current_rot,
            " groups_on_page=", groups_on_page,
            " with_image=", groups_with_image,
            " native=", tostring(has_native_annotation),
            " badges=", stale_count)
        self._last_paint_log = {
            page = page,
            rot = current_rot,
            on_page = groups_on_page,
            with_image = groups_with_image,
            stale = stale_count,
            native = has_native_annotation,
        }
    end

    -- Render saved strokes for current page (skipping stale ones, and the
    -- lasso selection while its background snapshot is being taken).
    local indices = self:pageIndices(page)
    local hidden = self._hide_selection and self.lasso_selection and self.lasso_selection.set
    for _, idx in ipairs(indices) do
        if not (stale_indices and stale_indices[idx]) then
            local stroke = self.strokes[idx]
            if stroke and not (hidden and hidden[stroke]) then
                self:renderStroke(bb, stroke)
            end
        end
    end

    -- Draw rotation-mismatch badges over the spots where the strokes would
    -- have appeared. Tapping a badge opens the saved image.
    if stale_groups then
        for _, group in ipairs(stale_groups) do
            self:renderRotationBadge(bb, group)
        end
    end

    -- Render current stroke being drawn (only if on current page)
    if self.current_stroke and self.current_stroke.page == page then
        self:renderStroke(bb, self.current_stroke)
    end

    -- Sticky notes, lasso path / selection
    self:paintNotes(bb, page)
    if not self._hide_selection then
        self:paintLassoOverlay(bb, page)
    end

    -- Floating toolbar always on top of page and strokes
    -- (_hide_toolbar: rendering the page snapshot used while dragging it)
    if self:isToolbarVisible() and not self._hide_toolbar then
        self.toolbar.active = self:getToolbarMode()
        self.toolbar:paintTo(bb)
    end
end

return Pencil
