--[[--
Constants and small helpers shared by the Pencil modules.

@module pencil.common
--]]--

local Device = require("device")
local Screen = Device.screen

-- Tool types
local TOOL_PEN = "pen"
local TOOL_HIGHLIGHTER = "highlighter"
local TOOL_ERASER = "eraser"
local TOOL_LASSO = "lasso"
local TOOL_NOTE = "note"

-- Pen types (pen tool only). Fountain and pencil use per-point pressure.
local PEN_TYPE_PEN = "pen"
local PEN_TYPE_FOUNTAIN = "fountain"
local PEN_TYPE_PENCIL = "pencil"
local PEN_TYPE_MARKER = "marker"   -- felt-tip: bold, even width
local MARKER_FACTOR = 2.5          -- marker line width relative to the pen width

-- What holding the pen's side button does (like the Kindle's "Kurzbefehl-
-- Taste"). Order and names follow the Kindle settings page.
local SIDE_BUTTON_TOOLS = {
    { id = "highlighter",  text = "Textmarker" },
    { id = "pen:pen",      text = "Stift" },
    { id = "pen:fountain", text = "Füller" },
    { id = "pen:marker",   text = "Marker" },
    { id = "pen:pencil",   text = "Bleistift" },
    { id = "eraser",       text = "Radierer" },
    { id = "lasso",        text = "Lassoauswahl" },
    { id = "note",         text = "Haftnotiz" },
    { id = "off",          text = "Aus" },
}
local SIDE_BUTTON_DEFAULT = "eraser"
local function sideButtonToolName(id)
    for _, t in ipairs(SIDE_BUTTON_TOOLS) do
        if t.id == id then return t.text end
    end
    return nil
end
-- Fountain: width factor at zero/full pressure. Pencil: grain density.
local FOUNTAIN_MIN_FACTOR = 0.35
local FOUNTAIN_MAX_FACTOR = 1.65
local PENCIL_MIN_DENSITY = 0.30
local PENCIL_MAX_DENSITY = 0.95

-- Color picker trigger settings
local COLOR_PICKER_DELAY_MS = 500  -- How long pen must be held still (milliseconds)
local COLOR_PICKER_TOLERANCE_PIXELS = 15  -- How many pixels pen can move while "still"

-- Annotation grouping constants
local GROUP_TIME_THRESHOLD_S = 10   -- seconds between strokes to be grouped
local GROUP_SPATIAL_THRESHOLD = 200 -- pixels between bboxes to be grouped

-- Annotation image constants
local IMAGE_CAPTURE_V_MARGIN_PX = 24     -- vertical padding around bbox before clamping
local IMAGE_MIN_HEIGHT_PX = 350          -- floor for captured strip height (legibility)
local IMAGE_MAX_DIM = 1280               -- only downscale captures whose longer side exceeds this
local IMAGE_JPEG_QUALITY = 85
local IMAGE_CAPTURE_DEBOUNCE_S = 4       -- seconds after last stroke before capturing
local IMAGE_BADGE_SIZE = 48              -- on-page badge edge (px) when annotation is stale
local IMAGE_BADGE_HIT_PAD = 32           -- extra pixels around badge for tap hit-test
local IMAGE_BADGE_MARGIN_GAP = 5         -- gap from text/screen edge for margin badge

local function rectsOverlap(ax, ay, aw, ah, bx, by, bw, bh)
    return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah
end

-- Bounding box of a stroke (incl. its width). Cached on the stroke: hit
-- tests, refresh regions and the lasso call this for every stroke on the
-- page, often per pen sample. The cache is keyed on point count and width;
-- code that moves points must clear it (see shiftStrokes).
local function strokeDrawWidth(stroke)
    local w = stroke.width or 3
    if stroke.pen_type == PEN_TYPE_FOUNTAIN then
        w = w * FOUNTAIN_MAX_FACTOR   -- full pressure draws wider than width
    elseif stroke.pen_type == PEN_TYPE_MARKER then
        w = w * MARKER_FACTOR
    end
    return w
end

