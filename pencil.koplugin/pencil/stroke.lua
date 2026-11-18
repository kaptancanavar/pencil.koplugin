--[[--
Freehand strokes from raw input: start, add points (drawn directly into
the framebuffer), commit.

@module pencil.stroke
--]]--

local Device = require("device")
local PencilGeometry = require("lib/geometry")
local Screen = Device.screen
local logger = require("logger")
local time = require("ui/time")
local Common = require("pencil/common")
local TOOL_PEN = Common.TOOL_PEN
local TOOL_HIGHLIGHTER = Common.TOOL_HIGHLIGHTER
local PEN_TYPE_PEN = Common.PEN_TYPE_PEN
local PEN_TYPE_FOUNTAIN = Common.PEN_TYPE_FOUNTAIN
local PEN_TYPE_MARKER = Common.PEN_TYPE_MARKER
local MARKER_FACTOR = Common.MARKER_FACTOR
local FOUNTAIN_MAX_FACTOR = Common.FOUNTAIN_MAX_FACTOR

local Pencil = {}

-- Start a new stroke from raw input
-- tool_override / pen_type_override: set while the side button is held with
-- a shortcut tool (see resolveSideButton).
function Pencil:startRawStroke(tool_override, pen_type_override)
    local page = self:getCurrentPage()
    local tool = tool_override or (self.side_button_down and TOOL_HIGHLIGHTER or self.current_tool)
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]

    if self.side_button_down then
        self.side_button_used_for_highlight = true
    end

    self.current_stroke = {
        page = page,
        vkey = self:getViewKey(),
        tool = tool,
        points = {},
        width = tool_settings.width,
        color = tool_settings.color,
        color_name = tool_settings.color_name,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }
    local pen_type = pen_type_override or tool_settings.pen_type
    if tool == TOOL_PEN and pen_type and pen_type ~= PEN_TYPE_PEN then
        self.current_stroke.pen_type = pen_type
        -- Input may swap its touch handler (e.g. snow protocol quirks);
        -- make sure we still see ABS_PRESSURE before relying on it.
        self:installPressureHook()
    end
    self.last_refresh_time = time.now()
    self.dirty_region = nil  -- Clear any pending dirty region
    logger.dbg("Pencil: raw stroke started")
end