local function strokeBBox(stroke)
    local pts = stroke.points
    if not pts or #pts == 0 then return nil end
    local c = stroke._bbox
    if c and c.n == #pts and c.wd == stroke.width then
        return c.x, c.y, c.w, c.h
    end
    local x0, y0, x1, y1 = pts[1].x, pts[1].y, pts[1].x, pts[1].y
    for i = 2, #pts do
        local p = pts[i]
        if p.x < x0 then x0 = p.x elseif p.x > x1 then x1 = p.x end
        if p.y < y0 then y0 = p.y elseif p.y > y1 then y1 = p.y end
    end
    local w = strokeDrawWidth(stroke)
    local half = math.floor(w / 2) + 2
    c = { n = #pts, wd = stroke.width,
          x = x0 - half, y = y0 - half, w = (x1 - x0) + 2 * half, h = (y1 - y0) + 2 * half }
    stroke._bbox = c
    return c.x, c.y, c.w, c.h
end

-- Is a snapshot still usable for blitting onto the current screen?
local function snapshotFits(bb)
    return bb ~= nil and Screen.bb ~= nil
        and bb:getWidth() == Screen:getWidth() and bb:getHeight() == Screen:getHeight()
end

local function unionRect(a, b)
    if not a then return b end
    if not b then return a end
    local x, y = math.min(a.x, b.x), math.min(a.y, b.y)
    return {
        x = x, y = y,
        w = math.max(a.x + a.w, b.x + b.w) - x,
        h = math.max(a.y + a.h, b.y + b.h) - y,
    }
end

return {
    TOOL_PEN = TOOL_PEN,
    TOOL_HIGHLIGHTER = TOOL_HIGHLIGHTER,
    TOOL_ERASER = TOOL_ERASER,
    TOOL_LASSO = TOOL_LASSO,
    TOOL_NOTE = TOOL_NOTE,
    PEN_TYPE_PEN = PEN_TYPE_PEN,
    PEN_TYPE_FOUNTAIN = PEN_TYPE_FOUNTAIN,
    PEN_TYPE_PENCIL = PEN_TYPE_PENCIL,
    PEN_TYPE_MARKER = PEN_TYPE_MARKER,
    MARKER_FACTOR = MARKER_FACTOR,
    SIDE_BUTTON_TOOLS = SIDE_BUTTON_TOOLS,
    SIDE_BUTTON_DEFAULT = SIDE_BUTTON_DEFAULT,
    sideButtonToolName = sideButtonToolName,
    FOUNTAIN_MIN_FACTOR = FOUNTAIN_MIN_FACTOR,
    FOUNTAIN_MAX_FACTOR = FOUNTAIN_MAX_FACTOR,
    PENCIL_MIN_DENSITY = PENCIL_MIN_DENSITY,
    PENCIL_MAX_DENSITY = PENCIL_MAX_DENSITY,
    COLOR_PICKER_DELAY_MS = COLOR_PICKER_DELAY_MS,
    COLOR_PICKER_TOLERANCE_PIXELS = COLOR_PICKER_TOLERANCE_PIXELS,
    GROUP_TIME_THRESHOLD_S = GROUP_TIME_THRESHOLD_S,
    GROUP_SPATIAL_THRESHOLD = GROUP_SPATIAL_THRESHOLD,
    IMAGE_CAPTURE_V_MARGIN_PX = IMAGE_CAPTURE_V_MARGIN_PX,
    IMAGE_MIN_HEIGHT_PX = IMAGE_MIN_HEIGHT_PX,
    IMAGE_MAX_DIM = IMAGE_MAX_DIM,
    IMAGE_JPEG_QUALITY = IMAGE_JPEG_QUALITY,
    IMAGE_CAPTURE_DEBOUNCE_S = IMAGE_CAPTURE_DEBOUNCE_S,
    IMAGE_BADGE_SIZE = IMAGE_BADGE_SIZE,
    IMAGE_BADGE_HIT_PAD = IMAGE_BADGE_HIT_PAD,
    IMAGE_BADGE_MARGIN_GAP = IMAGE_BADGE_MARGIN_GAP,
    rectsOverlap = rectsOverlap,
    strokeDrawWidth = strokeDrawWidth,
    strokeBBox = strokeBBox,
    snapshotFits = snapshotFits,
    unionRect = unionRect,
}