-- Add a point from raw input and draw it
function Pencil:addRawPoint(x, y)
    if not self.current_stroke then return end

    local point = { x = x, y = y }
    if self.current_stroke.pen_type then
        point.p = self:getPenPressure()
    end
    table.insert(self.current_stroke.points, point)

    local n = #self.current_stroke.points

    local width = self.current_stroke.width
    local color = self.current_stroke.color
    local half_w = math.floor(width / 2) + 2  -- padding for antialiasing
    if self.current_stroke.pen_type == PEN_TYPE_FOUNTAIN then
        half_w = math.floor(width * FOUNTAIN_MAX_FACTOR / 2) + 2
    elseif self.current_stroke.pen_type == PEN_TYPE_MARKER then
        half_w = math.floor(width * MARKER_FACTOR / 2) + 2
    end

    -- Reinvert color in night mode (if it's not black or gray)
    if Screen.night_mode and self.current_stroke.color_name ~= "Black" and self.current_stroke.color_name ~= "Gray" then
        color = color:invert()
    end

    -- Draw to framebuffer and track dirty region
    local dirty_x, dirty_y, dirty_w, dirty_h
    if n == 1 then
        -- Draw first point same size as line segments for consistency
        local half_w_draw = math.floor(width / 2)
        if self.current_stroke.tool == TOOL_HIGHLIGHTER then
            self:drawHighlighterSegment(Screen.bb, x, y, x, y, width, color, self:useInkPreview())
        elseif self.current_stroke.pen_type then
            self:drawPenSegment(Screen.bb, self.current_stroke, point, point, 0, 0, width, color)
        else
            Screen.bb:paintRectRGB32(x - half_w_draw, y - half_w_draw, width, width, color)
        end
        -- Use slightly larger dirty region for refresh padding
        dirty_x = x - half_w
        dirty_y = y - half_w
        dirty_w = width + 4
        dirty_h = width + 4
    elseif n >= 2 then
        local p1 = self.current_stroke.points[n - 1]
        local p2 = self.current_stroke.points[n]
        if self.current_stroke.tool == TOOL_HIGHLIGHTER then
            self:drawHighlighterSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color, self:useInkPreview())
        else
            self:drawPenSegment(Screen.bb, self.current_stroke, p1, p2, 0, 0, width, color)
        end
        -- Calculate bounding box of the segment
        dirty_x = math.min(p1.x, p2.x) - half_w
        dirty_y = math.min(p1.y, p2.y) - half_w
        dirty_w = math.abs(p2.x - p1.x) + width + 4
        dirty_h = math.abs(p2.y - p1.y) + width + 4
    end

    -- Accumulate dirty region for batch refresh
    if dirty_x then
        if self.dirty_region then
            -- Expand existing dirty region
            local r = self.dirty_region
            local new_x = math.min(r.x, dirty_x)
            local new_y = math.min(r.y, dirty_y)
            local new_x2 = math.max(r.x + r.w, dirty_x + dirty_w)
            local new_y2 = math.max(r.y + r.h, dirty_y + dirty_h)
            self.dirty_region = { x = new_x, y = new_y, w = new_x2 - new_x, h = new_y2 - new_y }
        else
            self.dirty_region = { x = dirty_x, y = dirty_y, w = dirty_w, h = dirty_h }
        end
    end

    -- Periodic refresh of dirty region only.
    -- When Sony Direct Handwriting is active, the kernel paints stylus strokes
    local now = time.now()
    if time.to_ms(now - self.last_refresh_time) >= self.refresh_interval_ms then
        self.last_refresh_time = now
        if self.dirty_region then
            local r = self.dirty_region
            -- Clamp to screen bounds
            local rx = math.max(0, math.floor(r.x))
            local ry = math.max(0, math.floor(r.y))
            local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
            local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
            -- On Sony, refreshFast routes through SonyEPDController which
            -- selects DU mode (mode 1 = ~120ms partial, 1-bit). On Kobo the
            -- original GC16 refreshUI is needed for proper color rendering.
            -- Kindle (Scribe): refreshFast maps to A2/DU on the MTK/mxcfb
            -- driver, which keeps ink-under-pen latency acceptable.
            -- The full refresh after the stroke ends restores quality.
            -- The highlighter's light gray would turn white under A2/DU, so on
            -- Kindle it is previewed as a dot pattern (useInkPreview) and
            -- replaced with real gray by the settle repaint.
            if self.sony_dhw_active or Device:isKindle() then
                Screen:refreshFast(rx, ry, rw, rh)
            else
                Screen:refreshUI(rx, ry, rw, rh)
            end
            self.dirty_region = nil
        end
    end
end

-- End stroke from raw input
function Pencil:endRawStroke()
    if self.input_debug_mode then
        self:writeDebugLog(string.format("endRawStroke: current_stroke=%s points=%d",
            tostring(self.current_stroke ~= nil),
            self.current_stroke and #self.current_stroke.points or 0))
    end
    if self.current_stroke and #self.current_stroke.points >= 1 then
        if self.current_stroke.tool == TOOL_HIGHLIGHTER and self.settle_repaint then
            -- Remember where the dot-pattern preview is, so the settle repaint
            -- only refreshes that area (see scheduleDelayedRefresh).
            local b = PencilGeometry.computeStrokeBbox(self.current_stroke)
            if b then
                local pad = math.floor((self.current_stroke.width or 20) / 2) + 4
                local r = self.settle_region
                if r then
                    r.x0, r.y0 = math.min(r.x0, b.x0 - pad), math.min(r.y0, b.y0 - pad)
                    r.x1, r.y1 = math.max(r.x1, b.x1 + pad), math.max(r.y1, b.y1 + pad)
                else
                    self.settle_region = { x0 = b.x0 - pad, y0 = b.y0 - pad,
                                           x1 = b.x1 + pad, y1 = b.y1 + pad }
                end
            end
        end
        self:anchorIfScroll(self.current_stroke)
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        self:pushUndo({ type = "add", stroke_idx = #self.strokes })
        self:assignStrokeToGroup(#self.strokes)
        self:scheduleDeferredWork()
        if self.input_debug_mode then
            self:writeDebugLog(string.format("endRawStroke: SAVED stroke #%d with %d points, total strokes=%d",
                #self.strokes, #self.current_stroke.points, #self.strokes))
        end
        logger.dbg("Pencil: raw stroke ended with", #self.current_stroke.points, "points")
    else
        if self.input_debug_mode then
            self:writeDebugLog("endRawStroke: NOT SAVED (no current_stroke or no points)")
        end
    end
    self.current_stroke = nil
    -- Schedule delayed refresh for clean display after writing stops
    self:scheduleDelayedRefresh()
end

return Pencil
