--[[--
Pencil plugin for KOReader.
Enables freehand drawing and annotation with stylus on supported devices.

@module koplugin.pencil
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local PencilGeometry = require("lib/geometry")
local PencilToolbar = require("lib/toolbar")
local Screen = Device.screen
local Size = require("ui/size")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local ffiUtil = require("ffi/util")
local T = ffiUtil.template
local time = require("ui/time")

-- Check if device supports touch input
if not Device:isTouchDevice() then
    return { disabled = true }
end

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

-- Module-level reference to the most recently initialized Pencil instance.
-- Used by the bookmark-list hook (a class-level monkey-patch installed once)
-- to find the live plugin without coupling to KOReader internals.
local _active_pencil = nil
local _bookmark_hook_installed = false

local Pencil = InputContainer:extend{
    name = "pencil_annotation",
    is_doc_only = true,  -- Only available when a document is open
    current_stroke = nil,
    strokes = nil,       -- All strokes for current document
    current_tool = TOOL_PEN,
    touch_zones_registered = false,
    undo_stack = {},     -- For undo functionality
    eraser_tool_active = false,  -- Track if physical eraser end is in use (via BTN_TOOL_RUBBER)
    eraser_button_active = false,  -- Hardware eraser button held
    eraser_button_deleted = {},    -- Track deletions for undo
    -- Text-highlight state: true while a side-button + pen-drag is building a
    -- KOReader text-highlight selection via ReaderHighlight. Sticky through
    -- pen lift so releasing the side button mid-drag doesn't abort.
    highlighting = false,

    -- Stylus callback for lowest latency (via Input:registerStylusCallback)
    stylus_callback_registered = false,
    pen_down = false,
    erasing = false,  -- Track if currently in erase mode (for finger modifier)
    pen_x = 0,
    pen_y = 0,

    last_refresh_time = 0,
    refresh_interval_ms = 16,  -- Refresh at most every 16ms during drawing (~60fps)
    dirty_region = nil,  -- Accumulated dirty region for batch refresh

    -- Delayed refresh - only refresh after user stops writing
    pending_refresh = nil,
    refresh_delay_ms = 600, -- Wait 600ms after last stroke before final refresh

    -- Save-on-event policy: persistent disk write only on page change /
    -- doc close, not per-stroke. strokes_dirty is set whenever something
    -- mutates self.strokes and cleared on save. flushDeferredWork keys
    -- off this flag.
    strokes_dirty = false,
    pending_save = nil,   -- legacy field; cancelPendingSave still touches it
    save_delay_ms = 1500, -- unused now, kept for setting back-compat
    dirty_groups = nil, -- Set of groups awaiting syncGroupBookmark (id -> group)

    -- Tool settings
    tool_settings = {
        [TOOL_PEN] = {
            width = 3,
            color = nil,  -- Blitbuffer color, set in init
            color_name = "Black",  -- For persistence and display
            alpha = 255,
        },
        [TOOL_HIGHLIGHTER] = {
            width = 20,
            color = nil,  -- Set in init (needs Blitbuffer)
            alpha = 128,
        },
        [TOOL_ERASER] = {
            width = 20,
        },
    },

    -- Side button state
    side_button_down = false,
    side_button_used_for_highlight = false,  -- Track if button was used during a stroke

    -- Color picker state (triggered by holding pen within 5 pixels for 5 seconds)
    color_picker_start_x = nil,  -- Initial X position when pen touched down
    color_picker_start_y = nil,  -- Initial Y position when pen touched down
    color_picker_start_time = nil,  -- Timestamp when pen touched down (nil if moved too far)
    color_picker_check_pending = nil,  -- Scheduled periodic check
    color_picker_showing = false,  -- Whether color picker is currently displayed

    -- Available colors for the pen (initialized in init() with actual Blitbuffer colors)
    available_colors = {},
}

function Pencil:init()
    -- CRITICAL: Add plugin to ReaderUI widget tree so it receives ALL key events
    -- This ensures we catch Eraser button press/release events
    -- Technique borrowed from eraser.koplugin by SimonLiu <simonliu423@gmail.com>
    table.insert(self.ui, self)                -- Add to widget children for event propagation
    table.insert(self.ui.active_widgets, self) -- Always receive events even when hidden

    self.ui.menu:registerToMainMenu(self)
    self.strokes = {}
    self.page_strokes = {}  -- Index: page -> array of stroke indices
    self.annotation_groups = {}  -- Annotation groups for bookmark integration
    self.strokes_loaded = false  -- Set true after successful loadStrokes
    self.undo_stack = {}
    self.redo_stack = {}
    self.notes = {}

    -- Initialize highlighter color (yellow)
    self.tool_settings[TOOL_HIGHLIGHTER].color = Blitbuffer.Color8(0xDD)  -- Light gray for e-ink

    -- Calculate gray value from highlight_lighten_factor setting
    local lighten_factor = G_reader_settings:readSetting("highlight_lighten_factor") or 0.2
    local gray_value = math.floor(255 * (1 - lighten_factor))

    -- Available colors for color picker (Blitbuffer color values)
    self.available_colors = {
        { name = "Black", color = Blitbuffer.COLOR_BLACK },
        { name = "Red", color = Blitbuffer.ColorRGB32(0xFF, 0x33, 0x00, 0xFF) },
        { name = "Orange", color = Blitbuffer.ColorRGB32(0xFF, 0x88, 0x00, 0xFF) },
        { name = "Yellow", color = Blitbuffer.ColorRGB32(0xFF, 0xFF, 0x33, 0xFF) },
        { name = "Green", color = Blitbuffer.ColorRGB32(0x00, 0xAA, 0x66, 0xFF) },
        { name = "Olive", color = Blitbuffer.ColorRGB32(0x88, 0xFF, 0x77, 0xFF) },
        { name = "Cyan", color = Blitbuffer.ColorRGB32(0x00, 0xFF, 0xEE, 0xFF) },
        { name = "Blue", color = Blitbuffer.ColorRGB32(0x00, 0x66, 0xFF, 0xFF) },
        { name = "Purple", color = Blitbuffer.ColorRGB32(0xEE, 0x00, 0xFF, 0xFF) },
        { name = "Gray", color = Blitbuffer.Color8(gray_value) },
    }

    -- Available pen widths for the optional experimental width picker.
    -- Gated by self.experimental_pen_width; see loadSettings().
    self.available_widths = {
        { name = "w3", width = 3 },
        { name = "w5", width = 5 },
        { name = "w7", width = 7 },
        { name = "w9", width = 9 },
    }

    -- Load tool and stylus button settings
    self:loadSettings()

    -- Floating Scribe-style toolbar (painted in paintTo, hit-tested on input)
    self.toolbar = PencilToolbar.new(Screen, self.path .. "/icons")
    self.toolbar.expanded = self.toolbar_expanded
    self.toolbar.fx, self.toolbar.fy = self.toolbar_fx, self.toolbar_fy
    self.toolbar.transparent_handle = self.toolbar_transparent
    self.toolbar.layout = {
        "pen", "highlighter", "eraser", "lasso", "pointer", "sep", "note", "undo", "redo", "more",
    }
    self.toolbar.flyout_provider = function(kind)
        return self:getFlyoutRows(kind)
    end
    -- Pen side button: short press shows/hides the toolbar
    self:installStylusButtonHook()
    -- Pen pressure for fountain pen and pencil
    self:installPressureHook()

    -- Kindle: KOReader doesn't map the pen's side button to a key, so the
    -- quick-press tool menu would never fire. Map BTN_STYLUS (331) and
    -- BTN_STYLUS2 (332); onKeyPress matches any key name containing "Stylus".
    if Device:isKindle() and Device.input and Device.input.event_map then
        local event_map = Device.input.event_map
        if not event_map[331] then event_map[331] = "Stylus" end
        if not event_map[332] then event_map[332] = "Stylus2" end
    end

    -- Ensure pen color has a default value (black) if not set
    if not self.tool_settings[TOOL_PEN].color then
        self.tool_settings[TOOL_PEN].color = Blitbuffer.COLOR_BLACK
        self.tool_settings[TOOL_PEN].color_name = "Black"
    end

    -- Register as view module to render strokes
    self.view = self.ui.view
    self.view:registerViewModule("pencil_strokes", self)

    -- Try to load strokes now if doc_settings is ready
    -- (backup: they'll also be loaded in onReaderReady/onReadSettings)
    if self.ui.doc_settings and self.ui.doc_settings.doc_sidecar_dir then
        logger.info("Pencil: doc_settings available in init, loading strokes")
        self:loadStrokes()
    else
        logger.info("Pencil: doc_settings not ready in init, will load in onReaderReady")
    end

    -- Check if plugin is enabled globally and auto-setup
    if self:isPluginOn() then
        self:setupPenInput()
    end

    -- Initialize debug logging (if debug mode enabled)
    self:initDebugLog()

    -- Register custom actions for gesture mapping
    Dispatcher:registerAction("pencil_toggle_tool", {
        category = "none",
        event = "PencilToggleTool",
        title = _("Pencil: toggle pencil/eraser"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_toggle_enabled", {
        category = "none",
        event = "PencilToggleEnabled",
        title = _("Pencil: toggle on/off"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_select_pen", {
        category = "none",
        event = "PencilSelectPen",
        title = _("Pencil: select pencil"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_select_eraser", {
        category = "none",
        event = "PencilSelectEraser",
        title = _("Pencil: select eraser"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_undo", {
        category = "none",
        event = "PencilUndo",
        title = _("Pencil: undo"),
        reader = true,
        separator = true,
    })

    -- Per-instance state for the annotation-image feature
    self.pending_image_captures = {}
    self.image_data_dirty = false
    _active_pencil = self

    -- Install the (class-level, one-time) bookmark list hook so taps on
    -- pencil bookmarks open the saved image.
    self:installBookmarkHook()

    logger.info("Pencil: initialized, enabled =", self:isPluginOn(), "tool =", self.current_tool, "strokes =", #self.strokes)
end

-- Dispatcher event handlers (for custom gesture mapping)
function Pencil:onPencilToggleTool()
    if self.current_tool == TOOL_ERASER then
        self.current_tool = TOOL_PEN
    else
        self.current_tool = TOOL_ERASER
    end
    local display_name = self.current_tool == TOOL_PEN and _("pencil") or _("eraser")
    UIManager:show(InfoMessage:new{
        text = T(_("Tool: %1"), display_name),
        timeout = 1,
    })
    return true
end

function Pencil:onPencilToggleEnabled()
    local enabled = self:isPluginOn()
    self:setEnabled(not enabled)
    if self:isPluginOn() then
        self:setupPenInput()
        UIManager:show(InfoMessage:new{
            text = _("Pencil enabled"),
            timeout = 1,
        })
    else
        self:teardownPenInput()
        UIManager:show(InfoMessage:new{
            text = _("Pencil disabled"),
            timeout = 1,
        })
    end
    return true
end

function Pencil:onPencilSelectPen()
    self.current_tool = TOOL_PEN
    UIManager:show(InfoMessage:new{
        text = _("Pencil tool: pencil"),
        timeout = 1,
    })
    return true
end

function Pencil:onPencilSelectEraser()
    self.current_tool = TOOL_ERASER
    UIManager:show(InfoMessage:new{
        text = _("Eraser selected"),
        timeout = 1,
    })
    return true
end

function Pencil:onPencilUndo()
    self:undoLastStroke()
    return true
end

-- Setup stylus callback for lowest latency pen capture
-- ---------------------------------------------------------------------------
-- Error isolation. Pen events, repaints, gestures and scheduled callbacks all
-- run inside KOReader's main loop, where an uncaught Lua error kills the app.
-- Everything we hook into goes through these guards instead.
-- ---------------------------------------------------------------------------

local ERROR_WINDOW_S = 10
local ERROR_LIMIT = 5

-- Log an error (each distinct message once per session, to keep the log small)
function Pencil:reportError(where, err)
    self._seen_errors = self._seen_errors or {}
    local key = where .. ":" .. tostring(err)
    if not self._seen_errors[key] then
        self._seen_errors[key] = true
        -- The reporter itself must never throw
        pcall(logger.err, "Pencil: error in", where, ":", tostring(err), debug.traceback("", 2))
    end
end

-- Stylus callback wrapper. On error: drop the half-finished gesture and let
-- the event through to KOReader. Too many errors in a short time: switch the
-- pen hook off for this document (reading keeps working) and say so once.
function Pencil:guardedStylusSlot(input, slot)
    local ok, res = pcall(self.handleStylusSlot, self, input, slot)
    if ok then return res end
    self:reportError("pen input", res)
    pcall(self.resetTransientInput, self)
    local now = os.time()
    local e = self._input_errors
    if not e or now - e.since > ERROR_WINDOW_S then
        e = { since = now, count = 0 }
        self._input_errors = e
    end
    e.count = e.count + 1
    if e.count >= ERROR_LIMIT and not self._input_disabled then
        self._input_disabled = true
        UIManager:nextTick(function()
            pcall(self.teardownStylusCallback, self)
            UIManager:show(InfoMessage:new{
                text = _("Pencil: pen input stopped after repeated errors. Reopen the book to retry. Details are in crash.log."),
                timeout = 5,
            })
        end)
    end
    return false
end

-- registerTouchZones, with every handler error-isolated (false = not handled,
-- so the gesture falls through to KOReader instead of crashing it)
function Pencil:registerZonesSafely(zones)
    for _, zone in ipairs(zones) do
        if zone.handler then
            zone.handler = self:guard("gesture " .. tostring(zone.id), zone.handler, false)
        end
    end
    self.ui:registerTouchZones(zones)
end

-- UIManager:nextTick with error isolation
function Pencil:defer(fn)
    UIManager:nextTick(function()
        local ok, err = pcall(fn)
        if not ok then self:reportError("deferred", err) end
    end)
end

-- Wrap a function so errors are logged instead of crashing the main loop.
-- Returns `fallback` on error (false for gesture handlers = "not handled").
function Pencil:guard(where, fn, fallback)
    return function(...)
        local ok, res = pcall(fn, ...)
        if ok then return res end
        self:reportError(where, res)
        return fallback
    end
end

-- Drop every half-finished pen/finger gesture and the buffers they hold.
-- Used when a lift event may have been lost (overlay, error, suspend) and on
-- page/screen changes. An unfinished pen stroke is committed, not discarded,
-- unless keep_pen is set (the caller handles current_stroke itself).
function Pencil:resetTransientInput(keep_pen)
    self.stylus_contact = false
    self.toolbar_pending = false
    self.toolbar_pen_action = nil
    self.note_touch = nil
    self.side_btn_down = nil
    for _, key in ipairs({ "toolbar_drag", "finger_drag", "lasso_move" }) do
        local g = self[key]
        if g and g.snap then
            self:releaseSnapshotBuffer(g.snap)
            g.snap = nil
        end
        self[key] = nil
    end
    if self.lasso_path then
        self.lasso_path = nil
        UIManager:setDirty(self.ui.dialog or self.ui, "ui")
    end
    self.lasso_active = nil
    if self.erasing or self.erase_total or self.erase_region or self.erase_snapshot then
        pcall(self.abortErase, self)
    end
    self.erasing = false
    if self.pen_down and not keep_pen then
        self.pen_down = false
        pcall(self.endRawStroke, self)
    end
end

-- Uses the new Input:registerStylusCallback() API that intercepts stylus events
-- before they reach the gesture detector
function Pencil:setupStylusCallback()
    if self.stylus_callback_registered then return end

    local Input = Device.input
    if not Input or not Input.registerStylusCallback then
        logger.warn("Pencil: stylus callback API not available")
        return
    end

    local plugin = self

    -- Register the stylus callback
    -- Callback receives: input (Input object), slot (table with slot, id, x, y, tool, timev)
    -- Return true to "dominate" (remove from gesture detection)
    Input:registerStylusCallback(function(input, slot)
        return plugin:guardedStylusSlot(input, slot)
    end)

    self.stylus_callback_registered = true
    self:setupSonyDhw()
    logger.info("Pencil: stylus callback registered")
end

-- Sony DPT: instead of routing the stroke through Lua + KOReader's render
-- path, hand it off to the Java StylusView overlay (ported from sony_draw).
-- That view owns: the SurfaceView, DHW, and the RenderingThread that locks
-- the canvas in Sony's DU/GC16 EPD modes — i.e. the exact path sony_draw
-- uses to get sub-50ms ink-under-pen latency. Lua just drains completed
-- strokes from the overlay and persists them.
-- Sony DPT setup: enable Direct Handwriting (kernel-fast pen preview) and
-- mark the plugin so addRawPoint switches its mid-stroke refresh from
-- refreshUI (GC16, ~450ms) to refreshFast (DU, ~120ms). Pencil's own Lua
-- paintRectRGB32 → ANativeWindow blit is what makes the ink stick; DHW is
-- the optional sub-50ms "ink under the pen" preview on top.
function Pencil:setupSonyDhw()
    if not Device:isAndroid() then return end
    local ok, android = pcall(require, "android")
    if not ok or not android then return end
    if not android.stylusDhwAvailable or not android.stylusDhwAvailable() then
        logger.info("Pencil: Sony DHW unavailable")
        return
    end
    local tool_settings = self.tool_settings[TOOL_PEN] or {}
    local pen_width = math.max(1, math.floor(tool_settings.width or 3))
    local rotation = Screen:getRotationMode()
    local rotation_deg = (rotation == 1 or rotation == 3) and 90 or 0
    android.stylusDhwSetArea(0, 0, Screen:getWidth(), Screen:getHeight(),
                             pen_width, rotation_deg)
    android.stylusDhwEnable()
    -- StylusView's per-segment NOCONVERT_DU draw uses its own pen width;
    -- sync it to the pencil tool width so the live preview matches the
    -- final stroke baked into the page.
    if android.stylusOverlaySetPenWidth then
        android.stylusOverlaySetPenWidth(pen_width)
    end
    self.sony_dhw_active = true
    logger.info("Pencil: Sony DHW enabled, pen=", pen_width, "rot=", rotation_deg)
end

function Pencil:teardownSonyDhw()
    if not self.sony_dhw_active then return end
    local ok, android = pcall(require, "android")
    if ok and android then
        if android.stylusDhwDisable then android.stylusDhwDisable() end
        if android.stylusDhwClearArea then android.stylusDhwClearArea() end
    end
    self.sony_dhw_active = false
    logger.info("Pencil: Sony stylus overlay disabled")
end

-- Convert "x1,y1,x2,y2,..." -> a stroke record matching the plugin's schema,
-- append it, draw it into Screen.bb (so KOReader's framebuffer keeps the
-- ink even after SurfaceFlinger swaps the overlay's transient buffers),
-- and trigger a partial EPD refresh of just the stroke bounding box.
function Pencil:onSonyOverlayStroke(s)
    local page = self:getCurrentPage()
    local tool = self.current_tool
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]
    local points = {}
    local minx, miny, maxx, maxy
    for sx, sy in s:gmatch("(-?%d+),(-?%d+)") do
        local x, y = tonumber(sx), tonumber(sy)
        table.insert(points, { x = x, y = y })
        if not minx or x < minx then minx = x end
        if not maxx or x > maxx then maxx = x end
        if not miny or y < miny then miny = y end
        if not maxy or y > maxy then maxy = y end
    end
    if #points == 0 then return end
    local stroke = {
        page = page,
        vkey = self:getViewKey(),
        tool = tool,
        points = points,
        width = tool_settings.width,
        color = tool_settings.color,
        color_name = tool_settings.color_name,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }
    table.insert(self.strokes, stroke)
    self:indexStroke(#self.strokes, page)
    self:pushUndo({ type = "add", stroke_idx = #self.strokes })
    self:assignStrokeToGroup(#self.strokes)
    self:scheduleDeferredWork()

    -- Paint into Screen.bb so the ink is in KOReader's persistent buffer.
    -- (The Java overlay shows real-time ink but its SurfaceView buffers are
    -- transient — SurfaceFlinger can swap them out and leave the screen
    -- blank in that area. Baking into Screen.bb makes the ink survive.)
    local width = tool_settings.width
    local color = tool_settings.color
    local half_w = math.floor(width / 2)
    if #points == 1 then
        Screen.bb:paintRectRGB32(points[1].x - half_w, points[1].y - half_w,
                                 width, width, color)
    else
        for i = 1, #points - 1 do
            self:drawLineSegment(Screen.bb,
                points[i].x, points[i].y,
                points[i + 1].x, points[i + 1].y,
                width, color)
        end
    end
    -- Flush the bbox to the screen via Sony's DU partial refresh.
    local pad = width + 4
    local rx = math.max(0, math.floor(minx - pad))
    local ry = math.max(0, math.floor(miny - pad))
    local rw = math.min(Screen:getWidth() - rx,  (maxx - minx) + pad * 2)
    local rh = math.min(Screen:getHeight() - ry, (maxy - miny) + pad * 2)
    Screen:refreshFast(rx, ry, rw, rh)
    logger.dbg("Pencil: Sony overlay stroke captured,", #points,
               "points  refresh=", rx, ry, rw, rh)
end

-- Transform stylus coordinates based on screen rotation
-- Raw stylus coordinates are in hardware space; framebuffer expects logical (rotated) space
function Pencil:transformCoordinates(x, y)
    local rotation = Screen:getRotationMode()
    return PencilGeometry.transformForRotation(x, y, rotation, Screen:getWidth(), Screen:getHeight())
end


-- Handle a stylus slot from the callback
-- slot = {slot=N, id=N, x=N, y=N, tool=N, timev=timestamp}
-- id >= 0 means contact active, id == -1 means contact lifted
-- Entry point for every pen event. After a lift, anything still open is
-- closed: the lift goes to the handler of the tool that is active NOW, so a
-- tool switch during the contact (finger on the toolbar, eraser end, side
-- button) used to leave the previous tool's gesture open, and the next
-- touch-down was swallowed or joined to it.
function Pencil:handleStylusSlot(input, slot)
    local res = self:dispatchStylusSlot(input, slot)
    if slot.id == nil or slot.id < 0 then
        self:afterLift(slot)
    end
    return res
end

function Pencil:afterLift(slot)
    if self.lasso_active then
        self:handleLassoSlot(slot)   -- finishes the loop / move
    end
    self.note_touch = nil
    if self.pen_down then
        self.pen_down = false
        if self.erasing then
            self.erasing = false
            self:finishErase()
            if self.eraser_deleted and #self.eraser_deleted > 0 then
                self:pushUndo({ type = "delete", strokes = self.eraser_deleted })
                self:scheduleDeferredWork()
            end
            self.eraser_deleted = nil
        else
            self:endRawStroke()
        end
    end
    -- Whatever path an erase took (pen eraser, eraser end, side button,
    -- switched mid-contact), nothing of it outlives the contact
    if self.erase_snapshot or self.erase_total or self.erase_region or self.erase_flush_scheduled then
        self:finishErase()
    end
end

function Pencil:dispatchStylusSlot(input, slot)
    -- Tool types from Linux input subsystem
    local TOOL_TYPE_PEN = 1
    local TOOL_TYPE_ERASER = 2
    local TOOL_TYPE_HIGHLIGHTER = 3

    -- Debug logging at the very start to see slot.tool
    if self.input_debug_mode then
        self:writeDebugLog(string.format("STYLUS SLOT: id=%d x=%d y=%d tool=%d eraser_active=%s",
            slot.id or -1, slot.x or 0, slot.y or 0, slot.tool or -1,
            tostring(self.eraser_button_active)))
    end

    -- Don't capture pen input when a menu or overlay is on top of the reader.
    -- But a lift still has to end whatever we were tracking: an overlay that
    -- opens mid-contact (e.g. the "cleared" message after "Seite löschen")
    -- would otherwise leave us mid-gesture, and the next touch-down would be
    -- swallowed or joined to the old stroke.
    if self:isOverlayActive() then
        if slot.id == nil or slot.id < 0 then
            self:resetTransientInput()
        end
        return false
    end

    -- Toolbar: a pen contact that *starts* on the toolbar is a button press.
    -- Buttons fire right away on touch-down; the handle fires on lift (tap =
    -- collapse/expand) or moves the toolbar if the pen is dragged. The rest
    -- of such a contact is swallowed until lift, so it never draws and never
    -- reaches the gesture detector. Works in pointer mode too.
    -- On Kindle (Wacom protocol) BTN_TOUCH can arrive in its own input frame
    -- without coordinates, so the hit-test waits for the first frame that
    -- has x/y instead of testing a bogus (0,0).
    local contact = slot.id ~= nil and slot.id >= 0
    if contact and self.side_btn_down then
        -- Side button held while touching = eraser use, not a toolbar toggle
        self.side_btn_contact = true
    end
    if contact and not self.stylus_contact then
        self.stylus_contact = true
        self.toolbar_pending = not self.pen_down
    elseif not contact then
        self.stylus_contact = false
        self.toolbar_pending = false
        if self.toolbar_drag then
            local drag = self.toolbar_drag
            self.toolbar_drag = nil
            self.toolbar_pen_action = nil
            self:defer(function()
                self:endToolbarDrag(drag)
            end)
            return true
        end
        if self.toolbar_pen_action then
            self.toolbar_pen_action = nil
            return true
        end
    end
    if self.toolbar_pending then
        if slot.x == nil or slot.y == nil then
            return true  -- no position yet: wait for the next frame
        end
        self.toolbar_pending = false
        local tx, ty = self:transformCoordinates(slot.x, slot.y)
        local hit = self:toolbarHitTest(tx, ty)
        if self.input_debug_mode then
            self:writeDebugLog(string.format("TOOLBAR TEST raw=(%d,%d) screen=(%d,%d) hit=%s",
                slot.x, slot.y, tx, ty, tostring(hit)))
        end
        if hit == "handle" then
            self.toolbar_pen_action = hit
            self.toolbar_drag = self:beginToolbarDrag(tx, ty)
            return true
        elseif hit then
            self.toolbar_pen_action = hit
            self:defer(function()
                self:onToolbarAction(hit)
            end)
            return true
        elseif self:isFlyoutOpen() then
            -- Touching the page while a menu is open just closes the menu
            self.toolbar_pen_action = "dismiss"
            self:defer(function()
                self:closeFlyout()
            end)
            return true
        end
    end
    if self.toolbar_drag then
        if contact and slot.x and slot.y then
            local tx, ty = self:transformCoordinates(slot.x, slot.y)
            self:updateToolbarDrag(self.toolbar_drag, tx, ty)
        end
        return true
    end
    if self.toolbar_pen_action then
        return true
    end

    -- Side button shortcut tool. KOReader turns a pen with the side button
    -- held into an "eraser" (slot.tool == 2). Unless the shortcut is the
    -- eraser, undo that here and remember which tool this contact uses.
    -- The choice is made at touch-down and kept until the pen lifts.
    local side_tool = self:resolveSideButton(slot)

    -- Pen contact while the side button is held = button used as eraser,
    -- so its release must not open the tool menu.
    if self.side_button_down and slot.id and slot.id >= 0 then
        self.side_button_used_for_highlight = true
    end

    -- Detect eraser end via slot.tool BEFORE key events arrive
    -- This handles the timing issue where stylus callback fires before key events
    if ((self.swap_eraser_and_highlighter and slot.tool == TOOL_TYPE_HIGHLIGHTER) or (not self.swap_eraser_and_highlighter and slot.tool == TOOL_TYPE_ERASER)) and not self.eraser_button_active then
        logger.info("Pencil: Eraser end detected via slot.tool, activating eraser mode")
        self.eraser_button_active = true
        self.eraser_button_deleted = {}
    elseif ((self.swap_eraser_and_highlighter and not (slot.tool == TOOL_TYPE_HIGHLIGHTER)) or (not self.swap_eraser_and_highlighter and not (slot.tool == TOOL_TYPE_ERASER))) and self.eraser_button_active then
        -- Switched from eraser end to pen tip
        logger.info("Pencil: Pen tip detected via slot.tool, deactivating eraser mode")
        if self.eraser_button_deleted and #self.eraser_button_deleted > 0 then
            self:pushUndo({ type = "delete", strokes = self.eraser_button_deleted })
            self:scheduleDeferredWork()  -- written on page change / close / suspend / autosave
        end
        self.eraser_button_active = false
        self.eraser_button_deleted = nil
        UIManager:setDirty(self.view, "ui")
    end

    -- Eraser mode (from eraser end or hardware button) - works even if pencil disabled
    if self.eraser_button_active then
        if slot.id and slot.id >= 0 then
            -- No position in this frame yet (Wacom touch-down): nothing to erase
            if slot.x == nil or slot.y == nil then return true end
            local x, y = self:transformCoordinates(slot.x, slot.y)
            local page = self:getCurrentPage()
            local deleted = self:eraseAlong(self.erase_prev_x, self.erase_prev_y, x, y, page)
            self.erase_prev_x, self.erase_prev_y = x, y
            if deleted then
                self.eraser_button_deleted = self.eraser_button_deleted or {}
                for _, stroke in ipairs(deleted) do
                    table.insert(self.eraser_button_deleted, stroke)
                end
                self:queueEraseRefresh(deleted)
            end
            -- Also remove any native KOReader text highlight at this position.
            -- removeItemByIndex emits AnnotationsModified and triggers its own
            -- repaint, so we don't need to mirror the refreshFast call above.
            self:eraseHighlightAtScreenPos(x, y)
            self.pen_x = x
            self.pen_y = y
        else
            self:finishErase()
        end
        return true
    end

    -- Native text-highlight path: runs before any draw/stroke logic.
    -- When input.lua has promoted slot.tool to HIGHLIGHTER (side button held),
    -- route pen events through KOReader's ReaderHighlight instead of creating
    -- a freehand stroke. Sticky: once we enter, we stay until pen lift even
    -- if the side button is released mid-drag.
    -- Also used while "Mark text" is selected in the side-button tool menu.
    if (self.experimental_text_highlight and slot.tool == TOOL_TYPE_HIGHLIGHTER)
            or self.highlighting
            or (self.textmark_mode and self:isEnabled()) then
        local current_slot_id = slot.id or -1
        if current_slot_id >= 0 and not self.highlighting then
            self:startTextHighlight(slot.x or 0, slot.y or 0)
        elseif current_slot_id >= 0 and self.highlighting then
            self:extendTextHighlight(slot.x or 0, slot.y or 0)
        elseif current_slot_id < 0 and self.highlighting then
            self:finishTextHighlight()
        end
        return true
    end

    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Log in debug mode
    if self.input_debug_mode then
        self:writeDebugLog(string.format("STYLUS: slot=%d id=%d x=%d y=%d tool=%d pen_down=%s tool=%s",
            slot.slot or -1, slot.id or -1, slot.x or 0, slot.y or 0, slot.tool or -1,
            tostring(self.pen_down), self.current_tool))
    end

    -- Determine effective tool:
    -- 1. Physical eraser end via slot.tool (TOOL_TYPE_ERASER = 2) takes priority
    -- 2. Physical eraser end via BTN_TOOL_RUBBER key event (eraser_tool_active) as backup
    -- 3. Otherwise use selected tool (user can toggle via gesture)
    local TOOL_TYPE_ERASER = 2
    local effective_tool
    if (self.swap_eraser_and_highlighter and slot.tool == TOOL_TYPE_HIGHLIGHTER) or (not self.swap_eraser_and_highlighter and slot.tool == TOOL_TYPE_ERASER) or self.eraser_tool_active then
        effective_tool = TOOL_ERASER
        if self.input_debug_mode and slot.tool == TOOL_TYPE_ERASER then
            self:writeDebugLog(string.format("ERASER END detected via slot.tool=%d", slot.tool))
        end
    else
        effective_tool = self.current_tool
    end
    local stroke_tool, stroke_pen_type
    if side_tool then
        effective_tool, stroke_pen_type = self:sideButtonEffectiveTool(side_tool)
        stroke_tool = effective_tool
    end

    -- Lasso and sticky notes have their own pen handling
    if effective_tool == TOOL_LASSO then
        return self:handleLassoSlot(slot)
    elseif effective_tool == TOOL_NOTE then
        return self:handleNoteSlot(slot)
    end

    -- Handle eraser mode
    if effective_tool == TOOL_ERASER then
        if self.input_debug_mode and not self.erasing then
            self:writeDebugLog(string.format("ERASER MODE: pen_down=%s slot.id=%d",
                tostring(self.pen_down), slot.id or -1))
        end
        if slot.id and slot.id >= 0 then
            -- Eraser is touching - erase at this position
            local first_touch = false
            if not self.pen_down or not self.erasing then
                if self.pen_down then
                    -- Switched from writing to erasing within one contact
                    -- (eraser end, side button, toolbar): finish the stroke
                    self:endRawStroke()
                end
                self.pen_down = true
                self.erasing = true
                self.eraser_deleted = {}
                first_touch = true
                if self.input_debug_mode then
                    self:writeDebugLog("=== ERASER DOWN ===")
                end
            end

            -- No position in this frame yet (Wacom touch-down): wait for one,
            -- rather than erasing at the previous stroke's last position.
            if slot.x == nil or slot.y == nil then return true end
            local x, y = self:transformCoordinates(slot.x, slot.y)
            -- Erase on first touch OR when position changes
            if first_touch or x ~= self.pen_x or y ~= self.pen_y then
                local page = self:getCurrentPage()
                if self.input_debug_mode then
                    self:writeDebugLog(string.format("ERASE ATTEMPT at (%d, %d) page=%s erasing=%s",
                        x, y, tostring(page), tostring(self.erasing)))
                end
                local deleted = self:eraseAlong(self.erase_prev_x, self.erase_prev_y, x, y, page)
                self.erase_prev_x, self.erase_prev_y = x, y
                if deleted then
                    self.eraser_deleted = self.eraser_deleted or {}
                    for _, stroke in ipairs(deleted) do
                        table.insert(self.eraser_deleted, stroke)
                    end
                    -- Throttled repaint, refreshing only the erased area
                    self:queueEraseRefresh(deleted)
                    if self.input_debug_mode then
                        self:writeDebugLog(string.format("ERASED %d strokes at (%d, %d)", #deleted, x, y))
                    end
                end
                self.pen_x = x
                self.pen_y = y
            end
        else
            -- Eraser lifted
            if self.pen_down and self.erasing then
                self.pen_down = false
                self.erasing = false
                self:finishErase()
                if self.eraser_deleted and #self.eraser_deleted > 0 then
                    self:pushUndo({ type = "delete", strokes = self.eraser_deleted })
                    self:scheduleDeferredWork()  -- written on page change / close / suspend / autosave
                end
                self.eraser_deleted = nil
                UIManager:setDirty(self.view, "ui")
                if self.input_debug_mode then
                    self:writeDebugLog("=== ERASER UP ===")
                end
            end
        end
        return true  -- Dominate: remove from gesture detection
    end

    -- Handle pen/highlighter mode
    if slot.id and slot.id >= 0 then
        -- Pen down or moving
        if self.pen_down and self.erasing then
            -- Switched from erasing to writing within one contact: close the
            -- erase (undoable, buffers released), then start a fresh stroke
            self:afterLift({ id = -1 })
        end
        if not self.pen_down then
            -- Check if color picker is showing - route pen tap to it
            if self.color_picker_showing and self.color_picker_widget then
                local raw_x = slot.x or 0
                local raw_y = slot.y or 0
                local x, y = self:transformCoordinates(raw_x, raw_y)
                if self.color_picker_widget:handlePenTap(x, y) then
                    -- Color picker handled the tap, don't start a stroke
                    return true
                end
            end

            -- Start new stroke
            self.pen_down = true
            self.erasing = false
            self:cancelPendingRefresh()
            self:cancelColorPickerTimer()
            self:startRawStroke(stroke_tool, stroke_pen_type)
            if slot.x == nil or slot.y == nil then
                -- Wacom touch-down frame without a position: the first point
                -- is added when coordinates arrive (see "Pen is moving").
                self.pen_x, self.pen_y = nil, nil
                self.pen_raw_x, self.pen_raw_y = nil, nil
                return true
            end
            -- Record the touch-down point itself, so a tap leaves a dot
            self.pen_raw_x, self.pen_raw_y = slot.x, slot.y
            local x, y = self:transformCoordinates(slot.x, slot.y)
            self.pen_x = x
            self.pen_y = y
            self:addRawPoint(x, y)
            -- Only track picker state and schedule the 10Hz poll when the
            -- hold-pen-still gesture would actually produce something to
            -- show. Skipping these when both experimental pickers are off
            -- avoids an UIManager:scheduleIn closure allocation on every
            -- pen-down — real GC pressure on the A53 during multi-second
            -- strokes.
            if self.experimental_color_picker or self.experimental_pen_width then
                self.color_picker_start_x = x
                self.color_picker_start_y = y
                self.color_picker_start_time = time.now()
                -- Schedule periodic check for color picker trigger
                self:scheduleColorPickerCheck()
            end
            if self.input_debug_mode then
                self:writeDebugLog("=== PEN DOWN ===")
            end
        else
            -- Pen is moving. Missing coordinates fall back to the last RAW
            -- position (falling back to the already-transformed pen_x/pen_y
            -- transformed them twice, i.e. wrong when rotated).
            local raw_x = slot.x or self.pen_raw_x
            local raw_y = slot.y or self.pen_raw_y
            if raw_x == nil or raw_y == nil then return true end
            self.pen_raw_x, self.pen_raw_y = raw_x, raw_y
            local x, y = self:transformCoordinates(raw_x, raw_y)
            if self.pen_x == nil then
                -- First coordinates of a stroke whose touch-down had none
                self.pen_x, self.pen_y = x, y
                self:addRawPoint(x, y)
            elseif x ~= self.pen_x or y ~= self.pen_y then
                -- Check if pen moved more than tolerance from start position
                if self.color_picker_start_x and self.color_picker_start_y then
                    local dx = math.abs(x - self.color_picker_start_x)
                    local dy = math.abs(y - self.color_picker_start_y)
                    if dx > COLOR_PICKER_TOLERANCE_PIXELS or dy > COLOR_PICKER_TOLERANCE_PIXELS then
                        -- Pen moved too far - reset tracking (no color picker)
                        self:resetColorPickerTracking()
                    end
                end
                self:addRawPoint(x, y)
                self.pen_x = x
                self.pen_y = y
            end
        end
    else
        -- Pen lifted (id == -1)
        if self.pen_down and not self.erasing then
            self.pen_down = false
            self:cancelColorPickerTimer()
            self:endRawStroke()
            if self.input_debug_mode then
                self:writeDebugLog("=== PEN UP ===")
            end
        end
    end

    return true  -- Dominate: remove from gesture detection
end

-- Teardown stylus callback
function Pencil:teardownStylusCallback()
    if not self.stylus_callback_registered then return end

    local Input = Device.input
    if Input and Input.unregisterStylusCallback then
        Input:unregisterStylusCallback()
    end

    self:teardownSonyDhw()
    self.stylus_callback_registered = false
    self.pen_down = false
    logger.info("Pencil: stylus callback unregistered")
end

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

-- Paint the in-progress text selection as "invert" rectangles while a
-- highlight drag is active. Mirrors what KOReader does during a normal
-- finger long-press+drag: the reader's paintTo iterates
-- self.view.highlight.temp[page] and inversion-paints each sbox. All we
-- have to do is populate that table with our current sboxes, then
-- setDirty so a repaint runs.
function Pencil:_paintTempSelection()
    if not (self.ui and self.ui.view and self.ui.view.highlight and self.ui.highlight) then
        return
    end
    local rh = self.ui.highlight
    local temp = self.ui.view.highlight.temp
    -- Reset any previous frame's temp entries so stale sboxes from earlier
    -- in the drag don't linger after the selection shrinks.
    for k in pairs(temp) do temp[k] = nil end
    if rh.selected_text and rh.selected_text.sboxes and #rh.selected_text.sboxes > 0 then
        local page_key = rh.hold_pos and rh.hold_pos.page or 1
        temp[page_key] = rh.selected_text.sboxes
    end
    UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
end

-- Clear the in-progress selection preview. Called on pen lift before we
-- persist the selection as a saved highlight (which then paints itself
-- via drawSavedHighlight instead of via temp).
function Pencil:_clearTempSelection()
    if not (self.ui and self.ui.view and self.ui.view.highlight) then return end
    local temp = self.ui.view.highlight.temp
    for k in pairs(temp) do temp[k] = nil end
    UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
end

-- Start a native KOReader text-highlight selection at a raw stylus position.
-- Called from handleStylusSlot when slot.tool has been promoted to HIGHLIGHTER
-- by input.lua (i.e., the side button is held during a pen contact).
--
-- Manipulates self.ui.highlight (ReaderHighlight) directly because there is
-- no public "start programmatic selection" API — the standard entry points
-- (onHold / onHoldPan) do extra work (panel-zoom probing, gesture wiring)
-- that we don't need and that would interact badly with our stylus-sourced
-- events. The methods we do call (getWordFromPosition / getTextFromPositions
-- / saveHighlight) are the same ones KOReader itself invokes internally.
function Pencil:startTextHighlight(raw_x, raw_y)
    if not (self.ui and self.ui.highlight and self.ui.view and self.ui.document) then
        return
    end
    local screen_x, screen_y = self:transformCoordinates(raw_x, raw_y)
    local page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
    if not page_pos then return end  -- Tap outside any page area

    local rh = self.ui.highlight
    rh.hold_pos = page_pos

    local ok, word = pcall(self.ui.document.getWordFromPosition, self.ui.document, page_pos)
    if ok and word and word.pos0 and word.pos1 then
        rh.selected_text = {
            text = word.word or "",
            pos0 = word.pos0,
            pos1 = word.pos1,
            sboxes = word.sbox and { word.sbox } or {},
            pboxes = word.pbox and { word.pbox } or {},
        }
    else
        rh.selected_text = nil
    end

    self.highlighting = true
    -- Prevent the drawing-path pen-down branch from also firing on subsequent
    -- events for this contact.
    self.pen_down = true

    -- Show the first-word preview immediately.
    self:_paintTempSelection()
end

-- Extend the active text-highlight selection to a new raw stylus position.
-- Called on each stylus slot update while self.highlighting is true.
function Pencil:extendTextHighlight(raw_x, raw_y)
    if not (self.ui and self.ui.highlight and self.ui.view and self.ui.document) then
        return
    end
    local rh = self.ui.highlight
    if not rh.hold_pos then return end

    local screen_x, screen_y = self:transformCoordinates(raw_x, raw_y)
    local page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
    if not page_pos then return end
    rh.holdpan_pos = page_pos

    -- getTextFromPositions handles EPUB (xpointer) and PDF (x/y/page) shapes
    -- and returns a selection dict with pos0/pos1/text/sboxes/pboxes.
    local ok, selected = pcall(self.ui.document.getTextFromPositions,
                               self.ui.document, rh.hold_pos, rh.holdpan_pos)
    if ok and selected and selected.pos0 and selected.pos1 then
        rh.selected_text = selected
        -- Repaint preview with the new sboxes.
        self:_paintTempSelection()
    end
end

-- Persist the current selection as a KOReader highlight annotation and reset.
-- Called on slot.id transitioning to -1 (pen lift) while self.highlighting.
function Pencil:finishTextHighlight()
    local rh = self.ui and self.ui.highlight
    local has_selection = rh and rh.selected_text
        and rh.selected_text.pos0 and rh.selected_text.pos1

    -- Clear the in-progress preview first; the saved highlight's own paint
    -- path (drawSavedHighlight) will take over on the next frame.
    self:_clearTempSelection()

    if has_selection then
        -- saveHighlight(false) builds the annotation item from self.selected_text
        -- and calls self.ui.annotation:addItem(item) internally, handling the
        -- PDF/EPUB item-shape difference. It emits AnnotationsModified itself,
        -- so we do NOT emit a second one here — a userpatch may further wrap
        -- this call to prompt for color, but that's not the plugin's concern.
        local ok, err = pcall(rh.saveHighlight, rh, false)
        if not ok then
            logger.warn("Pencil: saveHighlight failed:", tostring(err))
        end
    end

    if rh and rh.clear then
        pcall(rh.clear, rh)
    end

    self.highlighting = false
    self.pen_down = false
end

-- Find the index in self.ui.annotation.annotations of a saved text highlight
-- whose rendered boxes cover screen position (screen_x, screen_y).
-- Returns nil if no highlight is at that position.
-- Used by the eraser path so flipping to the eraser end and swiping across a
-- highlight removes it, the same way it removes freehand strokes.
function Pencil:findHighlightAtScreenPos(screen_x, screen_y)
    if not (self.ui and self.ui.annotation and self.ui.annotation.annotations
            and self.ui.view and self.ui.document) then
        return nil
    end

    local is_paging = self.ui.paging ~= nil
    local page_pos
    if is_paging then
        page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
        if not page_pos then return nil end
    end

    for index, item in ipairs(self.ui.annotation.annotations) do
        -- drawer is nil for page-bookmarks; only text highlights have it set.
        if item.drawer and item.pos0 and item.pos1 then
            local boxes
            if is_paging then
                if item.page == page_pos.page then
                    local ok, got = pcall(self.ui.document.getPageBoxesFromPositions,
                                          self.ui.document, page_pos.page, item.pos0, item.pos1)
                    if ok then boxes = got end
                end
            else
                -- Rolling mode (EPUB): work in screen coordinates directly.
                local ok, got = pcall(self.ui.document.getScreenBoxesFromPositions,
                                      self.ui.document, item.pos0, item.pos1, true)
                if ok then boxes = got end
            end
            if boxes then
                local px = is_paging and page_pos.x or screen_x
                local py = is_paging and page_pos.y or screen_y
                for _, box in ipairs(boxes) do
                    if px >= box.x and px < box.x + box.w
                            and py >= box.y and py < box.y + box.h then
                        return index
                    end
                end
            end
        end
    end
    return nil
end

-- Delete any KOReader text highlight at the given screen position.
-- Used by the eraser pass inside handleStylusSlot. removeItemByIndex emits
-- AnnotationsModified and does the logical cleanup, but on e-ink its
-- setDirty is not strong enough to clear the highlight's painted pixels
-- from the framebuffer — users saw the removed highlight linger until the
-- next page turn forced a full refresh. Force a UI-mode setDirty here so
-- the overlay actually disappears.
function Pencil:eraseHighlightAtScreenPos(screen_x, screen_y)
    local index = self:findHighlightAtScreenPos(screen_x, screen_y)
    if not index then return false end
    if not (self.ui and self.ui.bookmark and self.ui.bookmark.removeItemByIndex) then
        return false
    end
    local ok = pcall(self.ui.bookmark.removeItemByIndex, self.ui.bookmark, index)
    if ok then
        -- The page itself changed: the eraser snapshot no longer matches
        self:freeEraseSnapshot()
        UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
    end
    return ok
end

-- Get the path to the plugin's log file
function Pencil:getDebugLogPath()
    -- Write to KOReader's data directory (always writable)
    local log_dir = DataStorage:getDataDir()
    return log_dir .. "/pencil_input_debug.log"
end

-- Write a line to the debug log file
function Pencil:writeDebugLog(msg)
    if not self.input_debug_mode then return end

    local log_path = self:getDebugLogPath()
    local f = io.open(log_path, "a")
    if f then
        local timestamp = os.date("%H:%M:%S")
        f:write(string.format("[%s] %s\n", timestamp, msg))
        f:close()
    end
end

-- Clear the debug log file
function Pencil:clearDebugLog()
    local log_path = self:getDebugLogPath()
    local f = io.open(log_path, "w")
    if f then
        f:write("=== Pencil Annotation Input Debug Log ===\n")
        f:write("Started: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
        local device_name = "unknown"
        if Device.model then
            device_name = Device.model
        elseif Device.getDeviceName then
            device_name = Device:getDeviceName() or "unknown"
        end
        f:write("Device: " .. device_name .. "\n")
        f:write("==========================================\n\n")
        f:close()
        logger.info("Pencil: cleared debug log at", log_path)
    end
end

-- Initialize debug logging (clear log and write header)
function Pencil:initDebugLog()
    if not self.input_debug_mode then return end
    self:clearDebugLog()
    self:writeDebugLog("Debug logging enabled")
    local Input = Device.input
    if Input then
        self:writeDebugLog("Input.pen_slot = " .. tostring(Input.pen_slot or "nil"))
    end
end

-- Load plugin settings
function Pencil:loadSettings()
    local settings = G_reader_settings:readSetting("pencil_annotation_settings") or {}
    -- Always start with pencil tool when opening a book
    self.current_tool = TOOL_PEN
    -- Input debug mode: log all input details
    self.input_debug_mode = settings.input_debug_mode or false
    -- Experimental features
    self.experimental_bookmark_sync = settings.experimental_bookmark_sync or false
    -- Swap eraser and highlighter
    self.swap_eraser_and_highlighter = settings.swap_eraser_and_highlighter or false
    -- Partial eraser (only erase under the eraser) is the default
    self.partial_eraser = settings.partial_eraser ~= false
    self.experimental_pen_width = settings.experimental_pen_width or false
    self.experimental_color_picker = settings.experimental_color_picker or false
    self.experimental_text_highlight = settings.experimental_text_highlight or false
    -- Floating toolbar: shown by default, remembers collapsed state.
    -- Like the tool itself, every book opens in pen mode (not pointer).
    self.toolbar_shown = settings.toolbar_shown ~= false
    self.toolbar_expanded = settings.toolbar_expanded ~= false
    self.toolbar_fx, self.toolbar_fy = settings.toolbar_fx, settings.toolbar_fy
    self.toolbar_transparent = settings.toolbar_transparent ~= false
    self.side_button_tool = sideButtonToolName(settings.side_button_tool)
        and settings.side_button_tool or SIDE_BUTTON_DEFAULT
    self.tool_settings[TOOL_PEN].pen_type = settings.pen_type or PEN_TYPE_PEN
    if settings.highlighter_width then
        self.tool_settings[TOOL_HIGHLIGHTER].width = settings.highlighter_width
    end
    if settings.eraser_width then
        self.tool_settings[TOOL_ERASER].width = settings.eraser_width
    end
    self.pointer_mode = false
    -- Load pen color by name and look up the actual color value
    local color_name = settings.pen_color_name
    if color_name then
        self.tool_settings[TOOL_PEN].color_name = color_name
        for _, color_info in ipairs(self.available_colors) do
            if color_info.name == color_name then
                self.tool_settings[TOOL_PEN].color = color_info.color
                break
            end
        end
    end
    -- Load pen width if previously chosen via the experimental width picker.
    -- Validated against available_widths so a malformed settings file can't
    -- inject arbitrary widths.
    local saved_width = settings.pen_width
    if saved_width then
        for _, w in ipairs(self.available_widths) do
            if w.width == saved_width then
                self.tool_settings[TOOL_PEN].width = saved_width
                break
            end
        end
    end
end

-- Save plugin settings
function Pencil:saveSettings()
    G_reader_settings:saveSetting("pencil_annotation_settings", {
        input_debug_mode = self.input_debug_mode,
        experimental_bookmark_sync = self.experimental_bookmark_sync,
        experimental_pen_width = self.experimental_pen_width,
        experimental_color_picker = self.experimental_color_picker,
        experimental_text_highlight = self.experimental_text_highlight,
        pen_color_name = self.tool_settings[TOOL_PEN].color_name,
        swap_eraser_and_highlighter = self.swap_eraser_and_highlighter,
        partial_eraser = self.partial_eraser,
        pen_width = self.tool_settings[TOOL_PEN].width,
        toolbar_shown = self.toolbar_shown,
        toolbar_expanded = self.toolbar_expanded,
        toolbar_fx = self.toolbar and self.toolbar.fx or self.toolbar_fx,
        toolbar_fy = self.toolbar and self.toolbar.fy or self.toolbar_fy,
        toolbar_transparent = self.toolbar_transparent,
        side_button_tool = self.side_button_tool,
        highlighter_width = self.tool_settings[TOOL_HIGHLIGHTER].width,
        pen_type = self.tool_settings[TOOL_PEN].pen_type,
        eraser_width = self.tool_settings[TOOL_ERASER].width,
    })
end

-- Set current tool
function Pencil:setTool(tool)
    self.current_tool = tool
    self:saveSettings()
    -- Show visual feedback with proper display name
    local display_name = tool == TOOL_PEN and _("pencil") or _("eraser")
    UIManager:show(InfoMessage:new{
        text = T(_("Tool: %1"), display_name),
        timeout = 1,
    })
end

-- Plugin switched on in the menu (toolbar visible, input hooks installed).
function Pencil:isPluginOn()
    return G_reader_settings:readSetting("pencil_annotation_enabled") == true
end

-- Pen currently draws. False in pointer mode, where the pen acts like a
-- finger (page turns, menus, text selection) but the toolbar stays usable.
function Pencil:isEnabled()
    return self:isPluginOn() and not self.pointer_mode
end

-- Check if a menu or overlay is shown on top of the reader view.
-- When true, pen input should pass through so the overlay can handle it.
function Pencil:isOverlayActive()
    local top = UIManager:getTopmostVisibleWidget()
    if not top then return false end
    -- ReaderUI is the document view itself — anything else is an overlay.
    -- getTopmostVisibleWidget skips widgets marked invisible — transient
    -- decorations that paint but don't capture input, e.g. TrapWidget.
    return (top.name or top.id) ~= "ReaderUI"
end

-- Set enabled state (global setting)
function Pencil:setEnabled(enabled)
    G_reader_settings:saveSetting("pencil_annotation_enabled", enabled)
end

function Pencil:addToMainMenu(menu_items)
    menu_items.pencil_annotation = {
        text = _("Pencil"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Enabled"),
                checked_func = function()
                    return self:isPluginOn()
                end,
                callback = function()
                    self:onPencilToggleEnabled()
                end,
            },
            {
                text = _("Show toolbar"),
                help_text = _("Floating toolbar: pen, highlighter, eraser, pointer (pen acts as a finger), undo, redo. Tap the active tool again for widths. Drag the round handle to move it, tap it to collapse. A short press on the pen's side button shows/hides it."),
                checked_func = function()
                    return self.toolbar_shown
                end,
                callback = function()
                    self:setToolbarShown(not self.toolbar_shown)
                end,
                separator = true,
            },
            {
                text = _("Swap Eraser and Highlighter"),
                checked_func = function()
                    return self.swap_eraser_and_highlighter
                end,
                callback = function()
                    self.swap_eraser_and_highlighter = not self.swap_eraser_and_highlighter
                    self:saveSettings()
                end,
            },
            {
                text = _("Partial eraser"),
                help_text = _("Erase only the part of a stroke under the eraser. When off, touching a stroke erases the whole stroke."),
                checked_func = function()
                    return self.partial_eraser
                end,
                callback = function()
                    self.partial_eraser = not self.partial_eraser
                    self:saveSettings()
                end,
                separator = true,
            },
            {
                text = _("Tool"),
                help_text = _("Select pencil or eraser."),
                sub_item_table = {
                    {
                        text = _("Pencil"),
                        checked_func = function()
                            return self.current_tool == TOOL_PEN
                        end,
                        callback = function()
                            self:setTool(TOOL_PEN)
                        end,
                    },
                    {
                        text = _("Eraser"),
                        checked_func = function()
                            return self.current_tool == TOOL_ERASER
                        end,
                        callback = function()
                            self:setTool(TOOL_ERASER)
                        end,
                    },
                },
            },
            {
                text = _("Undo last stroke"),
                callback = function()
                    self:undoLastStroke()
                end,
                enabled_func = function()
                    return #self.undo_stack > 0
                end,
                separator = true,
            },
            {
                text = _("Clear page strokes"),
                callback = function()
                    self:clearPageStrokes()
                end,
                enabled_func = function()
                    return self:hasStrokesOnCurrentPage()
                end,
            },
            {
                text = _("Clear all strokes"),
                callback = function()
                    self:clearAllStrokes()
                end,
                enabled_func = function()
                    return #self.strokes > 0
                end,
            },
            {
                text_func = function()
                    local bytes = self:getImagesSizeBytes()
                    if bytes <= 0 then
                        return _("Annotation images: none")
                    elseif bytes < 1024 * 1024 then
                        return T(_("Annotation images: %1 KB"), math.floor(bytes / 1024))
                    else
                        return T(_("Annotation images: %1 MB"),
                            string.format("%.1f", bytes / (1024 * 1024)))
                    end
                end,
                help_text = _("Saved preview images of your annotations are used to show what you wrote even after the device is rotated, and to preview annotations from the bookmark list. Tap to clear them for this book."),
                keep_menu_open = true,
                enabled_func = function()
                    return self:getImagesSizeBytes() > 0
                end,
                callback = function(touchmenu_instance)
                    self:purgeAllImages()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                    UIManager:show(InfoMessage:new{
                        text = _("Cleared all annotation preview images for this book."),
                        timeout = 2,
                    })
                end,
                separator = true,
            },
            {
                text = _("Experimental"),
                sub_item_table = {
                    {
                        text = _("Bookmark sync"),
                        help_text = _("Automatically create KOReader bookmarks for pencil annotations so you can navigate to annotated pages from the Bookmarks menu."),
                        checked_func = function()
                            return self.experimental_bookmark_sync
                        end,
                        callback = function()
                            self.experimental_bookmark_sync = not self.experimental_bookmark_sync
                            self:saveSettings()
                            if self.experimental_bookmark_sync then
                                self:syncAllBookmarks()
                                UIManager:show(InfoMessage:new{
                                    text = _("Bookmark sync enabled. Pencil annotations will appear in the Bookmarks menu."),
                                    timeout = 3,
                                })
                            else
                                self:removeAllPencilBookmarks()
                                UIManager:show(InfoMessage:new{
                                    text = _("Bookmark sync disabled. Pencil bookmarks removed."),
                                    timeout = 3,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Color picker"),
                        help_text = _("Allow the hold-pen-still gesture to open a picker for changing pen color (and, if the pen width picker is also enabled, stroke width). When disabled, the pen stays on its last-saved color."),
                        checked_func = function()
                            return self.experimental_color_picker
                        end,
                        callback = function()
                            self.experimental_color_picker = not self.experimental_color_picker
                            self:saveSettings()
                            if self.experimental_color_picker then
                                UIManager:show(InfoMessage:new{
                                    text = _("Color picker enabled. Hold the pen still to open it."),
                                    timeout = 3,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Color picker disabled. Pen will keep its current color."),
                                    timeout = 2,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Pen width picker"),
                        help_text = _("Add pen width options (3, 5, 7, 9) to the color picker. The width buttons appear as black bars whose height previews the stroke thickness. Requires the color picker to also be enabled."),
                        checked_func = function()
                            return self.experimental_pen_width
                        end,
                        callback = function()
                            self.experimental_pen_width = not self.experimental_pen_width
                            self:saveSettings()
                            if self.experimental_pen_width then
                                UIManager:show(InfoMessage:new{
                                    text = _("Pen width picker enabled. Hold the pen still to open the picker and choose a stroke width."),
                                    timeout = 3,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Pen width picker disabled."),
                                    timeout = 2,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Text highlight (side button)"),
                        help_text = _("When enabled, holding the stylus side button during a pen drag creates a native KOReader text highlight on the underlying words, like a long-press \xe2\x86\x92 Highlight. Off by default because this is a new integration and has edge cases. Requires a stylus that sends BTN_STYLUS2."),
                        checked_func = function()
                            return self.experimental_text_highlight
                        end,
                        callback = function()
                            self.experimental_text_highlight = not self.experimental_text_highlight
                            self:saveSettings()
                            if self.experimental_text_highlight then
                                UIManager:show(InfoMessage:new{
                                    text = _("Text highlight enabled. Hold the side button while dragging the pen across words."),
                                    timeout = 3,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Text highlight disabled."),
                                    timeout = 2,
                                })
                            end
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("Input debug mode"),
                help_text = _("Enable detailed logging of input events to help diagnose stylus detection issues."),
                checked_func = function()
                    return self.input_debug_mode
                end,
                callback = function()
                    self.input_debug_mode = not self.input_debug_mode
                    self:saveSettings()
                    if self.input_debug_mode then
                        -- Initialize debug logging
                        self:initDebugLog()
                        UIManager:show(InfoMessage:new{
                            text = T(_("Input debug mode enabled.\n\nLog file: %1\n\nUse both pen tip and eraser end, then check the log."), self:getDebugLogPath()),
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Input debug mode disabled."),
                        })
                    end
                end,
            },
            {
                text = _("Clear debug log"),
                enabled_func = function()
                    return self.input_debug_mode
                end,
                callback = function()
                    self:clearDebugLog()
                    UIManager:show(InfoMessage:new{
                        text = _("Debug log cleared. Ready to capture new input events."),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("Show annotation status"),
                callback = function()
                    self:showAnnotationStatus()
                end,
            },
        },
    }
end

-- Show current annotation status for debugging
function Pencil:showAnnotationStatus()
    local page = self:getCurrentPage()
    local page_strokes = #self:pageIndices(page)
    local filepath = self:getStrokesFilePath() or "not available"

    -- Show all pages with strokes for debugging
    local pages_info = ""
    for p, indices in pairs(self.page_strokes) do
        pages_info = pages_info .. string.format("\n  %s (%s): %d", tostring(p), type(p), #indices)
    end
    if pages_info == "" then
        pages_info = "\n  (none)"
    end

    -- Stylus callback status
    local Input = Device.input
    local pen_slot = Input and Input.pen_slot or "N/A"
    local stylus_callback_status = self.stylus_callback_registered and "registered" or "not registered"
    local pen_down_status = self.pen_down and "YES" or "no"

    local status_text = T(_([[Pencil Annotation Status

Selected tool: %1
Total strokes: %2
Strokes on this page: %3
Current page: %4 (%5)
Storage file: %6
Enabled: %7

Stylus callback: %9
Pen slot: %10
Pen down: %11

Side button: tap to toggle pen/eraser, hold+drag to highlight.

Enable "Input debug mode" to log raw events for diagnosis.

Pages with strokes:%8]]),
        self.current_tool,
        #self.strokes,
        page_strokes,
        tostring(page),
        type(page),
        filepath,
        self:isPluginOn() and _("Yes") or _("No"),
        pages_info,
        stylus_callback_status,
        tostring(pen_slot),
        pen_down_status
    )

    UIManager:show(InfoMessage:new{
        text = status_text,
    })
end

-- Handle stylus button press (down event)
-- Side button behavior:
--   - Hold + drag = temporarily highlight, then return to original tool
--   - Quick press (no drawing while held) = toggle between pen and eraser
function Pencil:onStylusButtonPress()
    if not self:isEnabled() or self:isOverlayActive() then return false end

    self.side_button_down = true
    self.side_button_used_for_highlight = false

    logger.dbg("Pencil: side button pressed")
    return true
end

-- Handle stylus button release (up event)
function Pencil:onStylusButtonRelease()
    if not self:isEnabled() or self:isOverlayActive() then return false end

    local was_down = self.side_button_down
    self.side_button_down = false

    -- If the button was NOT used for highlighting (no drawing while held),
    -- treat it as a quick press to toggle between pen and eraser
    if was_down and not self.side_button_used_for_highlight then
        logger.dbg("Pencil: side button quick press - showing tool menu")
        self:showToolMenu()
    else
        -- Was used for highlighting - show brief feedback that we're back to normal
        logger.dbg("Pencil: highlight complete, back to", self.current_tool)
    end

    self.side_button_used_for_highlight = false
    return true
end

-- Tool menu, opened by a quick press of the stylus side button
function Pencil:showToolMenu()
    local ButtonDialog = require("ui/widget/buttondialog")
    local plugin = self
    local dialog
    local function mark(active, label)
        return active and ("✓ " .. label) or label
    end
    local function pick(tool, textmark)
        return function()
            UIManager:close(dialog)
            plugin.textmark_mode = textmark
            plugin.pointer_mode = false
            plugin.current_tool = tool
            plugin:saveSettings()
        end
    end
    local tm = self.textmark_mode
    dialog = ButtonDialog:new{
        title = _("Pencil"),
        title_align = "center",
        buttons = {
            {
                { text = mark(not tm and self.current_tool == TOOL_PEN, _("Pen")),
                  callback = pick(TOOL_PEN, false) },
                { text = mark(not tm and self.current_tool == TOOL_HIGHLIGHTER, _("Highlighter")),
                  callback = pick(TOOL_HIGHLIGHTER, false) },
            },
            {
                { text = mark(not tm and self.current_tool == TOOL_ERASER, _("Eraser")),
                  callback = pick(TOOL_ERASER, false) },
                { text = mark(tm, _("Mark text")),
                  callback = pick(TOOL_PEN, true) },
            },
            {
                { text = _("Undo"),
                  callback = function()
                      UIManager:close(dialog)
                      plugin:undoLastStroke()
                  end },
                { text = _("Close"),
                  callback = function()
                      UIManager:close(dialog)
                  end },
            },
        },
    }
    UIManager:show(dialog)
end

-- Toggle between pen and eraser
function Pencil:togglePenEraser()
    local old_tool = self.current_tool
    local new_tool
    if self.current_tool == TOOL_ERASER then
        new_tool = TOOL_PEN
    else
        new_tool = TOOL_ERASER
    end

    self.current_tool = new_tool
    self:saveSettings()
    logger.dbg("Pencil: toggled from", old_tool, "to", new_tool)

    -- Show brief visual feedback
    UIManager:show(InfoMessage:new{
        text = T(_("Tool: %1"), new_tool),
        timeout = 0.5,
    })
end

-- Handle stylus button and tool events
function Pencil:onKeyPress(key)
    local key_str = tostring(key)

    -- Always log key events when debug mode is on (even if not enabled)
    if self.input_debug_mode then
        self:writeDebugLog(string.format("KEY PRESS: %s key.key=%s", key_str, tostring(key.key)))
    end

    -- Hardware Eraser button - works regardless of pencil enabled state
    if (not self.swap_eraser_and_highlighter and key.key == "Eraser") then
        logger.info("Pencil: Eraser button PRESSED")
        self.eraser_button_active = true
        self.eraser_button_deleted = {}
        return true
    end

    -- BTN_TOOL_RUBBER - physical eraser end - works regardless of pencil enabled state
    if (self.swap_eraser_and_highlighter and (key_str:match("Highlighter") or key_str:match("Stylus"))) or (not self.swap_eraser_and_highlighter and (key_str:match("BTN_TOOL_RUBBER") or key_str:match("ToolRubber"))) then
        logger.info("Pencil: BTN_TOOL_RUBBER press - activating eraser mode")
        self.eraser_button_active = true
        self.eraser_button_deleted = {}
        self.eraser_tool_active = true
        return true
    end

    -- BTN_TOOL_PEN - pen tip - deactivate eraser mode
    if key_str:match("BTN_TOOL_PEN") or key_str:match("ToolPen") then
        logger.info("Pencil: BTN_TOOL_PEN press - deactivating eraser mode")
        if self.eraser_button_active and self.eraser_button_deleted and #self.eraser_button_deleted > 0 then
            -- Save any pending eraser deletions before switching to pen
            self:pushUndo({ type = "delete", strokes = self.eraser_button_deleted })
            self:saveStrokes()
        end
        self.eraser_button_active = false
        self.eraser_button_deleted = nil
        self.eraser_tool_active = false
        return true
    end

    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- BTN_STYLUS (331) - side button on stylus (mapped to "Eraser" on Kobo)
    -- BTN_STYLUS2 (332) - second side button (mapped to "Highlighter" on Kobo)
    if (self.swap_eraser_and_highlighter and key.key == "Eraser") or (not self.swap_eraser_and_highlighter and (key_str:match("Highlighter") or key_str:match("Stylus"))) then
        logger.dbg("Pencil: Stylus button press detected:", key_str)
        return self:onStylusButtonPress()
    end
    return false
end

function Pencil:onKeyRelease(key)
    local key_str = tostring(key)

    -- Always log key events when debug mode is on (even if not enabled)
    if self.input_debug_mode then
        self:writeDebugLog(string.format("KEY RELEASE: %s key.key=%s", key_str, tostring(key.key)))
    end

    -- Hardware Eraser button released
    if key.key == "Eraser" and self.eraser_button_active then
        logger.info("Pencil: Eraser button RELEASED")
        self.eraser_button_active = false
        if self.eraser_button_deleted and #self.eraser_button_deleted > 0 then
            self:pushUndo({ type = "delete", strokes = self.eraser_button_deleted })
            self:saveStrokes()
        end
        self.eraser_button_deleted = nil
        UIManager:setDirty(self.view, "ui")
        return true
    end

    -- BTN_TOOL_RUBBER released (eraser end moved away) - works regardless of pencil enabled state
    if key_str:match("BTN_TOOL_RUBBER") or key_str:match("ToolRubber") then
        logger.info("Pencil: BTN_TOOL_RUBBER release - deactivating eraser mode")
        if self.eraser_button_active and self.eraser_button_deleted and #self.eraser_button_deleted > 0 then
            self:pushUndo({ type = "delete", strokes = self.eraser_button_deleted })
            self:saveStrokes()
        end
        self.eraser_button_active = false
        self.eraser_button_deleted = nil
        self.eraser_tool_active = false
        UIManager:setDirty(self.view, "ui")
        return true
    end

    -- BTN_TOOL_PEN released
    if key_str:match("BTN_TOOL_PEN") or key_str:match("ToolPen") then
        logger.dbg("Pencil: BTN_TOOL_PEN release detected")
        return true
    end

    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Side button released
    if key_str:match("Highlighter") or key_str:match("Stylus") then
        logger.dbg("Pencil: Stylus button release detected:", key_str)
        return self:onStylusButtonRelease()
    end
    return false
end

-- Undo last stroke
local UNDO_LIMIT = 100

-- Record a new undoable action. Any new action invalidates the redo history.
-- "add" actions also keep the stroke itself: stroke_idx alone goes stale as
-- soon as an earlier stroke is erased (indices shift), and undo then removed
-- the wrong stroke. The history is capped to bound memory.
function Pencil:pushUndo(action)
    if action.type == "add" and not action.stroke and action.stroke_idx then
        action.stroke = self.strokes[action.stroke_idx]
    end
    table.insert(self.undo_stack, action)
    if #self.undo_stack > UNDO_LIMIT then
        table.remove(self.undo_stack, 1)
    end
    self.redo_stack = {}
end

-- Current index of a stroke (nil if it's gone)
function Pencil:findStrokeIndex(stroke)
    for i = #self.strokes, 1, -1 do
        if self.strokes[i] == stroke then return i end
    end
end

function Pencil:undoLastStroke()
    if #self.undo_stack == 0 then return end

    local last_action = table.remove(self.undo_stack)
    self.lasso_selection = nil   -- its bbox may no longer match
    if last_action.type == "move" then
        self:shiftStrokes(last_action.strokes, -last_action.dx, -last_action.dy)
        table.insert(self.redo_stack, last_action)
        self:rebuildPageIndex()
        self:rebuildAnnotationGroups()
        self:scheduleDeferredWork()
        UIManager:setDirty(self.ui.dialog or self.ui, "ui")
    elseif last_action.type == "add" then
        -- Remove the stroke that was added (found by identity, see pushUndo)
        local stroke_idx
        if last_action.stroke then
            stroke_idx = self:findStrokeIndex(last_action.stroke)
        else
            stroke_idx = last_action.stroke_idx
        end
        local stroke = stroke_idx and self.strokes[stroke_idx]
        if stroke then
            table.remove(self.strokes, stroke_idx)
            table.insert(self.redo_stack, { type = "add", stroke = stroke })
            self:rebuildPageIndex()
            self:rebuildAnnotationGroups()
            self:scheduleDeferredWork()
            UIManager:setDirty(self.ui.dialog or self.ui, "ui")
        end
    elseif last_action.type == "delete" then
        -- Partial erase leaves pieces behind (stroke._split_into, possibly
        -- split again). Remove every such piece, then restore the originals.
        local pieces = {}
        local function collect(stroke)
            for _, piece in ipairs(stroke._split_into or {}) do
                pieces[piece] = true
                collect(piece)
            end
        end
        for _, stroke in ipairs(last_action.strokes) do
            collect(stroke)
        end
        -- Remember what we change, so redo can put it back exactly.
        local saved_split = {}
        for _, stroke in ipairs(last_action.strokes) do
            saved_split[stroke] = stroke._split_into
        end
        local removed_pieces = {}
        if next(pieces) then
            for i = #self.strokes, 1, -1 do
                if pieces[self.strokes[i]] then
                    table.insert(removed_pieces, 1, self.strokes[i])
                    table.remove(self.strokes, i)
                end
            end
        end
        -- Restore deleted strokes (skipping pieces that were erased again)
        local restored = {}
        for _, stroke in ipairs(last_action.strokes) do
            if not pieces[stroke] then
                stroke._split_into = nil
                table.insert(self.strokes, stroke)
                table.insert(restored, stroke)
            end
        end
        table.insert(self.redo_stack, {
            type = "delete",
            action = last_action,
            restored = restored,
            removed_pieces = removed_pieces,
            saved_split = saved_split,
        })
        self:rebuildPageIndex()
        self:rebuildAnnotationGroups()
        self:scheduleDeferredWork()
        UIManager:setDirty(self.ui.dialog or self.ui, "ui")
    end
end

-- Re-apply the last undone action.
function Pencil:redoLastStroke()
    if not self.redo_stack or #self.redo_stack == 0 then return end

    local entry = table.remove(self.redo_stack)
    self.lasso_selection = nil
    if entry.type == "move" then
        self:shiftStrokes(entry.strokes, entry.dx, entry.dy)
        table.insert(self.undo_stack, entry)
    elseif entry.type == "add" then
        table.insert(self.strokes, entry.stroke)
        -- Direct insert: pushUndo would clear the rest of the redo history.
        table.insert(self.undo_stack, { type = "add", stroke = entry.stroke, stroke_idx = #self.strokes })
    elseif entry.type == "delete" then
        -- Take the restored originals out again...
        local restored = {}
        for _, stroke in ipairs(entry.restored) do
            restored[stroke] = true
        end
        for i = #self.strokes, 1, -1 do
            if restored[self.strokes[i]] then
                table.remove(self.strokes, i)
            end
        end
        -- ...put the leftover pieces of a partial erase back...
        for _, piece in ipairs(entry.removed_pieces) do
            table.insert(self.strokes, piece)
        end
        -- ...and re-link originals to their pieces so a later undo works.
        for stroke, split in pairs(entry.saved_split) do
            stroke._split_into = split
        end
        table.insert(self.undo_stack, entry.action)
    end
    self:rebuildPageIndex()
    self:rebuildAnnotationGroups()
    self:scheduleDeferredWork()
    UIManager:setDirty(self.ui.dialog or self.ui, "ui")
end

function Pencil:setupPenInput()
    if self.touch_zones_registered then return end

    logger.dbg("Pencil: setting up touch zones")

    -- Setup stylus callback for lowest latency pen capture
    self:setupStylusCallback()
    -- Register touch zones through the UI so they're in the active gesture hierarchy
    -- We need to override ALL gestures that might interfere with drawing
    self:registerZonesSafely({
        {
            -- Touch gesture fires IMMEDIATELY on first contact - critical for capturing stroke start
            id = "pencil_draw_touch",
            ges = "touch",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {},
            handler = function(ges)
                return self:onDrawTouch(ges)
            end,
        },
        {
            id = "pencil_draw_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "tap_forward",
                "tap_backward",
                "readerfooter_tap",
                "readerconfigmenu_tap",
                "readerhighlight_tap",
                "readermenu_tap",
                "paging_tap",
                "rolling_tap",
            },
            handler = function(ges)
                return self:onDrawTap(ges)
            end,
        },
        {
            id = "pencil_draw_hold",
            ges = "hold",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "readerhighlight_hold",
                "readerfooter_hold",
            },
            handler = function(ges)
                return self:onDrawHold(ges)
            end,
        },
        {
            id = "pencil_draw_pan",
            ges = "pan",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_pan",
                "rolling_pan",
                "paging_swipe",
                "rolling_swipe",
                "readerhighlight_pan",
            },
            handler = function(ges)
                return self:onDrawPan(ges)
            end,
        },
        {
            id = "pencil_draw_pan_release",
            ges = "pan_release",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_pan_release",
                "rolling_pan_release",
                "readerhighlight_pan_release",
            },
            handler = function(ges)
                return self:onDrawPanRelease(ges)
            end,
        },
        {
            id = "pencil_draw_swipe",
            ges = "swipe",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_swipe",
                "rolling_swipe",
                "readerhighlight_swipe",
            },
            handler = function(ges)
                return self:onDrawSwipe(ges)
            end,
        },
        {
            -- Finger taps on the floating toolbar. Full-screen zone; the
            -- handler hit-tests and passes everything else through.
            id = "pencil_toolbar_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "pencil_draw_tap",
                "tap_forward",
                "tap_backward",
                "readerfooter_tap",
                "readerconfigmenu_tap",
                "readerhighlight_tap",
                "readermenu_tap",
                "paging_tap",
                "rolling_tap",
            },
            handler = function(ges)
                return self:onToolbarTap(ges)
            end,
        },
        {
            -- Finger drag of the toolbar handle
            id = "pencil_toolbar_pan",
            ges = "pan",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "pencil_draw_pan",
                "paging_pan",
                "rolling_pan",
                "readerhighlight_pan",
            },
            handler = function(ges)
                return self:onToolbarPan(ges)
            end,
        },
        {
            id = "pencil_toolbar_pan_release",
            ges = "pan_release",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "pencil_draw_pan_release",
                "paging_pan_release",
                "rolling_pan_release",
                "readerhighlight_pan_release",
            },
            handler = function(ges)
                return self:onToolbarPanRelease(ges)
            end,
        },
    })
    self.touch_zones_registered = true
end

function Pencil:teardownPenInput()
    if not self.touch_zones_registered then return end

    -- Teardown stylus callback
    self:teardownStylusCallback()

    self.ui:unRegisterTouchZones({
        { id = "pencil_draw_touch" },  -- Must unregister touch zone too
        { id = "pencil_draw_tap" },
        { id = "pencil_draw_hold" },
        { id = "pencil_draw_pan" },
        { id = "pencil_draw_pan_release" },
        { id = "pencil_draw_swipe" },
        { id = "pencil_toolbar_tap" },
        { id = "pencil_toolbar_pan" },
        { id = "pencil_toolbar_pan_release" },
    })
    self.touch_zones_registered = false
end

-- Handle swipe gestures (block them when drawing mode is active)
function Pencil:onDrawSwipe(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- If raw input detected pen, block swipe to prevent page turns
    if self.pen_down then return true end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then return false end

    -- Block the swipe - we don't want page turns while drawing
    return true
end

-- Handle tip long press (hold gesture)
function Pencil:onDrawHold(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- If raw input detected pen, block hold to prevent reader highlight mode
    if self.pen_down then return true end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then return false end

    -- Block pen hold gestures while drawing mode is active
    return true
end

-- Schedule a delayed refresh after writing stops
function Pencil:scheduleDelayedRefresh()
    -- Cancel any existing pending refresh
    self:cancelPendingRefresh()

    -- UIManager:scheduleIn returns NOTHING — we must keep our own
    -- reference to the function we scheduled so cancelPendingRefresh can
    -- unschedule it by identity. Previously this was bugged: scheduling
    -- assigned nil to pending_refresh, so cancel never fired, and every
    -- stroke piled another 600ms timer onto the queue. Fast consecutive
    -- strokes blew past the timer and KOReader committed mid-write.
    local body
    local action = function()
        local ok, err = pcall(body)
        if not ok then self:reportError("settle refresh", err) end
    end
    body = function()
        self.pending_refresh = nil
        local region
        if self.sony_dhw_active and self.dirty_region then
            local r = self.dirty_region
            self.dirty_region = nil
            local rx = math.max(0, math.floor(r.x))
            local ry = math.max(0, math.floor(r.y))
            local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
            local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
            region = Geom:new{x = rx, y = ry, w = rw, h = rh}
            UIManager:setDirty(self.view, "fast", region)
            logger.dbg("Pencil: delayed refresh triggered (partial",
                       rx, ry, rw, rh, ")")
        else
            -- Kindle: "fast" is 1-bit A2 there, which turns the gray
            -- highlighter white and leaves text jagged. The settle-refresh
            -- after writing needs the gray-capable "ui" waveform.
            if self.settle_repaint then
                -- A highlighter preview (dot pattern) is on screen: repaint the
                -- page so the stroke is redrawn in its real gray.
                -- "partial" = REAGL on Kindle: grayscale without flashing.
                -- ("ui" is AUTO there and picks the flashing GC16 as soon as
                -- gray is present, which made the marker pop to black.)
                self.settle_repaint = false
                local r = self.settle_region
                self.settle_region = nil
                if r and self:isOverlayActive() then
                    -- A menu/dialog opened meanwhile: painting the page
                    -- directly would draw over it. Let UIManager repaint the
                    -- window stack in order instead.
                    UIManager:setDirty(self.ui.dialog or self.ui, "partial")
                elseif r then
                    -- Repaint the page, but refresh ONLY the new marker area,
                    -- directly with REAGL. Going through UIManager refreshed
                    -- the whole screen, and every 6th partial refresh gets
                    -- promoted to a flashing full refresh: all markers on the
                    -- page blinked black.
                    local x = math.max(0, math.floor(r.x0))
                    local y = math.max(0, math.floor(r.y0))
                    local w = math.min(Screen:getWidth(), math.ceil(r.x1)) - x
                    local h = math.min(Screen:getHeight(), math.ceil(r.y1)) - y
                    self.view:paintTo(Screen.bb, 0, 0)
                    if w > 0 and h > 0 then
                        Screen:refreshPartial(x, y, w, h)
                    end
                else
                    UIManager:setDirty(self.ui.dialog or self.ui, "partial")
                end
            else
                UIManager:setDirty(self.view, Device:isKindle() and "ui" or "fast")
            end
            logger.dbg("Pencil: delayed refresh triggered (full)")
        end
        -- The setDirty above queues a repaint for the next UI tick.
        -- Wipe the StylusView overlay AFTER that tick has had a chance
        -- to commit KOReader's page-with-strokes — scheduleIn(0.3)
        -- (roughly two DU waveform periods) gives the EPD time to flush.
        -- Doing it inline would clear the overlay before the page repaints,
        -- flashing the strokes off the screen briefly.
        if self.sony_dhw_active then
            UIManager:scheduleIn(0.3, function()
                local ok, android = pcall(require, "android")
                if ok and android and android.stylusOverlayClear then
                    android.stylusOverlayClear()
                end
            end)
        end
    end
    self.pending_refresh = action
    UIManager:scheduleIn(self.refresh_delay_ms / 1000, action)
end

-- Cancel pending refresh (called when new stroke starts)
function Pencil:cancelPendingRefresh()
    if self.pending_refresh then
        UIManager:unschedule(self.pending_refresh)
        self.pending_refresh = nil
    end
end

-- Mark strokes as dirty. Actual disk write is deferred until the user
-- changes page or closes the document — saving on every stroke caused
-- visible inter-stroke pauses on slow flash. flushDeferredWork is the
-- single drain point; see onPageUpdate / onUpdatePos / onCloseDocument.
-- Strokes are written on page change / close / suspend, and at the latest
-- AUTOSAVE_S after the first unsaved change, so a crash or flat battery
-- can't take a long session on one page with it.
local AUTOSAVE_S = 20

function Pencil:scheduleDeferredWork()
    self.strokes_dirty = true
    if self._autosave_fn then return end
    self._autosave_fn = function()
        self._autosave_fn = nil
        if self.pen_down or self.erasing then
            -- Never write mid-gesture; try again shortly
            return self:scheduleDeferredWork()
        end
        local ok, err = pcall(self.flushDeferredWork, self)
        if not ok then self:reportError("autosave", err) end
    end
    UIManager:scheduleIn(AUTOSAVE_S, self._autosave_fn)
end

function Pencil:cancelAutosave()
    if self._autosave_fn then
        UIManager:unschedule(self._autosave_fn)
        self._autosave_fn = nil
    end
end

function Pencil:cancelPendingSave()
    if self.pending_save then
        UIManager:unschedule(self.pending_save)
        self.pending_save = nil
    end
end

-- Run any pending deferred work immediately. Called before close, page change,
-- or any path that must persist state synchronously.
function Pencil:flushDeferredWork()
    local has_dirty_groups = self.dirty_groups and next(self.dirty_groups)
    if not self.strokes_dirty and not has_dirty_groups then
        return
    end
    self:cancelPendingSave()
    self:flushDirtyGroups()
    self:saveStrokes()
end

-- Sync bookmarks for any groups marked dirty since the last flush. No-op when
-- the experimental bookmark sync feature is off or nothing is pending.
function Pencil:flushDirtyGroups()
    if not self.dirty_groups then return end
    if not self.experimental_bookmark_sync then
        self.dirty_groups = nil
        return
    end
    for _, group in pairs(self.dirty_groups) do
        self:syncGroupBookmark(group)
    end
    self.dirty_groups = nil
end

-- Reset color picker tracking (called when pen moves too far)
function Pencil:resetColorPickerTracking()
    self.color_picker_start_x = nil
    self.color_picker_start_y = nil
    self.color_picker_start_time = nil
end

-- Check if color picker should be shown (called periodically while pen is down)
function Pencil:checkColorPickerTrigger()
    -- Gated behind the two experimental flags. At least one must be on for
    -- the hold-pen-still gesture to produce anything; otherwise the pen
    -- stays on its last-saved color/width.
    if not (self.experimental_color_picker or self.experimental_pen_width) then return end
    if not self.color_picker_start_time then return end
    if self.color_picker_showing then return end

    local elapsed_ms = time.to_ms(time.now() - self.color_picker_start_time)
    if elapsed_ms >= COLOR_PICKER_DELAY_MS then
        -- Time elapsed without moving too far - show color picker
        self:showColorPicker(self.pen_x, self.pen_y)
        self:resetColorPickerTracking()
    end
end

-- Schedule periodic check for color picker trigger
function Pencil:scheduleColorPickerCheck()
    if self.color_picker_check_pending then
        UIManager:unschedule(self.color_picker_check_pending)
    end

    local plugin = self
    -- UIManager:scheduleIn returns nothing — store the action itself so
    -- cancelColorPickerTimer can unschedule by identity. Without this the
    -- 100 ms poll never cancels and stacks more polls each pen-down.
    local action = function()
        plugin.color_picker_check_pending = nil
        if plugin.pen_down and plugin.color_picker_start_time and not plugin.color_picker_showing then
            plugin:checkColorPickerTrigger()
            -- Schedule next check if still waiting
            if plugin.color_picker_start_time then
                plugin:scheduleColorPickerCheck()
            end
        end
    end
    self.color_picker_check_pending = action
    UIManager:scheduleIn(0.1, action)
end

-- Cancel color picker check
function Pencil:cancelColorPickerTimer()
    if self.color_picker_check_pending then
        UIManager:unschedule(self.color_picker_check_pending)
        self.color_picker_check_pending = nil
    end
    self:resetColorPickerTracking()
end

-- Color picker widget for selecting pen color (and optionally pen width).
-- When `widths` is provided, the widget shows two rows: colors on top,
-- widths below. The width row contains black bars whose vertical thickness
-- matches the actual stroke thickness in device pixels (what-you-see is
-- what-you-draw).
local ColorPickerWidget = InputContainer:extend {
    width = nil,
    height = nil,
    colors = nil, -- Array of {color, name} objects
    widths = nil, -- Optional array of {name, width} objects (experimental width picker)
    current_color_name = nil, -- Currently selected color name (for comparison)
    current_width = nil, -- Currently selected pen width (for width selection indicator)
    callback = nil,
    close_callback = nil,
    -- Layout constants cached after init so handlePenTap / paintTo don't
    -- recompute them. Kept on self so tests can read them too.
    _button_size = nil,
    _spacing = nil,
    _row_gap = nil,
    _padding = nil,
}

-- Build one button (color or width). Returns the InputContainer button, which
-- also stores its own color / width metadata so the callback can route without
-- string-matching on name.
function ColorPickerWidget:_makeButton(item, button_size, selection_border)
    -- Selection: colors compare by name, widths compare by width value
    local is_selected
    if item.kind == "width" then
        is_selected = (item.width_value == self.current_width)
    else
        is_selected = (item.name == self.current_color_name)
    end
    local border_size = is_selected and selection_border or Size.border.thick

    local swatch
    if item.kind == "width" then
        -- Truthful preview: a horizontal black bar whose height equals the
        -- stroke's actual device-pixel thickness. We deliberately do NOT
        -- scale by Screen:scaleBySize — the stroke itself is drawn in raw
        -- pixels (see paintRectRGB32 in drawLineSegment), so scaling here
        -- would lie about the line weight.
        local inner = button_size - border_size * 2
        local bar_h = item.width_value
        local bar_w = math.floor(inner * 0.7)
        local bar = FrameContainer:new{
            width = bar_w,
            height = bar_h,
            padding = 0,
            margin = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_BLACK,
            WidgetContainer:new{
                dimen = Geom:new{ w = bar_w, h = bar_h },
            },
        }
        swatch = FrameContainer:new{
            width = button_size,
            height = button_size,
            padding = 0,
            margin = 0,
            bordersize = border_size,
            color = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = inner, h = inner },
                bar,
            },
        }
    else
        -- Regular color swatch
        local border_color = Blitbuffer.COLOR_BLACK
        if item.name == "Black" then
            border_color = Blitbuffer.Color8(0x44)
        end
        swatch = FrameContainer:new{
            width = button_size,
            height = button_size,
            padding = 0,
            margin = 0,
            bordersize = border_size,
            color = border_color,
            background = item.color_value,
            WidgetContainer:new{
                dimen = Geom:new{ w = button_size - border_size * 2, h = button_size - border_size * 2 },
            },
        }
        if Screen.night_mode and item.name ~= "Black" and item.name ~= "Gray" then
            swatch.background = swatch.background:invert()
        end
    end

    local button = InputContainer:new{
        dimen = Geom:new{ w = button_size, h = button_size },
        swatch,
        kind = item.kind,
        color_value = item.color_value,  -- nil for width items
        color_name = item.name,
        width_value = item.width_value,  -- nil for color items
    }

    button.ges_events = {
        TapSelectColor = {
            GestureRange:new{
                ges = "tap",
                range = function() return button.dimen end,
            },
        },
    }

    local widget = self
    button.onTapSelectColor = function(btn)
        if widget.callback then
            widget.callback(btn.color_value, btn.color_name, btn.width_value)
        end
        if widget.close_callback then
            widget.close_callback()
        end
        return true
    end

    return button
end

-- Build a HorizontalGroup row of buttons from an item list. Populates the
-- supplied `info_list` in-tap-index order.
function ColorPickerWidget:_buildRow(items, button_size, spacing, selection_border, info_list)
    local group = HorizontalGroup:new{ align = "center" }
    for i, item in ipairs(items) do
        if i > 1 then
            table.insert(group, HorizontalSpan:new{ width = spacing })
        end
        local button = self:_makeButton(item, button_size, selection_border)
        table.insert(group, button)
        table.insert(info_list, button)
    end
    return group
end

function ColorPickerWidget:init()
    local button_size = Screen:scaleBySize(36)
    local spacing = Screen:scaleBySize(8)
    local row_gap = Screen:scaleBySize(8)  -- vertical gap between color row and width row
    local padding = Screen:scaleBySize(10)
    local selection_border = Size.border.thick * 3

    self._button_size = button_size
    self._spacing = spacing
    self._row_gap = row_gap
    self._padding = padding

    -- Build optional color row. `colors` is nil when the color-picker
    -- experimental flag is off; in that case we render a widths-only picker.
    local has_colors = self.colors and #self.colors > 0
    self.color_buttons_info = {}
    local color_row_group
    local colors_row_width = 0
    if has_colors then
        local color_items = {}
        for _, color_info in ipairs(self.colors) do
            table.insert(color_items, {
                kind = "color",
                name = color_info.name,
                color_value = color_info.color,
            })
        end
        color_row_group = self:_buildRow(color_items, button_size, spacing, selection_border, self.color_buttons_info)
        colors_row_width = #color_items * button_size + (#color_items - 1) * spacing
    end

    -- Build optional width row
    local has_widths = self.widths and #self.widths > 0
    self.width_buttons_info = {}
    local width_row_group
    local widths_row_width = 0
    if has_widths then
        local width_items = {}
        for _, width_info in ipairs(self.widths) do
            table.insert(width_items, {
                kind = "width",
                name = width_info.name,
                width_value = width_info.width,
            })
        end
        width_row_group = self:_buildRow(width_items, button_size, spacing, selection_border, self.width_buttons_info)
        widths_row_width = #width_items * button_size + (#width_items - 1) * spacing
    end

    -- Inner width accommodates the wider of the visible rows. Height
    -- accumulates one button_size per visible row plus a gap when both
    -- are showing.
    local visible_rows = (has_colors and 1 or 0) + (has_widths and 1 or 0)
    local inner_w = math.max(colors_row_width, widths_row_width)
    self.width = inner_w
    self.height = visible_rows * button_size + (visible_rows > 1 and row_gap or 0)

    local content
    if has_colors and has_widths then
        content = VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = button_size },
                color_row_group,
            },
            VerticalSpan:new{ width = row_gap },
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = button_size },
                width_row_group,
            },
        }
    elseif has_colors then
        content = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = button_size },
            color_row_group,
        }
    else
        -- widths-only picker (color picker experimental flag off)
        content = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = button_size },
            width_row_group,
        }
    end

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = padding,
        content,
    }

    self[1] = self.frame
    self.dimen = self.frame:getSize()

    -- Register gesture to close when tapping outside
    self.ges_events = {
        TapCloseOutside = {
            GestureRange:new{
                ges = "tap",
                range = function() return Geom:new{
                    x = 0, y = 0,
                    w = Screen:getWidth(),
                    h = Screen:getHeight(),
                } end,
            },
        },
    }
end

-- Hit-test one row of buttons. `row_y` is the top y of the row in absolute
-- coordinates. Returns the matching button info or nil.
function ColorPickerWidget:_hitRow(x, y, row_y, info_list)
    local button_size = self._button_size
    local spacing = self._spacing
    if #info_list == 0 then return nil end
    if y < row_y or y >= row_y + button_size then return nil end

    local row_buttons_width = #info_list * button_size + (#info_list - 1) * spacing
    local row_start_x = self.dimen.x + (self.dimen.w - row_buttons_width) / 2
    local relative_x = x - row_start_x
    if relative_x < 0 or relative_x >= row_buttons_width then return nil end

    local stride = button_size + spacing
    local idx = math.floor(relative_x / stride) + 1
    local pos_in_slot = relative_x - (idx - 1) * stride
    if pos_in_slot >= button_size then return nil end
    if idx < 1 or idx > #info_list then return nil end
    return info_list[idx]
end

-- Handle pen/stylus tap on color picker
-- Returns true if the tap was handled (hit a button or was inside picker)
function ColorPickerWidget:handlePenTap(x, y)
    if not self.dimen then
        return false
    end

    -- Check if tap is inside the widget
    local inside = x >= self.dimen.x and x < self.dimen.x + self.dimen.w
            and y >= self.dimen.y and y < self.dimen.y + self.dimen.h

    if not inside then
        -- Tap outside - close the picker
        if self.close_callback then
            self.close_callback()
        end
        return true  -- Consume the event to prevent drawing
    end

    local border = Size.border.window
    local button_size = self._button_size
    local row_gap = self._row_gap
    local padding = self._padding

    -- When colors are hidden (color-picker flag off, width-picker on),
    -- the widths row slides up to the top-row position. The info-lists
    -- drive which row is where.
    local top_row_y = self.dimen.y + border + padding
    local colors_present = #self.color_buttons_info > 0
    local widths_row_y = colors_present and (top_row_y + button_size + row_gap) or top_row_y

    local btn = self:_hitRow(x, y, top_row_y, self.color_buttons_info)
        or self:_hitRow(x, y, widths_row_y, self.width_buttons_info)

    if btn then
        if self.callback then
            self.callback(btn.color_value, btn.color_name, btn.width_value)
        end
        if self.close_callback then
            self.close_callback()
        end
        return true
    end

    -- Inside picker but didn't hit a button - still consume the event
    return true
end

-- Handle tap - close if outside the widget
function ColorPickerWidget:onTapCloseOutside(_, ges)
    if ges and ges.pos and self.dimen then
        -- Check if tap is inside the widget using coordinate comparison
        local x, y = ges.pos.x, ges.pos.y
        local inside = x >= self.dimen.x and x < self.dimen.x + self.dimen.w
                and y >= self.dimen.y and y < self.dimen.y + self.dimen.h
        if inside then
            -- Tap is inside, let the color buttons handle it
            return false
        end
    end
    -- Tap is outside, close the widget without changing color
    if self.close_callback then
        self.close_callback()
    end
    return true
end

-- Update button dimens for one row so individual TapSelectColor gesture ranges
-- match the painted positions. Mirrors the centered layout built in init().
function ColorPickerWidget:_placeRow(info_list, paint_x, frame_inner_width, padding, border, row_y)
    if #info_list == 0 then return end
    local button_size = self._button_size
    local spacing = self._spacing
    local total_buttons_width = #info_list * button_size + (#info_list - 1) * spacing
    local row_start_x = paint_x + border + padding + (frame_inner_width - total_buttons_width) / 2
    for i, btn in ipairs(info_list) do
        btn.dimen.x = row_start_x + (i - 1) * (button_size + spacing)
        btn.dimen.y = row_y
    end
end

function ColorPickerWidget:paintTo(bb, x, y)
    -- Use absolute position from dimen if set, otherwise use passed coordinates
    local paint_x = self.dimen and self.dimen.x or x
    local paint_y = self.dimen and self.dimen.y or y

    -- Paint the frame at the absolute position
    self.frame:paintTo(bb, paint_x, paint_y)

    if not self.color_buttons_info then return end

    local button_size = self._button_size
    local row_gap = self._row_gap
    local padding = self._padding
    local border = Size.border.window
    local frame_inner_width = self.dimen.w - 2 * padding - 2 * border

    -- Symmetric with handlePenTap: widths slide up to the top slot when
    -- no colors are visible.
    local top_row_y = paint_y + border + padding
    local colors_present = #self.color_buttons_info > 0

    if colors_present then
        self:_placeRow(self.color_buttons_info, paint_x, frame_inner_width, padding, border, top_row_y)
    end

    if self.width_buttons_info and #self.width_buttons_info > 0 then
        local widths_row_y = colors_present and (top_row_y + button_size + row_gap) or top_row_y
        self:_placeRow(self.width_buttons_info, paint_x, frame_inner_width, padding, border, widths_row_y)
    end
end

function ColorPickerWidget:onCloseWidget()
    UIManager:setDirty(nil, "ui", self.dimen)
end

-- Show color picker popup near the pen position
function Pencil:showColorPicker(x, y)
    if self.color_picker_showing then return end

    -- Discard any current stroke that was made while holding still
    -- The user was holding still to trigger color picker, not intentionally drawing
    if self.current_stroke then
        self.current_stroke = nil
        -- Repaint to remove the stroke from screen immediately
        self.view:paintTo(Screen.bb, 0, 0)
        self:paintTo(Screen.bb, 0, 0)
        Screen:refreshUI(0, 0, Screen:getWidth(), Screen:getHeight())
    end

    self.color_picker_showing = true

    local plugin = self

    -- Which rows to render is driven by the two experimental toggles,
    -- independently. The hold-pen-still gesture only gets here when at
    -- least one of them is on (see checkColorPickerTrigger), so at least
    -- one row is guaranteed non-empty.
    local show_colors = self.experimental_color_picker
    local show_widths = self.experimental_pen_width
    local colors_for_picker = show_colors and self.available_colors or nil
    local widths_for_picker = show_widths and self.available_widths or nil

    -- Picker uses up to two rows (colors on top, widths below). Row width
    -- is the wider of the two visible rows; height accumulates one
    -- button_size per visible row plus a gap between them.
    local button_size = Screen:scaleBySize(36)
    local spacing = Screen:scaleBySize(8)
    local row_gap = Screen:scaleBySize(8)
    local padding = Screen:scaleBySize(10)
    local border = Size.border.window
    local colors_row_width = show_colors and
        (#self.available_colors * button_size + (#self.available_colors - 1) * spacing) or 0
    local widths_row_width = show_widths and
        (#self.available_widths * button_size + (#self.available_widths - 1) * spacing) or 0
    local buttons_width = math.max(colors_row_width, widths_row_width)
    local picker_width = buttons_width + padding * 2 + border * 2
    local rows = (show_colors and 1 or 0) + (show_widths and 1 or 0)
    local picker_height = rows * button_size + padding * 2 + border * 2
    if rows > 1 then
        picker_height = picker_height + row_gap
    end
    local margin_above = Screen:scaleBySize(30)  -- Gap between picker and pen
    local screen_margin = 10  -- Minimum margin from screen edges

    -- Try to position above the pen first, centered horizontally
    local picker_x = x - picker_width / 2
    local picker_y = y - picker_height - margin_above

    -- Adjust horizontal position to keep picker fully on screen
    if picker_x < screen_margin then
        picker_x = screen_margin
    end
    if picker_x + picker_width > Screen:getWidth() - screen_margin then
        picker_x = Screen:getWidth() - picker_width - screen_margin
    end

    -- If no room above, position below the pen
    if picker_y < screen_margin then
        picker_y = y + margin_above
    end

    -- Final check: ensure it fits on screen vertically
    if picker_y + picker_height > Screen:getHeight() - screen_margin then
        picker_y = Screen:getHeight() - picker_height - screen_margin
    end

    local color_picker = ColorPickerWidget:new{
        colors = colors_for_picker,
        widths = widths_for_picker,
        current_color_name = self.tool_settings[TOOL_PEN].color_name,
        current_width = self.tool_settings[TOOL_PEN].width,
        callback = function(color_value, color_name, width_value)
            -- Width taps are routed through width_value; color taps leave it nil.
            -- This avoids the string-match ambiguity the earlier prototype had.
            if width_value then
                plugin:setPenWidth(width_value)
                UIManager:show(InfoMessage:new{
                    text = T(_("Pen width: %1"), width_value),
                    timeout = 1,
                })
                return
            end

            plugin:setPenColor(color_value, color_name)

            -- Display white as the color name if black is picked in night mode
            if Screen.night_mode and color_name == "Black" then
                color_name = "White"
            end

            UIManager:show(InfoMessage:new{
                text = T(_("Pen color: %1"), color_name),
                timeout = 1,
            })
        end,
        close_callback = function()
            plugin.color_picker_showing = false
            UIManager:close(plugin.color_picker_widget)
            plugin.color_picker_widget = nil
            -- Refresh to clean up
            UIManager:setDirty(plugin.view, "ui")
        end,
    }

    -- Position the widget at the calculated coordinates
    -- Set dimen with absolute position before showing
    color_picker.dimen = color_picker.dimen or Geom:new{}
    color_picker.dimen.x = picker_x
    color_picker.dimen.y = picker_y

    self.color_picker_widget = color_picker

    UIManager:show(self.color_picker_widget)
    UIManager:setDirty(self.color_picker_widget, "ui")

    logger.dbg("Pencil: color picker shown at", picker_x, picker_y)
end

-- Set pen color
function Pencil:setPenColor(color, color_name)
    self.tool_settings[TOOL_PEN].color = color
    self.tool_settings[TOOL_PEN].color_name = color_name
    logger.info("Pencil: setPenColor - color_name =", color_name)
    self:saveSettings()
end

-- Set pen width. Only callable while experimental_pen_width is on
-- (the picker is the only UI path that invokes this).
function Pencil:setPenWidth(width)
    self.tool_settings[TOOL_PEN].width = width
    logger.info("Pencil: setPenWidth - width =", width)
    self:saveSettings()
    -- Keep StylusView's per-segment NOCONVERT_DU render in sync.
    if Device:isAndroid() then
        local ok, android = pcall(require, "android")
        if ok and android and android.stylusOverlaySetPenWidth then
            android.stylusOverlaySetPenWidth(width)
        end
    end
end

-- Handle initial touch - fires IMMEDIATELY on first contact
-- This is critical for capturing the start of strokes without delay
-- NOTE: For pen/highlighter, raw input hook handles drawing directly for lowest latency
-- This handler blocks gestures and is a backup if raw input not working
function Pencil:onDrawTouch(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Check if this is a finger touch (not pen) - let gesture system handle it
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    -- Check if raw input hook detected pen - if so, block gesture but don't duplicate
    -- This is the primary pen detection method (lowest latency)
    if self.pen_down then
        -- Raw input is handling drawing - just block the gesture
        self:cancelPendingRefresh()
        return true
    end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then return false end

    -- Cancel any pending refresh - user is still writing
    self:cancelPendingRefresh()

    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)

    -- For eraser, we handle in pan (need movement to erase)
    if effective_tool == TOOL_ERASER then
        return true  -- Block but don't start stroke
    end

    -- Fallback: handle via gesture system if raw input not working
    local page = self:getCurrentPage()

    -- If side button is held for highlighting
    if self.side_button_down then
        self.side_button_used_for_highlight = true
    end

    -- Start new stroke immediately with first point
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]
    self.current_stroke = {
        page = page,
        vkey = self:getViewKey(),
        tool = effective_tool,
        points = { { x = ges.pos.x, y = ges.pos.y } },
        width = tool_settings.width,
        color = tool_settings.color,
        color_name = tool_settings.color_name,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }

    -- Draw first point to framebuffer - NO REFRESH during drawing
    -- E-ink displays show "ghost" pixels when framebuffer changes, providing visual feedback
    -- Refresh only happens after user stops writing (delayed refresh)
    local width = tool_settings.width
    local color = tool_settings.color
    local half_w = math.floor(width / 2)
    Screen.bb:paintRectRGB32(ges.pos.x - half_w, ges.pos.y - half_w, width, width, color)

    return true
end

-- Check if this is a stylus/pen event (not finger)
-- Returns: is_pen (boolean), is_eraser_end (boolean), is_highlighter (boolean)
function Pencil:isPenInput(ges)
    if Device:isEmulator() then
        return true, false, false
    end

    local Input = Device.input
    if not Input or not Input.pen_slot then
        return false, false, false
    end

    local TOOL_TYPE_PEN = 1
    local TOOL_TYPE_ERASER = 2
    local TOOL_TYPE_HIGHLIGHTER = 3

    local pen_slot_data = Input:getMtSlot(Input.pen_slot)
    if pen_slot_data and pen_slot_data.id and pen_slot_data.id ~= -1 then
        if pen_slot_data.tool == TOOL_TYPE_PEN then
            return true, false, false
        elseif pen_slot_data.tool == TOOL_TYPE_ERASER then
            return true, true, false
        elseif pen_slot_data.tool == TOOL_TYPE_HIGHLIGHTER then
            return true, false, true
        end
    end

    return false, false, false
end

-- Get the effective tool (considers physical eraser end and side button)
function Pencil:getEffectiveTool(is_eraser_end, is_highlighter)
    -- Check both the tool type detection AND the BTN_TOOL_RUBBER state
    if self.eraser_tool_active or ((self.swap_eraser_and_highlighter and is_highlighter) or (not self.swap_eraser_and_highlighter and is_eraser_end)) then
        return TOOL_ERASER
    end

    -- Side button held = highlighter mode (for hold+drag highlighting)
    if self.side_button_down or ((self.swap_eraser_and_highlighter and is_eraser_end) or (not self.swap_eraser_and_highlighter and is_highlighter)) then
        return TOOL_HIGHLIGHTER
    end

    return self.current_tool
end

-- Called on tap - create a dot or erase at point
function Pencil:onDrawTap(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- If raw input detected pen recently, block tap to prevent navigation
    -- Note: pen_down will be false by tap time, but we may have just drawn
    -- We should block taps if there's a current stroke or recent drawing
    if self.current_stroke then
        return true  -- Block tap while stroke in progress
    end

    -- Rotation badge hit-test: consume taps (pen or finger) over the camera
    -- badge of a stale-rotation annotation and open its saved image.
    if ges and ges.pos then
        local hit = self:findGroupBadgeAtPoint(ges.pos.x, ges.pos.y)
        if hit then
            logger.info("Pencil: badge tap hit group", hit.id,
                "at (", ges.pos.x, ",", ges.pos.y, ")")
            self:showGroupImagePreview(hit)
            return true
        end
    end

    -- Check if finger tap - let gesture system handle it
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    local page = self:getCurrentPage()
    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)
    logger.dbg("Pencil: onDrawTap - effective_tool =", effective_tool)

    -- Log to debug file for analysis
    self:writeDebugLog(string.format("=== TAP at (%d, %d) ===", ges.pos.x, ges.pos.y))
    self:writeDebugLog(string.format("  is_eraser_end=%s eraser_tool_active=%s effective_tool=%s",
        tostring(is_eraser_end), tostring(self.eraser_tool_active), effective_tool))

    if effective_tool == TOOL_ERASER then
        -- Eraser: delete strokes near tap point
        logger.info("Pencil: eraser tap at", ges.pos.x, ges.pos.y, "page =", page)
        local erased = self:eraseAtPoint(ges.pos.x, ges.pos.y, page)
        if erased then
            logger.info("Pencil: erased", #erased, "strokes")
            self:pushUndo({ type = "delete", strokes = erased })
            self:queueEraseRefresh(erased)
            self:finishErase()
            self:saveStrokes()
            UIManager:setDirty(self.view, "ui")
        else
            logger.info("Pencil: eraser tap found no strokes to erase")
        end
        return true
    end

    -- Pen or Highlighter: create a dot
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]
    local stroke = {
        page = page,
        vkey = self:getViewKey(),
        tool = effective_tool,
        points = { { x = ges.pos.x, y = ges.pos.y } },
        width = tool_settings.width,
        color = tool_settings.color,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }

    table.insert(self.strokes, stroke)
    self:indexStroke(#self.strokes, page)
    self:saveStrokes()

    -- Add to undo stack
    self:pushUndo({ type = "add", stroke_idx = #self.strokes })

    -- Draw directly to screen buffer
    self:renderStroke(Screen.bb, stroke)

    -- Direct framebuffer refresh for instant feedback
    local w = stroke.width
    Screen:refreshFast(ges.pos.x - w, ges.pos.y - w, w * 2, w * 2)

    return true
end

-- Called during pan - continues stroke started by onDrawTouch
-- NOTE: For pen/highlighter, raw input hook handles drawing directly for lowest latency
-- This handler blocks gestures and handles eraser mode
function Pencil:onDrawPan(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Check if raw input hook detected pen - if so, block gesture
    -- Raw input handles all drawing; this just needs to block swipe/pan gestures
    if self.pen_down then
        return true  -- Block pan gesture, raw input is drawing
    end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then return false end

    local page = self:getCurrentPage()
    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)

    -- If side button is held and we're drawing, mark it as used for highlighting
    if self.side_button_down and effective_tool == TOOL_HIGHLIGHTER then
        self.side_button_used_for_highlight = true
    end

    -- Eraser mode: erase along path (raw input doesn't handle eraser)
    if effective_tool == TOOL_ERASER then
        if not self.eraser_deleted then
            self.eraser_deleted = {}
        end

        local deleted = self:eraseAtPoint(ges.pos.x, ges.pos.y, page)
        if deleted then
            for _, stroke in ipairs(deleted) do
                table.insert(self.eraser_deleted, stroke)
            end
            self:queueEraseRefresh(deleted)
        end
        return true
    end

    -- Fallback: handle via gesture system if raw input not working
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]

    -- Stroke should already exist from onDrawTouch, but handle fallback cases
    if not self.current_stroke or self.current_stroke.page ~= page or self.current_stroke.tool ~= effective_tool then
        -- Fallback: create stroke if touch event was missed or context changed
        logger.dbg("Pencil: onDrawPan creating fallback stroke")
        self.current_stroke = {
            page = page,
            vkey = self:getViewKey(),
            tool = effective_tool,
            points = {},
            width = tool_settings.width,
            color = tool_settings.color,
            color_name = tool_settings.color_name,
            alpha = tool_settings.alpha,
            datetime = os.time(),
        }
        -- Use start_pos if available for the first point
        if ges.start_pos then
            table.insert(self.current_stroke.points, { x = ges.start_pos.x, y = ges.start_pos.y })
        end
    end

    -- Add current point to stroke
    local point = { x = ges.pos.x, y = ges.pos.y }
    table.insert(self.current_stroke.points, point)

    -- Draw the new segment to framebuffer - NO REFRESH during drawing
    -- E-ink shows ghost pixels, refresh happens on pan_release
    local n = #self.current_stroke.points
    local width = self.current_stroke.width
    local color = self.current_stroke.color

    if n >= 2 then
        local p1 = self.current_stroke.points[n - 1]
        local p2 = self.current_stroke.points[n]

        if effective_tool == TOOL_HIGHLIGHTER then
            self:drawHighlighterSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        else
            self:drawLineSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        end
    elseif n == 1 then
        local p = self.current_stroke.points[1]
        local half_w = math.floor(width / 2)
        Screen.bb:paintRectRGB32(p.x - half_w, p.y - half_w, width, width, color)
    end

    return true
end

-- Called when pan ends - finalize stroke
-- NOTE: For pen/highlighter, raw input hook may have already finalized the stroke
function Pencil:onDrawPanRelease(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Let finger releases be handled by gesture system
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    local effective_tool = self:getEffectiveTool(is_eraser_end, is_highlighter)

    -- Log pan end to debug file
    self:writeDebugLog(string.format("=== PAN END at (%d, %d) ===", ges.pos.x, ges.pos.y))
    self:writeDebugLog(string.format("  is_eraser_end=%s eraser_tool_active=%s effective_tool=%s",
        tostring(is_eraser_end), tostring(self.eraser_tool_active), effective_tool))

    -- Handle eraser pan release (raw input doesn't handle eraser)
    if effective_tool == TOOL_ERASER then
        self:finishErase()
        if self.eraser_deleted and #self.eraser_deleted > 0 then
            -- Add deleted strokes to undo stack
            self:pushUndo({ type = "delete", strokes = self.eraser_deleted })
            self:saveStrokes()
        end
        -- Always refresh screen after erasing to clear any visual artifacts
        UIManager:setDirty(self.view, "partial")
        self.eraser_deleted = nil
        return true
    end

    -- For pen/highlighter: raw input hook already finalized the stroke
    -- Just consume the event and ensure delayed refresh is scheduled
    if not self.current_stroke then
        -- Raw input already handled it, just schedule refresh if not already pending
        self:scheduleDelayedRefresh()
        return true
    end

    -- Fallback: finalize stroke via gesture system
    if #self.current_stroke.points >= 1 then
        -- Finalize the stroke
        self:anchorIfScroll(self.current_stroke)
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        self:saveStrokes()

        -- Add to undo stack
        self:pushUndo({ type = "add", stroke_idx = #self.strokes })
        self:assignStrokeToGroup(#self.strokes)

        logger.dbg("Pencil: stroke completed with", #self.current_stroke.points, "points")
    end

    self.current_stroke = nil

    -- Schedule delayed refresh - will fire after user stops writing
    -- If user starts another stroke, the refresh will be canceled and rescheduled
    self:scheduleDelayedRefresh()

    return true
end

-- Get current page number (stable reference for both paged and rolling modes)
function Pencil:getCurrentPage()
    if self.ui.paging then
        return self.view.state.page
    else
        -- For rolling/EPUB documents use the rendered page number directly.
        -- Do NOT derive it from getXPointer(): that returns the bookmark of
        -- the top of the page, which for a page starting mid-paragraph points
        -- at the paragraph's start on the PREVIOUS page. Two pages then share
        -- one key and strokes show up on the following page too.
        local doc = self.ui.document
        if doc.getCurrentPage then
            local ok, pn = pcall(doc.getCurrentPage, doc)
            if ok and type(pn) == "number" and pn > 0 then
                return pn
            end
        end
        -- Fallback: convert XPointer to page number
        local xp = self.ui.document:getXPointer()
        if xp and self.ui.document.getPageFromXPointer then
            return self.ui.document:getPageFromXPointer(xp)
        end
        -- Fallback to XPointer if conversion not available
        return xp
    end
end

-- Which part of the page is on screen (paged documents only).
-- Strokes are stored in screen coordinates. A PDF page that is taller than
-- the screen (zoom "fit width", landscape, ...) is shown in several screens,
-- and turning the page first moves within the SAME page number. Without this
-- key a stroke drawn on the upper half also showed on the lower half.
-- Returns nil where the page number alone identifies the screen (EPUB) and
-- in continuous scroll mode (no fixed screens).
function Pencil:getViewKey()
    if not self.ui or not self.ui.paging then return nil end
    local view = self.view
    if not view or view.page_scroll then return nil end
    local va = view.visible_area
    local zoom = view.state and view.state.zoom
    if not va or not zoom then return nil end
    return string.format("%d,%d,%d", math.floor(va.x + 0.5), math.floor(va.y + 0.5),
        math.floor(zoom * 10000 + 0.5))
end

-- Index key of a stroke (or note): its page, plus the screen part if known
local function indexKey(page, vkey)
    if vkey then return tostring(page) .. "|" .. vkey end
    return page
end

-- ---------------------------------------------------------------------------
-- Page-anchored strokes (continuous scroll mode of PDFs/CBZ).
-- In scroll mode the text moves under the screen, so screen coordinates are
-- meaningless. Strokes drawn there are stored in coordinates of their PDF
-- page (stroke.anchor = true, stroke.dpts = unzoomed page coordinates) and
-- projected to the screen (stroke.points) whenever the view changes. All the
-- drawing / erasing / lasso code keeps working on stroke.points.
-- ---------------------------------------------------------------------------

local function docKey(page) return tostring(page) .. "|doc" end

-- Pages on screen and how each maps to the screen, or nil (EPUB).
-- Same arithmetic as ReaderView:getScrollPagePosition / getSinglePagePosition.
function Pencil:getPageLayout()
    if not self.ui or not self.ui.paging then return nil end
    local view = self.view
    if not view then return nil end
    local layout = {}
    if view.page_scroll then
        local gap = view.page_gap and view.page_gap.height or 0
        local top = 0
        for _, st in ipairs(view.page_states or {}) do
            local va, off = st.visible_area, st.offset
            if va and st.zoom and st.zoom > 0 then
                layout[#layout + 1] = { page = st.page, zoom = st.zoom,
                    vx = va.x, vy = va.y, vh = va.h,
                    ox = off and off.x or 0, oy = off and off.y or 0, top = top }
                top = top + va.h + gap
            end
        end
    else
        local st, va = view.state, view.visible_area
        if st and va and st.zoom and st.zoom > 0 and st.page then
            layout[1] = { page = st.page, zoom = st.zoom, vx = va.x, vy = va.y, vh = va.h,
                ox = st.offset and st.offset.x or 0, oy = st.offset and st.offset.y or 0, top = 0 }
        end
    end
    if #layout == 0 then return nil end
    return layout
end

local function layoutSig(layout)
    local t = {}
    for i, e in ipairs(layout) do
        t[i] = string.format("%s:%.5f:%d:%d:%d:%d:%d", tostring(e.page), e.zoom,
            math.floor(e.vx + 0.5), math.floor(e.vy + 0.5), math.floor(e.ox + 0.5),
            math.floor(e.oy + 0.5), math.floor(e.top + 0.5))
    end
    return table.concat(t, ";")
end

local function layoutEntry(layout, page)
    if not layout then return nil end
    for _, e in ipairs(layout) do
        if e.page == page then return e end
    end
    return nil
end

-- Layout entry under screen y (the page block containing it)
local function layoutEntryAt(layout, y)
    for _, e in ipairs(layout) do
        if y < e.top + e.oy + e.vh then return e end
    end
    return layout[#layout]
end

local function toScreen(e, px, py)
    return math.floor(e.ox + px * e.zoom - e.vx + 0.5),
           math.floor(e.top + e.oy + py * e.zoom - e.vy + 0.5)
end

local function toDoc(e, x, y)
    local px = (x - e.ox + e.vx) / e.zoom
    local py = (y - e.top - e.oy + e.vy) / e.zoom
    -- two decimals are plenty (page units) and keep the file small
    return math.floor(px * 100 + 0.5) / 100, math.floor(py * 100 + 0.5) / 100
end

function Pencil:isScrollMode()
    return self.ui ~= nil and self.ui.paging ~= nil and self.view ~= nil
        and self.view.page_scroll and true or false
end

-- Recompute stroke.dpts from stroke.points (after drawing, splitting, moving)
function Pencil:syncDocPoints(stroke, layout)
    local e = layoutEntry(layout or self:getPageLayout(), stroke.page)
    if not e then return false end
    local d = {}
    for i, pt in ipairs(stroke.points) do
        local px, py = toDoc(e, pt.x, pt.y)
        d[i] = { x = px, y = py, p = pt.p }
    end
    stroke.dpts = d
    stroke._pz = e.zoom
    return true
end

-- Turn a stroke just drawn in scroll mode into a page-anchored one
function Pencil:anchorStroke(stroke)
    local layout = self:getPageLayout()
    if not layout or not stroke.points or #stroke.points == 0 then return false end
    local e = layoutEntryAt(layout, stroke.points[1].y)
    stroke.page = e.page
    stroke.vkey = nil
    stroke.anchor = true
    stroke._bbox = nil
    self:syncDocPoints(stroke, layout)
    return true
end

-- New stroke committed: anchor it to its page when in scroll mode
function Pencil:anchorIfScroll(stroke)
    if stroke and not stroke.anchor and self:isScrollMode() and self:anchorStroke(stroke) then
        stroke._just_anchored = true
    end
end

-- Same for a sticky note
function Pencil:anchorNote(n)
    local layout = self:getPageLayout()
    if not layout then return end
    local e = layoutEntryAt(layout, n.y)
    n.page, n.vkey, n.anchor = e.page, nil, true
    n.px, n.py = toDoc(e, n.x, n.y)
end

-- Make stroke.points of all anchored strokes on screen match the current
-- view. Cheap when nothing moved (signature compare).
function Pencil:ensureProjection()
    if not self.n_anchored or self.n_anchored == 0 then return nil end
    local layout = self:getPageLayout()
    if not layout then return nil end
    local sig = layoutSig(layout)
    if sig ~= self._proj_sig then
        self._proj_sig = sig
        for _, e in ipairs(layout) do
            for _, idx in ipairs(self.page_strokes[docKey(e.page)] or {}) do
                local stroke = self.strokes[idx]
                if stroke and stroke.dpts then
                    local pts = {}
                    for i, d in ipairs(stroke.dpts) do
                        local x, y = toScreen(e, d.x, d.y)
                        pts[i] = { x = x, y = y, p = d.p }
                    end
                    stroke.points = pts
                    stroke._bbox = nil
                    stroke._pz = e.zoom
                end
            end
        end
    end
    return layout
end

-- Index a stroke by page for quick lookup
function Pencil:indexStroke(stroke_idx, page)
    local stroke = self.strokes and self.strokes[stroke_idx]
    local key
    if stroke and stroke.anchor then
        key = docKey(stroke.page or page)
        self.n_anchored = (self.n_anchored or 0) + 1
        if stroke._just_anchored then
            stroke._just_anchored = nil   -- drawn now: points already on screen
        else
            self._proj_sig = nil          -- project it on next use
        end
    else
        key = indexKey((stroke and stroke.page) or page, stroke and stroke.vkey)
    end
    if not self.page_strokes[key] then
        self.page_strokes[key] = {}
    end
    table.insert(self.page_strokes[key], stroke_idx)
end

local NO_INDICES = setmetatable({}, { __newindex = function() error("read-only") end })

-- Stroke indices visible on `page` in the current view: strokes drawn in
-- this exact view, plus older strokes saved without a view key.
function Pencil:pageIndices(page)
    if page == nil then return NO_INDICES end
    local current = (page == self:getCurrentPage())
    local vkey = current and self:getViewKey() or nil
    local lists, n = {}, 0
    local legacy = self.page_strokes[page]
    if legacy and #legacy > 0 then n = n + 1; lists[n] = legacy end
    if vkey then
        local keyed = self.page_strokes[indexKey(page, vkey)]
        if keyed and #keyed > 0 then n = n + 1; lists[n] = keyed end
    end
    -- page-anchored strokes of every page on screen (scroll mode shows several)
    local layout = current and self:ensureProjection() or nil
    if layout then
        for _, e in ipairs(layout) do
            local docs = self.page_strokes[docKey(e.page)]
            if docs and #docs > 0 then n = n + 1; lists[n] = docs end
        end
    elseif not current and self.n_anchored and self.n_anchored > 0 then
        local docs = self.page_strokes[docKey(page)]
        if docs and #docs > 0 then n = n + 1; lists[n] = docs end
    end
    if n == 0 then return NO_INDICES end
    if n == 1 then return lists[1] end
    local merged = {}
    for _, l in ipairs(lists) do
        for i = 1, #l do merged[#merged + 1] = l[i] end
    end
    table.sort(merged)
    return merged
end

-- Does a note belong to the current screen?
function Pencil:noteVisible(n, page)
    if n.anchor then
        local e = layoutEntry(self:getPageLayout(), n.page)
        if not e or not n.px then return false end
        n.x, n.y = toScreen(e, n.px, n.py)
        return true
    end
    return n.page == page and (n.vkey == nil or n.vkey == self:getViewKey())
end

-- Get an XPointer for a screen-space position on the current rolling-mode
-- page. Used to remember WHERE an annotation lives (so it can be re-resolved
-- to a post-rotation page) rather than just the top of the page it was
-- drawn on. Returns nil for paging docs or when the API is unavailable.
function Pencil:getXPointerAtBboxCenter(bbox)
    if not bbox then return nil end
    if not self.ui.rolling then return nil end
    if not self.ui.document or not self.ui.document.getTextFromPositions then
        return nil
    end
    local cx = math.floor((bbox.x0 + bbox.x1) / 2)
    local cy = math.floor((bbox.y0 + bbox.y1) / 2)
    local ok, range = pcall(self.ui.document.getTextFromPositions,
        self.ui.document, { x = cx, y = cy }, { x = cx, y = cy }, true)
    if ok and range and range.pos0 then
        return range.pos0
    end
    -- Fallback: nearest-line xpointer via the current scroll top.
    if self.ui.document.getXPointer then
        local ok2, xp = pcall(self.ui.document.getXPointer, self.ui.document)
        if ok2 and xp then return xp end
    end
    return nil
end

-- Resolve a group's page number in the current layout. For paging docs (PDF)
-- the saved group.page is stable. For rolling docs (EPUB) page numbers shift
-- with rotation / font / spacing changes, so re-derive from the saved
-- XPointer if we have one. Falls back to the original page number when no
-- XPointer was stored (older groups created before this code shipped).
function Pencil:getGroupCurrentPage(group)
    if not group then return nil end
    if self.ui.rolling and group.xpointer
            and self.ui.document and self.ui.document.getPageFromXPointer then
        local ok, pn = pcall(self.ui.document.getPageFromXPointer,
            self.ui.document, group.xpointer)
        if ok and pn then return pn end
    end
    return group.page
end

-- Lazily store / upgrade an XPointer for rolling-doc groups on the current
-- page. Two paths:
--   1. Legacy group with no xpointer: drop in the page-top xpointer so at
--      least same-rotation matching keeps working.
--   2. Group whose xpointer was stored at page-top (old buggy code) or for
--      any reason isn't marked precise: when we're on the same page AND in
--      the rotation the annotation was captured at, the bbox coords are
--      valid on the current screen, so we can resolve a precise per-bbox
--      xpointer. Mark xpointer_v2 to avoid repeated work.
function Pencil:backfillGroupXPointers()
    if not self.ui.rolling then return end
    if not self.ui.document or not self.ui.document.getXPointer
            or not self.ui.document.getPageFromXPointer then
        return
    end
    local cur_page = self:getCurrentPage()
    local cur_rot = Screen:getRotationMode()
    local cur_xp_top = nil
    for _, group in ipairs(self.annotation_groups or {}) do
        if group.page == cur_page then
            local upgraded = false
            if not group.xpointer_v2 and group.bbox
                    and (group.image_rotation == nil
                            or group.image_rotation == cur_rot) then
                local precise = self:getXPointerAtBboxCenter(group.bbox)
                if precise then
                    group.xpointer = precise
                    group.xpointer_v2 = true
                    self.image_data_dirty = true
                    upgraded = true
                end
            end
            if not upgraded and not group.xpointer then
                cur_xp_top = cur_xp_top or self.ui.document:getXPointer()
                if cur_xp_top then
                    group.xpointer = cur_xp_top
                    self.image_data_dirty = true
                end
            end
        end
    end
end

-- Assign a newly-added stroke to an annotation group (or create a new one).
-- Called after a stroke is finalized and inserted into self.strokes.
-- @param stroke_idx number  index of the stroke in self.strokes
-- @param skip_bookmark boolean  if true, skip bookmark sync (used during bootstrap)
function Pencil:assignStrokeToGroup(stroke_idx, skip_bookmark)
    local stroke = self.strokes[stroke_idx]
    if not stroke then return end

    local bbox = PencilGeometry.computeStrokeBbox(stroke)
    if not bbox then return end

    local stroke_time = stroke.datetime or 0
    local best_group = nil

    for _, group in ipairs(self.annotation_groups) do
        if group.page == stroke.page then
            local time_diff = math.abs(stroke_time - (group.datetime_last or group.datetime or 0))
            if time_diff <= GROUP_TIME_THRESHOLD_S then
                local dist = PencilGeometry.bboxDistance(bbox, group.bbox)
                if dist <= GROUP_SPATIAL_THRESHOLD then
                    best_group = group
                    break
                end
            end
        end
    end

    if best_group then
        -- Merge into existing group
        table.insert(best_group.stroke_indices, stroke_idx)
        best_group.bbox = PencilGeometry.bboxUnion(best_group.bbox, bbox)
        best_group.datetime_last = math.max(best_group.datetime_last or 0, stroke_time)
        -- Update tool to majority
        local pen_count, hl_count = 0, 0
        for _, si in ipairs(best_group.stroke_indices) do
            local s = self.strokes[si]
            if s then
                if s.tool == TOOL_HIGHLIGHTER then hl_count = hl_count + 1
                else pen_count = pen_count + 1 end
            end
        end
        best_group.tool = hl_count > pen_count and TOOL_HIGHLIGHTER or TOOL_PEN
        if not skip_bookmark then
            self:markGroupDirty(best_group)
            -- A merged stroke invalidates the previously captured image (bbox
            -- grew); re-schedule the deferred capture.
            self:removeGroupImage(best_group)
            self:scheduleGroupImageCapture(best_group)
        end
    else
        -- Create new group
        local group = {
            id = "pencil_" .. os.date("%Y%m%d%H%M%S") .. "_" .. stroke_idx,
            page = stroke.page,
            stroke_indices = { stroke_idx },
            bbox = bbox,
            datetime = stroke_time,
            datetime_last = stroke_time,
            tool = (stroke.tool == TOOL_HIGHLIGHTER) and TOOL_HIGHLIGHTER or TOOL_PEN,
        }
        -- For rolling/EPUB docs, capture an XPointer AT THE ANNOTATION'S
        -- POSITION (bbox center) so we can re-resolve which page the
        -- annotation falls on after rotation / font change. CRITICAL: only
        -- valid when we're actually viewing the page this stroke was drawn
        -- on, because getTextFromPositions reads from the currently
        -- rendered page. During a full rebuild (after erase / undo) we
        -- process strokes from every page; for off-current-page strokes
        -- we skip the xpointer and let getGroupCurrentPage fall back to
        -- the saved group.page number. Backfill upgrades them later.
        if stroke.page == self:getCurrentPage() then
            local annot_xp = self:getXPointerAtBboxCenter(bbox)
            if annot_xp then
                group.xpointer = annot_xp
                group.xpointer_v2 = true
            end
        end
        table.insert(self.annotation_groups, group)
        if not skip_bookmark then
            self:markGroupDirty(group)
            self:scheduleGroupImageCapture(group)
        end
    end
end

-- Mark a group as needing a bookmark sync on the next deferred-work flush.
-- Keeps the heavy getPageXPointer / annotation insertion off the writing path.
function Pencil:markGroupDirty(group)
    if not self.experimental_bookmark_sync then return end
    self.dirty_groups = self.dirty_groups or {}
    self.dirty_groups[group.id] = group
end

-- Rebuild all annotation groups from scratch by re-running the grouping algorithm
-- on all existing strokes sorted by datetime. Called after erase/undo operations.
function Pencil:rebuildAnnotationGroups()
    local ok, err = pcall(function()
        -- Remove all existing bookmarks for pencil groups, and cancel any
        -- pending image captures (group ids will change).
        for _, group in ipairs(self.annotation_groups) do
            self:removeGroupBookmark(group)
            self:cancelGroupImageCapture(group.id)
        end

        self.annotation_groups = {}

        -- Build list of {index, datetime} sorted by datetime
        local sorted = {}
        for i, stroke in ipairs(self.strokes) do
            table.insert(sorted, { idx = i, dt = stroke.datetime or 0 })
        end
        table.sort(sorted, function(a, b) return a.dt < b.dt end)

        -- Re-assign each stroke
        for _, entry in ipairs(sorted) do
            self:assignStrokeToGroup(entry.idx)
        end
    end)
    if not ok then
        logger.warn("Pencil: rebuildAnnotationGroups failed:", err)
        self.annotation_groups = self.annotation_groups or {}
    end
    -- Any JPEGs whose stem no longer matches a current group.id are now stale.
    self:purgeOrphanImages()
end

-- Get page number for bookmark display (always numeric).
function Pencil:getPageNumber(page_ref)
    if type(page_ref) == "number" then
        return page_ref
    end
    -- For XPointer (rolling docs), try to convert
    if self.ui.document and self.ui.document.getPageFromXPointer then
        local pn = self.ui.document:getPageFromXPointer(page_ref)
        if pn then return pn end
    end
    return 0
end

-- Get the bookmark page reference for a group.
-- For paging mode (PDF), this is the page number.
-- For rolling mode (EPUB), this must be an XPointer.
function Pencil:getBookmarkPageRef(group_page)
    if self.ui.rolling and self.ui.document and self.ui.document.getPageXPointer then
        -- group.page is a number (from getCurrentPage), convert back to XPointer
        return self.ui.document:getPageXPointer(group_page)
    end
    return group_page
end

-- Sync a group's bookmark into KOReader's annotation system.
function Pencil:syncGroupBookmark(group)
    if not self.experimental_bookmark_sync then return end
    if not self.ui or not self.ui.annotation then
        logger.dbg("Pencil: annotation module not available, skipping bookmark sync")
        return
    end
    if not self.ui.annotation.annotations then
        logger.dbg("Pencil: annotations not loaded yet, skipping bookmark sync")
        return
    end

    local ok, err = pcall(function()
        -- Remove existing bookmark for this group first
        self:removeGroupBookmark(group)

        local pageno = self:getPageNumber(group.page)
        local bookmark_page = self:getBookmarkPageRef(group.page)
        local chapter = ""
        if self.ui.toc and self.ui.toc.getTocTitleByPage then
            chapter = self.ui.toc:getTocTitleByPage(bookmark_page) or ""
        end

        local datetime = group.id  -- use group id as unique datetime key
        group.bookmark_datetime = datetime

        local item = {
            page = bookmark_page,
            datetime = datetime,
            text = string.format("Pencil annotation on page %d", pageno),
            chapter = chapter,
        }

        if self.ui.annotation.addItem then
            self.ui.annotation:addItem(item)
            logger.dbg("Pencil: synced bookmark for group", group.id, "on page", pageno)
        else
            logger.warn("Pencil: annotation.addItem not available")
        end
    end)
    if not ok then
        logger.warn("Pencil: bookmark sync failed:", err)
    end
end

-- Remove a group's bookmark from KOReader's annotation system.
function Pencil:removeGroupBookmark(group)
    if not self.experimental_bookmark_sync then return end
    if not self.ui or not self.ui.annotation then return end
    if not group.bookmark_datetime then return end

    local ok, err = pcall(function()
        local annotations = self.ui.annotation.annotations
        if not annotations then return end

        for i, ann in ipairs(annotations) do
            if ann.datetime == group.bookmark_datetime then
                table.remove(annotations, i)
                logger.dbg("Pencil: removed bookmark for group", group.id)
                return
            end
        end
    end)
    if not ok then
        logger.warn("Pencil: bookmark removal failed:", err)
    end
end

-- Remove ALL pencil bookmarks from KOReader's annotation system.
-- Used before re-syncing to avoid duplicates.
-- Note: always runs regardless of feature flag, so disabling cleans up.
function Pencil:removeAllPencilBookmarks()
    if not self.ui or not self.ui.annotation then return end
    local annotations = self.ui.annotation.annotations
    if not annotations then return end

    -- Remove in reverse order to maintain indices
    for i = #annotations, 1, -1 do
        if annotations[i].datetime and annotations[i].datetime:match("^pencil_") then
            table.remove(annotations, i)
        end
    end
end

-- Sync all annotation groups to bookmarks (used after load/rebuild).
function Pencil:syncAllBookmarks()
    if not self.experimental_bookmark_sync then return end

    -- Clean slate: remove all pencil bookmarks first to avoid duplicates
    self:removeAllPencilBookmarks()

    for _, group in ipairs(self.annotation_groups) do
        self:syncGroupBookmark(group)
    end
    logger.info("Pencil: synced", #self.annotation_groups, "annotation group bookmarks")
end

------------------------------------------------------------------------------
-- Annotation image capture & preview (issue #51)
------------------------------------------------------------------------------

-- Directory holding per-group preview JPEGs for this document.
function Pencil:getImagesDir()
    if not self.ui or not self.ui.doc_settings then return nil end
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if not sidecar_dir then return nil end
    return sidecar_dir .. "/pencil_images"
end

function Pencil:ensureImagesDir()
    local dir = self:getImagesDir()
    if not dir then return nil end
    local ok, err = lfs.mkdir(dir)
    if not ok and err ~= "File exists" then
        logger.warn("Pencil: failed to create images dir:", err)
        return nil
    end
    return dir
end

function Pencil:getGroupImagePath(group)
    local dir = self:getImagesDir()
    if not dir or not group or not group.image_path then return nil end
    return dir .. "/" .. group.image_path
end

-- Render the captured-page-context image for a group into a Blitbuffer and
-- write it as a JPEG. Returns true on success.
function Pencil:captureGroupImage(group)
    if not group or not group.bbox then return false end
    if not self.view or not self.view.paintTo then return false end

    local dir = self:ensureImagesDir()
    if not dir then return false end

    -- Only capture if the group's page matches the current pagination;
    -- otherwise ReaderView would render the wrong content. For rolling docs
    -- this uses the group's XPointer (rotation-stable) when available.
    local gpage = self:getGroupCurrentPage(group)
    if gpage ~= self:getCurrentPage() then
        logger.dbg("Pencil: captureGroupImage: page mismatch (group=", tostring(gpage),
            " current=", tostring(self:getCurrentPage()), "), deferring")
        return false
    end

    -- Capture a full-screen-width strip vertically bounded by the bbox + a
    -- small margin. This gives the user enough context (full line of text)
    -- when they preview the annotation from the bookmark list or rotation
    -- badge, instead of a tight crop that just shows the strokes.
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local rect = PencilGeometry.captureStripRect(
        group.bbox, sw, sh, IMAGE_CAPTURE_V_MARGIN_PX, IMAGE_MIN_HEIGHT_PX)
    local w = math.floor(rect.x1 - rect.x0)
    local h = math.floor(rect.y1 - rect.y0)
    if w < 8 or h < 8 then return false end

    -- Allocate offscreen buffer of the same type as Screen.bb so paintTo writes
    -- pixels in the format ReaderView expects.
    local bb_type = Screen.bb:getType()
    local ok_bb, off_bb = pcall(Blitbuffer.new, w, h, bb_type)
    if not ok_bb or not off_bb then
        logger.warn("Pencil: failed to allocate offscreen buffer for capture")
        return false
    end

    -- Paint the page (and other plugins / highlights / dogear etc.) into the
    -- offscreen buffer. The (-x, -y) offset places the captured page region
    -- at (0, 0) inside off_bb; Blitbuffer paints clip to buffer bounds.
    local x0, y0 = math.floor(rect.x0), math.floor(rect.y0)
    self._capturing = true
    local ok_paint, paint_err = pcall(self.view.paintTo, self.view, off_bb, -x0, -y0)
    self._capturing = false
    if not ok_paint then
        logger.warn("Pencil: ReaderView paint to offscreen failed:", paint_err)
        if off_bb.free then off_bb:free() end
        return false
    end

    -- Render this group's strokes over the painted page background.
    for _, idx in ipairs(group.stroke_indices or {}) do
        local stroke = self.strokes[idx]
        if stroke then
            self:renderStrokeOffset(off_bb, stroke, -x0, -y0)
        end
    end

    -- Downscale if longer side exceeds IMAGE_MAX_DIM (storage / encode budget).
    local final_bb = off_bb
    local longer = math.max(w, h)
    if longer > IMAGE_MAX_DIM and off_bb.scale then
        local scale = IMAGE_MAX_DIM / longer
        local sw_new = math.max(1, math.floor(w * scale))
        local sh_new = math.max(1, math.floor(h * scale))
        local ok_scale, scaled = pcall(off_bb.scale, off_bb, sw_new, sh_new)
        if ok_scale and scaled then
            final_bb = scaled
        end
    end

    -- Encode + write.
    local filename = group.id .. ".jpg"
    local fullpath = dir .. "/" .. filename
    local ok_write, write_err = pcall(final_bb.writeJPG, final_bb, fullpath, IMAGE_JPEG_QUALITY)

    -- Free buffers we own (final_bb might be the same object as off_bb after
    -- skipping the downscale path).
    if final_bb ~= off_bb and final_bb.free then final_bb:free() end
    if off_bb.free then off_bb:free() end

    if not ok_write then
        logger.warn("Pencil: failed to write JPEG:", write_err)
        return false
    end

    group.image_path = filename
    group.image_rotation = Screen:getRotationMode()
    self.image_data_dirty = true
    logger.info("Pencil: captured image for group", group.id, "rotation", group.image_rotation, "->", fullpath)
    return true
end

-- Variant of renderStroke that translates points by (dx, dy) before drawing.
-- Used during capture to render a group's strokes onto an offscreen buffer
-- whose origin corresponds to the bbox top-left.
function Pencil:renderStrokeOffset(bb, stroke, dx, dy, preview)
    if not stroke or not stroke.points or #stroke.points < 1 then return end

    local tool = stroke.tool or TOOL_PEN
    local width = stroke.width or self.tool_settings[tool].width or 3
    local color = stroke.color or self.tool_settings[tool].color or Blitbuffer.COLOR_BLACK

    if Screen.night_mode and stroke.color_name ~= "Black" and stroke.color_name ~= "Gray" then
        color = color:invert()
    end

    local is_highlighter = (tool == TOOL_HIGHLIGHTER)
    if is_highlighter then
        color = stroke.color or Blitbuffer.Color8(0xDD)
    end

    if #stroke.points == 1 then
        local p = stroke.points[1]
        local half_w = math.floor(width / 2)
        if is_highlighter then
            self:drawHighlighterSegment(bb, p.x + dx, p.y + dy, p.x + dx, p.y + dy, width, color, preview)
        elseif stroke.pen_type then
            self:drawPenSegment(bb, stroke, p, p, dx, dy, width, color)
        else
            bb:paintRectRGB32(p.x + dx - half_w, p.y + dy - half_w, width, width, color)
        end
    else
        for i = 2, #stroke.points do
            local p1 = stroke.points[i - 1]
            local p2 = stroke.points[i]
            if is_highlighter then
                self:drawHighlighterSegment(bb, p1.x + dx, p1.y + dy, p2.x + dx, p2.y + dy, width, color, preview)
            else
                self:drawPenSegment(bb, stroke, p1, p2, dx, dy, width, color)
            end
        end
    end
end

-- Schedule a deferred capture for the group. If a capture is already pending
-- for this group id, cancel and re-arm so we only capture once after the
-- grouping window has settled.
-- delay (optional): seconds before firing. Defaults to IMAGE_CAPTURE_DEBOUNCE_S
-- so we wait past the GROUP_TIME_THRESHOLD_S merge window before capturing a
-- fresh stroke. Backfill uses a shorter delay since no merges are pending.
function Pencil:scheduleGroupImageCapture(group, delay)
    if not group or not group.id then return end
    self.pending_image_captures = self.pending_image_captures or {}

    self:cancelGroupImageCapture(group.id)

    local cb = function()
        self.pending_image_captures[group.id] = nil
        -- The group might have been deleted by the eraser by now.
        local current = nil
        for _, g in ipairs(self.annotation_groups) do
            if g.id == group.id then current = g; break end
        end
        if not current then return end
        local ok, err = pcall(self.captureGroupImage, self, current)
        if not ok then
            logger.warn("Pencil: captureGroupImage error:", err)
        end
        if self.image_data_dirty then
            self.image_data_dirty = false
            self:saveStrokes()
        end
    end

    self.pending_image_captures[group.id] = cb
    local d = delay or IMAGE_CAPTURE_DEBOUNCE_S
    UIManager:scheduleIn(d, cb)
    logger.dbg("Pencil: scheduled image capture for group", group.id, "in", d, "seconds")
end

function Pencil:cancelGroupImageCapture(group_id)
    if not self.pending_image_captures then return end
    local cb = self.pending_image_captures[group_id]
    if cb then
        UIManager:unschedule(cb)
        self.pending_image_captures[group_id] = nil
    end
end

-- Run all pending captures synchronously and clear the queue. Called on
-- document close / suspend so we don't lose freshly drawn annotations.
function Pencil:flushPendingCaptures()
    if not self.pending_image_captures then return end
    local pending = self.pending_image_captures
    self.pending_image_captures = {}
    for _, cb in pairs(pending) do
        UIManager:unschedule(cb)
        local ok, err = pcall(cb)
        if not ok then
            logger.warn("Pencil: flushPendingCaptures error:", err)
        end
    end
end

function Pencil:removeGroupImage(group)
    local path = self:getGroupImagePath(group)
    if not path then return end
    os.remove(path)
    group.image_path = nil
    group.image_rotation = nil
end

-- Delete any JPEG in pencil_images/ whose stem isn't a current group.id.
-- Called after group rebuilds (which regenerate ids) and during saveStrokes.
function Pencil:purgeOrphanImages()
    local dir = self:getImagesDir()
    if not dir then return end
    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return end

    local valid = {}
    for _, g in ipairs(self.annotation_groups or {}) do
        if g.image_path then
            valid[g.image_path] = true
        end
    end

    for file in lfs.dir(dir) do
        if file ~= "." and file ~= ".." and file:match("%.jpg$") and not valid[file] then
            os.remove(dir .. "/" .. file)
            logger.dbg("Pencil: purged orphan image", file)
        end
    end
end

-- Open the saved image for a group in an ImageViewer popup.
function Pencil:showGroupImagePreview(group)
    if not group then return end
    local path = self:getGroupImagePath(group)
    if not path then
        UIManager:show(InfoMessage:new{
            text = _("No saved image for this annotation yet."),
            timeout = 2,
        })
        return
    end
    local attr = lfs.attributes(path)
    if not attr then
        UIManager:show(InfoMessage:new{
            text = _("Annotation image is missing on disk."),
            timeout = 2,
        })
        return
    end
    local ImageViewer = require("ui/widget/imageviewer")
    local pageno = self:getPageNumber(group.page) or 0
    UIManager:show(ImageViewer:new{
        file = path,
        with_title_bar = true,
        title_text = T(_("Annotation - page %1"), pageno),
        fullscreen = false,
    })
end

-- Compute the on-screen badge rect for a stale-rotation group. The badge is
-- pinned to the right edge of the screen (i.e. in the margin) at a vertical
-- position proportional to the original bbox center Y, so multiple stale
-- annotations stack along the right side in roughly their original reading
-- order.
function Pencil:getGroupBadgeRect(group)
    if not group or not group.bbox or not group.image_rotation then return nil end
    local current_rot = Screen:getRotationMode()
    if current_rot == group.image_rotation then return nil end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    -- Source-rotation screen height: rotations 0/2 vs 1/3 swap width/height.
    local src_sh = sh
    if (group.image_rotation == 1 or group.image_rotation == 3) ~=
            (current_rot == 1 or current_rot == 3) then
        src_sh = sw
    end

    -- Vertical: proportional remap of the bbox center onto current screen.
    local cy = (group.bbox.y0 + group.bbox.y1) / 2
    local y_fraction = src_sh > 0 and (cy / src_sh) or 0.5
    local target_y = math.floor(y_fraction * sh)

    -- Horizontal: fixed position in the right margin. Simple and reliable;
    -- avoids depending on the document's reported page margins which can
    -- behave unexpectedly across EPUB engines.
    local badge_x = sw - IMAGE_BADGE_SIZE - IMAGE_BADGE_MARGIN_GAP

    local half = math.floor(IMAGE_BADGE_SIZE / 2)
    local x = math.max(0, math.min(sw - IMAGE_BADGE_SIZE, badge_x))
    local y = math.max(0, math.min(sh - IMAGE_BADGE_SIZE, target_y - half))
    return { x = x, y = y, w = IMAGE_BADGE_SIZE, h = IMAGE_BADGE_SIZE }
end

-- Pick a representative color for an annotation group: the first stroke's
-- saved color. Returns nil if no usable color is found, so the caller can
-- fall back to a default.
function Pencil:getGroupColor(group)
    if not group or not group.stroke_indices then return nil end
    for _, idx in ipairs(group.stroke_indices) do
        local stroke = self.strokes[idx]
        if stroke and stroke.color then
            return stroke.color
        end
    end
    return nil
end

function Pencil:renderRotationBadge(bb, group)
    local rect = self:getGroupBadgeRect(group)
    if not rect then return end
    -- Fill matches the annotation color so users can tell badges apart when
    -- a page has annotations in different colors. Black border for
    -- definition, white inner mark to suggest interactivity (and to keep
    -- light colors like gray / highlighter yellow visible).
    -- Must use paintRectRGB32 (not paintRect) to preserve the color channels
    -- of ColorRGB32 fills; paintRect treats the value as a luminance and
    -- would render colored fills as gray.
    local fill = self:getGroupColor(group)
            or Blitbuffer.ColorRGB32(0xCC, 0x00, 0x00, 0xFF)
    bb:paintRectRGB32(rect.x, rect.y, rect.w, rect.h, Blitbuffer.COLOR_BLACK)
    bb:paintRectRGB32(rect.x + 2, rect.y + 2, rect.w - 4, rect.h - 4, fill)
    local inset = math.floor(rect.w / 3)
    bb:paintRectRGB32(rect.x + inset, rect.y + inset,
        rect.w - 2 * inset, rect.h - 2 * inset, Blitbuffer.COLOR_WHITE)
end

-- Compute the list of stale-rotation groups whose badges should be drawn on
-- the current page in the current rotation. Returns nil if no badges should
-- show (no stale groups, or suppressed because a native annotation is also
-- on this page). Shared by paintTo and findGroupBadgeAtPoint to keep
-- drawing and hit-testing in lockstep.
function Pencil:getStaleGroupsForCurrentView()
    local current_rot = Screen:getRotationMode()
    local page = self:getCurrentPage()
    local stale = nil
    local has_native = false
    for _, group in ipairs(self.annotation_groups or {}) do
        local gpage = self:getGroupCurrentPage(group)
        if gpage == page then
            if group.image_rotation == nil
                    or group.image_rotation == current_rot then
                has_native = true
            elseif group.image_path then
                stale = stale or {}
                stale[#stale + 1] = group
            end
        end
    end
    if has_native then return nil end
    return stale
end

-- Hit-test the rotation badges on the current page. Mirrors the drawing
-- logic in paintTo: a badge is tappable iff its group would have its badge
-- drawn by the current render pass.
function Pencil:findGroupBadgeAtPoint(x, y)
    local stale = self:getStaleGroupsForCurrentView()
    if not stale then return nil end
    for _, group in ipairs(stale) do
        local rect = self:getGroupBadgeRect(group)
        if rect
                and x >= rect.x - IMAGE_BADGE_HIT_PAD
                and x <= rect.x + rect.w + IMAGE_BADGE_HIT_PAD
                and y >= rect.y - IMAGE_BADGE_HIT_PAD
                and y <= rect.y + rect.h + IMAGE_BADGE_HIT_PAD then
            return group
        end
    end
    return nil
end

-- Called by the bookmark-list hook on menu select. Returns true if we
-- handled the tap (and the original navigation should be skipped).
function Pencil:tryShowImageForBookmark(item)
    if not item or not item.datetime then return false end
    if not item.datetime:match("^pencil_") then return false end
    -- Find the matching group by id (group.id is stored as the bookmark datetime).
    for _, group in ipairs(self.annotation_groups or {}) do
        if group.id == item.datetime then
            if group.image_path then
                self:showGroupImagePreview(group)
                return true
            end
            return false  -- pencil bookmark but no image yet; fall through to navigate
        end
    end
    return false
end

-- Total disk usage of pencil_images/ for the current document, in bytes.
function Pencil:getImagesSizeBytes()
    local dir = self:getImagesDir()
    if not dir then return 0 end
    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return 0 end
    local total = 0
    for file in lfs.dir(dir) do
        if file ~= "." and file ~= ".." then
            local fattr = lfs.attributes(dir .. "/" .. file)
            if fattr and fattr.size then total = total + fattr.size end
        end
    end
    return total
end

-- Remove all preview images for the current book and clear group references.
function Pencil:purgeAllImages()
    local dir = self:getImagesDir()
    if dir then
        local attr = lfs.attributes(dir)
        if attr and attr.mode == "directory" then
            for file in lfs.dir(dir) do
                if file ~= "." and file ~= ".." then
                    os.remove(dir .. "/" .. file)
                end
            end
        end
    end
    for _, group in ipairs(self.annotation_groups or {}) do
        group.image_path = nil
        group.image_rotation = nil
    end
    self:saveStrokes()
    UIManager:setDirty(self.view, "ui")
end

-- Re-capture missing images for groups on the currently visible page.
-- Called from onReaderReady and onPageUpdate so the user sees rotation
-- badges work without needing to redraw the annotation. Uses a short delay
-- so the page has fully rendered before we ask ReaderView to repaint into
-- our offscreen, but no merge-window wait since the group is already final.
function Pencil:backfillMissingImages()
    local page = self:getCurrentPage()
    for _, group in ipairs(self.annotation_groups or {}) do
        if self:getGroupCurrentPage(group) == page and not group.image_path then
            self:scheduleGroupImageCapture(group, 1.0)
        end
    end
end

-- Install a one-time class-level patch on ReaderBookmark so that
-- long-pressing a pencil bookmark that has a saved image opens a
-- full-screen ImageViewer popup directly, instead of the standard
-- bookmark detail dialog. Closing the ImageViewer returns to the
-- bookmark list with nothing else stacked behind it.
--
-- Falls through to the standard dialog for non-pencil bookmarks and for
-- pencil bookmarks without a saved image. Short-tap still navigates to
-- the bookmark (default behavior, untouched).
function Pencil:installBookmarkHook()
    if _bookmark_hook_installed then return end

    local ok, ReaderBookmark = pcall(require, "apps/reader/modules/readerbookmark")
    if not ok or not ReaderBookmark or not ReaderBookmark.showBookmarkDetails then
        logger.warn("Pencil: ReaderBookmark module not available, skipping hook")
        return
    end

    local original_showBookmarkDetails = ReaderBookmark.showBookmarkDetails
    function ReaderBookmark:showBookmarkDetails(item_or_index)
        local item = type(item_or_index) == "table"
            and item_or_index
            or (self.ui.annotation and self.ui.annotation.annotations
                    and self.ui.annotation.annotations[item_or_index])
        if item and item.datetime and item.datetime:match("^pencil_")
                and _active_pencil and _active_pencil.annotation_groups then
            for _, group in ipairs(_active_pencil.annotation_groups) do
                if group.id == item.datetime and group.image_path then
                    local path = _active_pencil:getGroupImagePath(group)
                    if path and lfs.attributes(path) then
                        _active_pencil:showGroupImagePreview(group)
                        return true  -- suppress standard dialog
                    end
                    break
                end
            end
        end
        return original_showBookmarkDetails(self, item_or_index)
    end

    _bookmark_hook_installed = true
    logger.info("Pencil: installed bookmark list hook")
end

-- Rebuild page index from strokes
function Pencil:rebuildPageIndex()
    self.page_strokes = {}
    self.n_anchored = 0
    self._proj_sig = nil
    for i, stroke in ipairs(self.strokes) do
        self:indexStroke(i, stroke.page)
    end
end

-- Get strokes for a specific page
function Pencil:getStrokesForPage(page)
    local result = {}
    local indices = self:pageIndices(page)
    for _, idx in ipairs(indices) do
        if self.strokes[idx] then
            table.insert(result, self.strokes[idx])
        end
    end
    return result
end

-- Check if current page has strokes
function Pencil:hasStrokesOnCurrentPage()
    local page = self:getCurrentPage()
    return #self:pageIndices(page) > 0
end

-- Clear strokes on current page
function Pencil:clearPageStrokes()
    local page = self:getCurrentPage()
    local indices_to_remove = self:pageIndices(page)

    if #indices_to_remove == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No annotations found on this page."),
            timeout = 1,
        })
        return
    end

    -- Copy and sort in reverse order to maintain indices during removal
    local sorted_indices = {}
    for _, idx in ipairs(indices_to_remove) do
        table.insert(sorted_indices, idx)
    end
    table.sort(sorted_indices, function(a, b) return a > b end)

    local deleted_strokes = {}
    for _, idx in ipairs(sorted_indices) do
        if self.strokes[idx] then
            table.insert(deleted_strokes, self.strokes[idx])
            table.remove(self.strokes, idx)
        end
    end

    if #deleted_strokes > 0 then
        self:pushUndo({ type = "delete", strokes = deleted_strokes })
    end

    self:rebuildPageIndex()
    self:rebuildAnnotationGroups()
    self:saveStrokes()

    UIManager:show(InfoMessage:new{
        text = T(_("Cleared %1 annotation(s) from page."), #deleted_strokes),
        timeout = 1,
    })
    -- self.view is not on the UI stack: repaint the reader window itself
    UIManager:setDirty(self.ui.dialog or self.ui, "ui")
end

-- Clear all strokes
function Pencil:clearAllStrokes()
    -- Remove all bookmarks for annotation groups + delete their images.
    for _, group in ipairs(self.annotation_groups) do
        self:removeGroupBookmark(group)
        self:cancelGroupImageCapture(group.id)
        self:removeGroupImage(group)
    end
    self.strokes = {}
    self.page_strokes = {}
    self.annotation_groups = {}
    self:saveStrokes()
    -- Belt-and-suspenders: any leftover files get reaped.
    self:purgeOrphanImages()

    UIManager:setDirty(self.view, "ui")
end

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

-- ---------------------------------------------------------------------------
-- Pen pressure: KOReader doesn't keep ABS_PRESSURE for Wacom pens, so we
-- watch the raw EV_ABS events passing through Input:handleTouchEv.
-- ---------------------------------------------------------------------------

local EV_ABS = 3
local ABS_PRESSURE = 0x18
local DEFAULT_PRESSURE_MAX = 4095

function Pencil:installPressureHook()
    local input = Device.input
    if not input or type(input.handleTouchEv) ~= "function" then return end
    Pencil._pressure_owner = self
    if input._pencil_touch_wrapper and input.handleTouchEv == input._pencil_touch_wrapper then
        return   -- already in place
    end
    local orig = input.handleTouchEv
    local wrapper = function(inp, ev)
        if ev and ev.type == EV_ABS and ev.code == ABS_PRESSURE then
            local owner = Pencil._pressure_owner
            if owner then
                owner.cur_pressure = ev.value
                if ev.value > (owner.pressure_max or DEFAULT_PRESSURE_MAX) then
                    owner.pressure_max = ev.value
                end
            end
        end
        return orig(inp, ev)
    end
    input._pencil_touch_wrapper = wrapper
    input.handleTouchEv = wrapper
end

function Pencil:uninstallPressureHook()
    if Pencil._pressure_owner == self then
        Pencil._pressure_owner = nil
    end
end

-- Current pen pressure as 0..1 (gentle curve), or nil without pressure data
function Pencil:getPenPressure()
    local raw = self.cur_pressure
    if not raw then return nil end
    local p = raw / (self.pressure_max or DEFAULT_PRESSURE_MAX)
    if p < 0 then p = 0 elseif p > 1 then p = 1 end
    p = p ^ 0.75   -- light strokes respond more
    return math.floor(p * 100 + 0.5) / 100
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

-- Is a snapshot still usable for blitting onto the current screen?
local function snapshotFits(bb)
    return bb ~= nil and Screen.bb ~= nil
        and bb:getWidth() == Screen:getWidth() and bb:getHeight() == Screen:getHeight()
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
                -- Cheap reject first: eraser circle far from the stroke's box
                local bx, by, bw, bh = strokeBBox(stroke)
                local near = bx and x >= bx - eraser_width and x <= bx + bw + eraser_width
                    and y >= by - eraser_width and y <= by + bh + eraser_width
                if near and self:isPointNearStroke(x, y, stroke, eraser_width) then
                    hit = true
                    if self.partial_eraser then
                        -- Partial erase: keep the parts of the stroke outside
                        -- the eraser radius as new strokes. If the circle only
                        -- grazes the line without removing a point, it's a miss
                        -- (otherwise the stroke would be "deleted" and re-added
                        -- unchanged, polluting undo).
                        local cut
                        pieces, cut = self:splitStrokeAtPoint(stroke, x, y, eraser_width)
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
                        local reach = eraser_width + math.floor(strokeDrawWidth(stroke) / 2) + 4
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

-- ---------------------------------------------------------------------------
-- Floating toolbar
-- ---------------------------------------------------------------------------

function Pencil:isToolbarVisible()
    return self.toolbar ~= nil and self.toolbar_shown and self:isPluginOn()
end

-- Which toolbar button shows as active
function Pencil:getToolbarMode()
    if self.pointer_mode then return "pointer" end
    if self.current_tool == TOOL_LASSO then return "lasso" end
    if self.current_tool == TOOL_NOTE then return "note" end
    if self.current_tool == TOOL_HIGHLIGHTER then return "highlighter" end
    if self.current_tool == TOOL_ERASER then return "eraser" end
    return "pen"
end

-- Hit-test in screen (logical) coordinates; nil when outside the toolbar
function Pencil:toolbarHitTest(x, y)
    if not self:isToolbarVisible() then return nil end
    return self.toolbar:hitTest(x, y)
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

-- Run fn, which may change the toolbar's size/position/contents, then repaint
-- and refresh only the union of the area before and after.
function Pencil:changeToolbar(fn)
    local before = self:isToolbarVisible() and self.toolbar:getRect() or nil
    fn()
    local after = self:isToolbarVisible() and self.toolbar:getRect() or nil
    local region = unionRect(before, after)
    if region then
        UIManager:setDirty(self.ui.dialog or self.ui, function()
            return "ui", Geom:new(region)
        end)
    end
end

-- Kept for callers from earlier versions
function Pencil:refreshToolbar()
    self:changeToolbar(function() end)
end

function Pencil:isFlyoutOpen()
    return self:isToolbarVisible() and self.toolbar.flyout ~= nil and self.toolbar.expanded
end

function Pencil:closeFlyout()
    if self.toolbar and self.toolbar.flyout then
        self:changeToolbar(function()
            self.toolbar.flyout = nil
        end)
    end
end

-- Width presets per tool, shown in the flyouts (like the Scribe's own toolbar)
local WIDTH_LABELS = { "Fein", "Dünn", "Mittel", "Dick", "Sehr dick" }
local TOOL_WIDTHS = {
    [TOOL_PEN] = { 2, 3, 5, 8, 12 },
    [TOOL_HIGHLIGHTER] = { 10, 16, 22, 30, 40 },
    [TOOL_ERASER] = { 10, 15, 20, 28, 40 },
}

-- Index of the preset closest to the tool's current width
function Pencil:getWidthLevel(tool)
    local presets = TOOL_WIDTHS[tool]
    local w = self.tool_settings[tool].width or presets[3]
    local best, best_d = 3, math.huge
    for i, pw in ipairs(presets) do
        local d = math.abs(pw - w)
        if d < best_d then best, best_d = i, d end
    end
    return best
end

function Pencil:setWidthLevel(tool, level)
    local presets = TOOL_WIDTHS[tool]
    if presets and presets[level] then
        self.tool_settings[tool].width = presets[level]
        self:saveSettings()
    end
end

-- Rows for the toolbar flyouts (see lib/toolbar.lua getFlyout)
function Pencil:getFlyoutRows(kind)
    local rows = {}
    if kind == TOOL_PEN then
        local current_type = self.tool_settings[TOOL_PEN].pen_type or PEN_TYPE_PEN
        for _, t in ipairs({
            { PEN_TYPE_PEN, "Stift" },
            { PEN_TYPE_FOUNTAIN, "Füller" },
            { PEN_TYPE_MARKER, "Marker" },
            { PEN_TYPE_PENCIL, "Bleistift" },
        }) do
            table.insert(rows, { id = "pt:" .. t[1], text = t[2], selected = (current_type == t[1]) })
        end
        local level = self:getWidthLevel(TOOL_PEN)
        local items = {}
        for i, w in ipairs(TOOL_WIDTHS[TOOL_PEN]) do
            table.insert(items, {
                id = "w:" .. TOOL_PEN .. ":" .. i,
                sample = { type = "line", width = w },
                selected = (i == level),
            })
        end
        table.insert(rows, { kind = "strip", items = items })
    elseif kind == TOOL_HIGHLIGHTER or kind == TOOL_ERASER then
        local level = self:getWidthLevel(kind)
        for i, w in ipairs(TOOL_WIDTHS[kind]) do
            table.insert(rows, {
                id = "w:" .. kind .. ":" .. i,
                text = WIDTH_LABELS[i],
                sample = { type = (kind == TOOL_ERASER) and "ring" or "bar", width = w },
                selected = (i == level),
            })
        end
        if kind == TOOL_ERASER then
            table.insert(rows, { kind = "sep" })
            if self:hasLassoSelection() then
                table.insert(rows, { id = "delete_selection", text = "Auswahl löschen" })
            end
            table.insert(rows, { id = "clear_page", text = "Seite löschen" })
        end
    elseif kind == "sidebtn" then
        -- What holding the pen's side button does
        for _, t in ipairs(SIDE_BUTTON_TOOLS) do
            table.insert(rows, { id = "sb:" .. t.id, text = t.text,
                selected = ((self.side_button_tool or SIDE_BUTTON_DEFAULT) == t.id) })
        end
    elseif kind == "more" then
        table.insert(rows, { id = "reset_pos", text = "Position zurücksetzen" })
        table.insert(rows, { id = "transparent", text = "Griff transparent",
            selected = self.toolbar_transparent })
        table.insert(rows, { id = "sidebtn", text = "Stifttaste: " ..
            sideButtonToolName(self.side_button_tool or SIDE_BUTTON_DEFAULT) })
        table.insert(rows, { id = "hide", text = "Leiste ausblenden" })
    end
    return rows
end

function Pencil:toggleFlyout(kind, anchor)
    self:changeToolbar(function()
        local f = self.toolbar.flyout
        if f and f.kind == kind then
            self.toolbar.flyout = nil
        else
            self.toolbar.flyout = { kind = kind, anchor = anchor or kind }
        end
    end)
end

function Pencil:onToolbarAction(id)
    logger.dbg("Pencil: toolbar action", id)
    if id == nil or id == "sep" or id == "fly:" then
        return
    end
    if id:sub(1, 4) == "fly:" then
        return self:onFlyoutAction(id:sub(5))
    end
    if id == "handle" then
        self:changeToolbar(function()
            self.toolbar.flyout = nil
            self.toolbar.expanded = not self.toolbar.expanded
            self.toolbar_expanded = self.toolbar.expanded
        end)
        self:saveSettings()
        return
    end
    if id == "pen" or id == "highlighter" or id == "eraser" then
        if self:getToolbarMode() == id then
            -- Tapping the active tool again opens its options, as on the Scribe
            return self:toggleFlyout(id)
        end
        self:selectTool((id == "pen" and TOOL_PEN)
            or (id == "highlighter" and TOOL_HIGHLIGHTER)
            or TOOL_ERASER)
    elseif id == "lasso" or id == "note" then
        if self:getToolbarMode() ~= id then
            self:selectTool(id == "lasso" and TOOL_LASSO or TOOL_NOTE)
        end
    elseif id == "pointer" then
        self:clearLassoSelection()
        self:changeToolbar(function()
            self.toolbar.flyout = nil
            self.pointer_mode = true
            self.textmark_mode = false
            -- Properly finish any half-done pen gesture (stroke saved, erase
            -- undoable, buffers released) so the pen acts as a finger now
            self:afterLift({ id = -1 })
        end)
    elseif id == "more" then
        self:toggleFlyout("more")
    elseif id == "undo" or id == "redo" then
        self:closeFlyout()
        if id == "undo" then self:undoLastStroke() else self:redoLastStroke() end
    end
end

-- Switch the pen to a tool (leaves pointer mode, closes menus; leaving the
-- lasso drops its selection).
function Pencil:selectTool(tool)
    -- A gesture of the previous tool may still be open (switch during contact)
    self:afterLift({ id = -1 })
    if tool ~= TOOL_LASSO then
        self:clearLassoSelection()
    end
    self:changeToolbar(function()
        self.toolbar.flyout = nil
        self.pointer_mode = false
        self.textmark_mode = false
        if tool == TOOL_NOTE and self.current_tool ~= TOOL_NOTE then
            -- After placing a note, the pen goes back to what it was
            self.tool_before_note = self.current_tool
        end
        self.current_tool = tool
    end)
    self:saveSettings()
end

function Pencil:onFlyoutAction(rid)
    local tool, level = rid:match("^w:(%a+):(%d)$")
    local pen_type = rid:match("^pt:(%a+)$")
    if pen_type then
        self.tool_settings[TOOL_PEN].pen_type = pen_type
        self:saveSettings()
        self:closeFlyout()
    elseif tool then
        self:setWidthLevel(tool, tonumber(level))
        self:closeFlyout()
    elseif rid == "clear_page" then
        self:closeFlyout()
        self:clearPageStrokes()
    elseif rid == "delete_selection" then
        self:closeFlyout()
        self:deleteLassoSelection()
    elseif rid == "reset_pos" then
        self:changeToolbar(function()
            self.toolbar.flyout = nil
            self.toolbar:resetPosition()
        end)
        self:saveSettings()
    elseif rid == "transparent" then
        self:changeToolbar(function()
            self.toolbar.flyout = nil
            self.toolbar_transparent = not self.toolbar_transparent
            self.toolbar.transparent_handle = self.toolbar_transparent
        end)
        self:saveSettings()
    elseif rid == "sidebtn" then
        self:toggleFlyout("sidebtn", "more")
    elseif rid:sub(1, 3) == "sb:" and sideButtonToolName(rid:sub(4)) then
        self.side_button_tool = rid:sub(4)
        self:saveSettings()
        self:closeFlyout()
    elseif rid == "hide" then
        self:closeFlyout()
        self:setToolbarShown(false)
    end
end

-- Show/hide the toolbar (menu entry, "…" menu, or the pen's side button)
function Pencil:setToolbarShown(shown)
    if shown == self.toolbar_shown then return end
    self:changeToolbar(function()
        self.toolbar_shown = shown
        if self.toolbar then self.toolbar.flyout = nil end
        if not shown then
            -- A hidden toolbar must not leave the pen stuck in pointer mode
            self.pointer_mode = false
        end
    end)
    self:saveSettings()
end

-- Finger taps on the toolbar (pen taps are caught in handleStylusSlot)
function Pencil:onToolbarTap(ges)
    if not ges or not ges.pos or self:isOverlayActive() then return false end
    local hit = self:toolbarHitTest(ges.pos.x, ges.pos.y)
    if not hit then
        if self:isFlyoutOpen() then
            -- A tap on the page while a menu is open only closes the menu
            self:closeFlyout()
            return true
        end
        -- Tap on a sticky note icon opens it
        local idx = self:isPluginOn() and self:noteAt(ges.pos.x, ges.pos.y)
        if idx then
            self:openNoteDialog(idx)
            return true
        end
        return false
    end
    self:onToolbarAction(hit)
    return true
end

-- ---------------------------------------------------------------------------
-- Moving the toolbar: drag its round handle (pen or finger).
-- While dragging, the page and strokes are restored from a snapshot taken
-- once without the toolbar, so each move is a memory blit + fast refresh.
-- ---------------------------------------------------------------------------

local DRAG_REFRESH_MS = 30

function Pencil:beginToolbarDrag(x, y)
    local ox, oy = self.toolbar:origin()
    return { sx = x, sy = y, ox = ox, oy = oy, moved = false }
end

function Pencil:updateToolbarDrag(drag, x, y)
    local dx, dy = x - drag.sx, y - drag.sy
    if not drag.moved then
        local thr = Screen:scaleBySize(8)
        if dx * dx + dy * dy < thr * thr then return end
        drag.moved = true
        drag.total = self.toolbar:getRect()      -- includes an open flyout
        self.toolbar.flyout = nil
        drag.snap = self:renderPageSnapshot(true)
    end
    local now = time.now()
    drag.pending_x, drag.pending_y = x, y
    if drag.last and time.to_ms(now - drag.last) < DRAG_REFRESH_MS then
        return  -- the next event (or the lift) will catch up
    end
    drag.last = now
    self:applyToolbarDrag(drag)
end

function Pencil:applyToolbarDrag(drag)
    if not drag.pending_x then return end
    local old = self.toolbar:getRect()
    self.toolbar:moveTo(drag.ox + drag.pending_x - drag.sx, drag.oy + drag.pending_y - drag.sy)
    drag.pending_x, drag.pending_y = nil, nil
    local new = self.toolbar:getRect()
    local u = unionRect(old, new)
    drag.total = unionRect(drag.total, new)
    if drag.snap and snapshotFits(drag.snap) then
        Screen.bb:blitFrom(drag.snap, u.x, u.y, u.x, u.y, u.w, u.h)
        self.toolbar:paintTo(Screen.bb)
        Screen:refreshFast(u.x, u.y, u.w, u.h)
    else
        UIManager:setDirty(self.ui.dialog or self.ui, function()
            return "fast", Geom:new(u)
        end)
    end
end

function Pencil:endToolbarDrag(drag)
    if not drag.moved then
        -- No real movement: it was a tap on the handle
        return self:onToolbarAction("handle")
    end
    self:applyToolbarDrag(drag)
    if drag.snap then
        self:releaseSnapshotBuffer(drag.snap)
        drag.snap = nil
    end
    self:saveSettings()
    -- One clean repaint + gray-capable refresh of everything the drag touched
    local region = drag.total
    UIManager:setDirty(self.ui.dialog or self.ui, function()
        return "ui", Geom:new(region)
    end)
end

-- Finger drag of the handle (pan gesture)
function Pencil:onToolbarPan(ges)
    if not ges or not ges.pos or self:isOverlayActive() then return false end
    if not self.finger_drag then
        local start = ges.start_pos
        if not start or self:toolbarHitTest(start.x, start.y) ~= "handle" then
            return false
        end
        self.finger_drag = self:beginToolbarDrag(start.x, start.y)
    end
    self:updateToolbarDrag(self.finger_drag, ges.pos.x, ges.pos.y)
    return true
end

function Pencil:onToolbarPanRelease(ges)
    local drag = self.finger_drag
    if not drag then return false end
    self.finger_drag = nil
    if ges and ges.pos then
        drag.pending_x, drag.pending_y = ges.pos.x, ges.pos.y
    end
    if drag.moved then
        self:endToolbarDrag(drag)
    end
    return true
end

-- Page (and, unless hide_strokes, our strokes) rendered without the toolbar
-- into an offscreen buffer. nil where blitting isn't safe (night mode).
function Pencil:renderPageSnapshot(keep_strokes)
    if Screen.night_mode or self.sony_dhw_active or not Screen.bb then return nil end
    local bb = self:acquireSnapshotBuffer()
    if not bb then return nil end
    if keep_strokes then
        self._hide_toolbar = true
    else
        self._snapshot_mode = true
    end
    local painted = pcall(self.view.paintTo, self.view, bb, 0, 0)
    self._hide_toolbar = false
    self._snapshot_mode = false
    if not painted then
        self:releaseSnapshotBuffer(bb)
        return nil
    end
    return bb
end

-- ---------------------------------------------------------------------------
-- Pen side button: a short press without touching the screen shows/hides
-- the toolbar. (Holding it while writing still erases, handled by Input.)
-- KOReader has no key event for this button on Kindle, so we look at the
-- raw EV_KEY BTN_STYLUS events passing through Input:handleKeyBoardEv.
-- ---------------------------------------------------------------------------

local BTN_STYLUS = 0x14b   -- linux/input-event-codes.h

-- Is the side button held right now? Input tracks it for the tool rewrite;
-- our own hook (onStylusSideButton) is the fallback.
function Pencil:isSideButtonHeld()
    local inp = Device.input
    return (inp and inp.stylus_eraser_active) or self.side_btn_down ~= nil
end

-- Called for every pen frame. Returns the shortcut tool id of the current
-- contact (nil = no shortcut, use the normal tool). Rewrites slot.tool back
-- to "pen" when the side button made KOReader report an eraser and the
-- shortcut is something else, so the eraser paths don't kick in.
function Pencil:resolveSideButton(slot)
    local TOOL_TYPE_PEN, TOOL_TYPE_ERASER = 1, 2
    local choice = self.side_button_tool or SIDE_BUTTON_DEFAULT
    local contact = slot.id ~= nil and slot.id >= 0
    local held = self:isSideButtonHeld()
    if contact and not self.side_contact_decided then
        self.side_contact_decided = true
        if held and choice ~= "eraser" and choice ~= "off" then
            self.side_contact_tool = choice
        else
            self.side_contact_tool = nil
        end
    end
    local tool = self.side_contact_tool
    if not contact then
        -- this lift frame still belongs to the contact; the next one is fresh
        self.side_contact_decided = false
        self.side_contact_tool = nil
    end
    if held and choice ~= "eraser" and slot.tool == TOOL_TYPE_ERASER then
        slot.tool = TOOL_TYPE_PEN
    end
    return tool
end

-- Shortcut id -> tool (+ pen type for pen shortcuts)
function Pencil:sideButtonEffectiveTool(id)
    local pt = id:match("^pen:(%a+)$")
    if pt then return TOOL_PEN, pt end
    if id == "highlighter" then return TOOL_HIGHLIGHTER end
    if id == "lasso" then return TOOL_LASSO end
    if id == "note" then return TOOL_NOTE end
    return self.current_tool
end
local SIDE_BUTTON_TAP_MS = 1000

function Pencil:installStylusButtonHook()
    local input = Device.input
    if not input or type(input.handleKeyBoardEv) ~= "function" then return end
    Pencil._side_button_owner = self
    if input._pencil_kbd_orig then return end   -- already wrapped
    local orig = input.handleKeyBoardEv
    input._pencil_kbd_orig = orig
    input.handleKeyBoardEv = function(inp, ev)
        local owner = Pencil._side_button_owner
        if owner and ev and ev.code == BTN_STYLUS then
            local ok, err = pcall(owner.onStylusSideButton, owner, ev.value)
            if not ok then logger.warn("Pencil: side button hook", err) end
        end
        return orig(inp, ev)
    end
end

function Pencil:uninstallStylusButtonHook()
    if Pencil._side_button_owner == self then
        Pencil._side_button_owner = nil
    end
end

function Pencil:onStylusSideButton(value)
    if value == 1 then
        self.side_btn_down = time.now()
        self.side_btn_contact = false
    elseif value == 0 then
        local t = self.side_btn_down
        self.side_btn_down = nil
        if t and not self.side_btn_contact
                and time.to_ms(time.now() - t) < SIDE_BUTTON_TAP_MS
                and self:isPluginOn() and not self:isOverlayActive() then
            self:defer(function()
                self:setToolbarShown(not self.toolbar_shown)
            end)
        end
    end
end

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

-- ---------------------------------------------------------------------------
-- Sticky notes: with the note tool, tap the page to pin a text note there;
-- tap a note icon (note tool, finger, or pen in pointer mode) to read, edit
-- or delete it. Stored with the strokes (data.notes).
-- ---------------------------------------------------------------------------

function Pencil:getNoteSize()
    return Screen:scaleBySize(36)
end

function Pencil:getNoteRect(note)
    local s = self:getNoteSize()
    return { x = note.x - math.floor(s / 2), y = note.y - math.floor(s / 2), w = s, h = s }
end

-- Index of the note under (x, y) on the current page, or nil
function Pencil:noteAt(x, y)
    local page = self:getCurrentPage()
    local slack = Screen:scaleBySize(6)
    for i = #(self.notes or {}), 1, -1 do
        local n = self.notes[i]
        if self:noteVisible(n, page) then
            local r = self:getNoteRect(n)
            if x >= r.x - slack and x < r.x + r.w + slack and y >= r.y - slack and y < r.y + r.h + slack then
                return i
            end
        end
    end
    return nil
end

function Pencil:paintNotes(bb, page)
    if not self.notes or #self.notes == 0 or not self.toolbar then return end
    for _, n in ipairs(self.notes) do
        if self:noteVisible(n, page) then
            local r = self:getNoteRect(n)
            bb:paintRoundedRect(r.x, r.y, r.w, r.h, Blitbuffer.COLOR_WHITE, Screen:scaleBySize(5))
            bb:paintBorder(r.x, r.y, r.w, r.h, math.max(1, Screen:scaleBySize(1.5)), Blitbuffer.COLOR_BLACK, Screen:scaleBySize(5))
            local icon = self.toolbar:getIcon("note")
            local is = self.toolbar.icon_size
            icon:paintTo(bb, r.x + math.floor((r.w - is) / 2), r.y + math.floor((r.h - is) / 2))
        end
    end
end

function Pencil:handleNoteSlot(slot)
    local contact = slot.id ~= nil and slot.id >= 0
    if contact then
        if slot.x and slot.y then
            local x, y = self:transformCoordinates(slot.x, slot.y)
            if not self.note_touch then
                self.note_touch = { x = x, y = y }
            end
        end
        return true
    end
    local t = self.note_touch
    self.note_touch = nil
    if t then
        self:defer(function()
            local idx = self:noteAt(t.x, t.y)
            self:openNoteDialog(idx, t.x, t.y)
        end)
    end
    return true
end

-- After a note dialog in note mode, the pen returns to its previous tool
function Pencil:leaveNoteMode()
    if self.current_tool == TOOL_NOTE then
        self:selectTool(self.tool_before_note or TOOL_PEN)
    end
end

function Pencil:openNoteDialog(index, x, y)
    local note = index and self.notes[index]
    local page = self:getCurrentPage()
    local dialog
    local function done()
        UIManager:close(dialog)
        self:leaveNoteMode()
        UIManager:setDirty(self.ui.dialog or self.ui, "ui")
    end
    local row = {}
    if note then
        table.insert(row, {
            text = "Löschen",
            callback = function()
                for i, n in ipairs(self.notes) do
                    if n == note then table.remove(self.notes, i) break end
                end
                self:scheduleDeferredWork()
                done()
            end,
        })
    end
    table.insert(row, {
        text = "Abbrechen",
        id = "close",
        callback = done,
    })
    table.insert(row, {
        text = "Speichern",
        is_enter_default = true,
        callback = function()
            local text = dialog:getInputText() or ""
            if note then
                if text == "" then
                    for i, n in ipairs(self.notes) do
                        if n == note then table.remove(self.notes, i) break end
                    end
                else
                    note.text = text
                end
                self:scheduleDeferredWork()
            elseif text ~= "" then
                local n = { page = page, vkey = self:getViewKey(), x = x, y = y, text = text, datetime = os.time() }
                if self:isScrollMode() then self:anchorNote(n) end
                table.insert(self.notes, n)
                self:scheduleDeferredWork()
            end
            done()
        end,
    })
    dialog = InputDialog:new{
        title = note and "Notiz" or "Neue Notiz",
        input = note and note.text or "",
        allow_newline = true,
        buttons = { row },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Get the pencil strokes file path for this document
function Pencil:getStrokesFilePath()
    if not self.ui or not self.ui.doc_settings then
        logger.warn("Pencil: doc_settings not available")
        return nil
    end
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        return sidecar_dir .. "/pencil_strokes.lua"
    end
    logger.warn("Pencil: sidecar_dir not available")
    return nil
end

-- Load strokes from our own file
function Pencil:loadStrokes()
    local filepath = self:getStrokesFilePath()
    logger.info("Pencil: loadStrokes - filepath =", filepath)

    if not filepath then
        logger.warn("Pencil: no filepath available for loading strokes")
        self.strokes = {}
        self.page_strokes = {}
        return
    end

    -- Read a strokes file; nil + reason if missing or unusable
    local function readStrokesFile(path)
        if lfs.attributes(path, "mode") ~= "file" then return nil, "missing" end
        local ok, data = pcall(dofile, path)
        if ok and type(data) == "table" and type(data.strokes) == "table" then
            return data
        end
        return nil, ok and "unexpected content" or tostring(data)
    end

    local data, reason = readStrokesFile(filepath)
    local recovered = false
    if not data and reason ~= "missing" then
        -- Damaged (e.g. power loss mid-write with an older version of this
        -- plugin). Move it aside so no later save can overwrite it, then
        -- fall back to the previous version.
        local aside = filepath .. ".broken-" .. os.date("%Y%m%d-%H%M%S")
        os.rename(filepath, aside)
        logger.err("Pencil: strokes file unreadable (", reason, "), moved to", aside)
    end
    local from_backup = false
    if not data then
        -- A complete .tmp (crash between writing and renaming it) is newer
        -- than .old; a truncated one doesn't parse and is skipped.
        data = readStrokesFile(filepath .. ".tmp") or readStrokesFile(filepath .. ".old")
        from_backup = data ~= nil
        recovered = from_backup and reason ~= "missing"
    end
    if recovered then
        logger.warn("Pencil: restored strokes from backup", filepath .. ".old")
        UIManager:nextTick(function()
            UIManager:show(InfoMessage:new{
                text = _("Pencil: the annotation file was damaged. The last backup was restored."),
                timeout = 4,
            })
        end)
    end
    if not data then
        logger.info("Pencil: no strokes file (or nothing recoverable):", filepath)
        self.strokes = {}
        self.page_strokes = {}
        self.notes = {}
        -- Safe to save now: a damaged file was moved aside above
        self.strokes_loaded = true
        return
    end

    do
        -- Convert saved strokes back to usable format. A single malformed
        -- entry is skipped instead of failing the whole book.
        self.strokes = {}
        local skipped = 0
        for _, saved in ipairs(data.strokes) do
            local sok, stroke = pcall(self.strokeFromSaved, self, saved)
            if sok and stroke and type(stroke.points) == "table" and stroke.page then
                table.insert(self.strokes, stroke)
            else
                skipped = skipped + 1
            end
        end
        if skipped > 0 then
            logger.warn("Pencil: skipped", skipped, "malformed strokes")
        end
        self:rebuildPageIndex()
        self.notes = {}
        for _, n in ipairs(type(data.notes) == "table" and data.notes or {}) do
            if type(n) == "table" and type(n.x) == "number" and type(n.y) == "number"
                    and n.page ~= nil and type(n.text) == "string" then
                table.insert(self.notes, n)
            end
        end

        -- Load annotation groups or bootstrap from v1 data. Saved groups
        -- refer to strokes by index, so after skipping any they're rebuilt.
        if skipped == 0 and type(data.annotation_groups) == "table" and #data.annotation_groups > 0 then
            self.annotation_groups = data.annotation_groups
            logger.info("Pencil: loaded", #self.annotation_groups, "annotation groups")
        else
            -- v1 data or no groups — bootstrap by running grouping on all strokes
            -- skip_bookmark=true because annotation module isn't ready yet during load
            logger.info("Pencil: bootstrapping annotation groups from strokes")
            self.annotation_groups = {}
            local sorted = {}
            for i, stroke in ipairs(self.strokes) do
                table.insert(sorted, { idx = i, dt = stroke.datetime or 0 })
            end
            table.sort(sorted, function(a, b) return a.dt < b.dt end)
            for _, entry in ipairs(sorted) do
                self:assignStrokeToGroup(entry.idx, true)
            end
        end

        self.strokes_loaded = true
        if from_backup or skipped > 0 then
            -- Write the recovered state back as the main file
            self:scheduleDeferredWork()
        end
        logger.info("Pencil: loaded", #self.strokes, "strokes from", filepath)
    end
end

-- Convert stroke for saving (remove non-serializable values)
function Pencil:strokeToSaveable(stroke)
    return {
        page = stroke.page,
        vkey = stroke.vkey,
        anchor = stroke.anchor or nil,   -- then points are page coordinates
        tool = stroke.tool,
        width = stroke.width,
        alpha = stroke.alpha,
        datetime = stroke.datetime,
        points = (stroke.anchor and stroke.dpts) or stroke.points,
        color_name = stroke.color_name,  -- Save color name for persistence
        pen_type = stroke.pen_type,
    }
end

-- Convert saved stroke back to usable format
function Pencil:strokeFromSaved(saved)
    local tool = saved.tool or TOOL_PEN
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]

    -- Look up color from color_name
    local color = tool_settings.color
    if saved.color_name then
        for _, color_info in ipairs(self.available_colors) do
            if color_info.name == saved.color_name then
                color = color_info.color
                break
            end
        end
    end

    local stroke = {
        page = saved.page,
        vkey = type(saved.vkey) == "string" and saved.vkey or nil,
        tool = saved.tool,
        width = saved.width or tool_settings.width,
        color = color,
        color_name = saved.color_name,
        alpha = saved.alpha or tool_settings.alpha,
        datetime = saved.datetime,
        points = saved.points,
        pen_type = saved.pen_type,
    }
    if saved.anchor == true and type(saved.points) == "table" then
        -- page coordinates; stroke.points gets projected before first use
        stroke.anchor = true
        local d, pts = {}, {}
        for i, pt in ipairs(saved.points) do
            d[i] = { x = pt.x, y = pt.y, p = pt.p }
            pts[i] = { x = pt.x, y = pt.y, p = pt.p }
        end
        stroke.dpts, stroke.points = d, pts
    end
    return stroke
end

-- Save strokes to our own file
function Pencil:saveStrokes()
    local filepath = self:getStrokesFilePath()
    logger.info("Pencil: saveStrokes - filepath =", filepath, "strokes count =", #self.strokes)

    if not filepath then
        logger.warn("Pencil: no filepath available for saving strokes")
        return
    end

    -- Safety: don't save empty data if strokes were never successfully loaded
    -- (prevents data loss if a crash causes save before load completes)
    if #self.strokes == 0 and not self.strokes_loaded then
        logger.warn("Pencil: refusing to save empty strokes (strokes never loaded)")
        return
    end

    -- Ensure the directory exists
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        local ok, err = lfs.mkdir(sidecar_dir)
        if not ok and err ~= "File exists" then
            logger.warn("Pencil: failed to create sidecar dir:", err)
        end
    end

    -- Convert strokes to saveable format (remove non-serializable values)
    local saveable_strokes = {}
    for i, stroke in ipairs(self.strokes) do
        saveable_strokes[i] = self:strokeToSaveable(stroke)
    end

    -- Serialize and write. Version 3 marks files that may contain image_path /
    -- image_rotation fields on annotation groups; older readers can ignore
    -- those fields and continue to use the strokes directly.
    local data = {
        version = 3,
        strokes = saveable_strokes,
        annotation_groups = self.annotation_groups,
        notes = self.notes,   -- sticky notes (optional; older readers ignore it)
    }

    local ok, err = self:writeFileAtomic(filepath, "return " .. require("dump")(data) .. "\n")
    if ok then
        self.strokes_dirty = false
        logger.info("Pencil: saved", #self.strokes, "strokes to", filepath)
    else
        -- strokes_dirty stays set: the next page change / autosave retries
        logger.err("Pencil: failed to save strokes:", filepath, "error:", err)
    end
end

-- Write a file so that a crash or power loss at any moment leaves either the
-- old or the new version, never a half-written one: write to .tmp, fsync,
-- then rename over the original. The previous version is kept as .old (like
-- KOReader's own settings, only if it's over a minute old, so a burst of
-- saves doesn't rotate a good backup away).
function Pencil:writeFileAtomic(path, content)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return nil, err end
    local wok, werr = f:write(content)
    if wok then pcall(ffiUtil.fsyncOpenedFile, f) end
    local cok, cerr = f:close()
    if not wok or not cok then
        os.remove(tmp)   -- e.g. disk full: keep the existing file untouched
        return nil, werr or cerr
    end
    local mtime = lfs.attributes(path, "modification")
    if mtime and mtime < os.time() - 60 then
        os.remove(path .. ".old")
        os.rename(path, path .. ".old")
    end
    local rok, rerr = os.rename(tmp, path)
    if not rok and lfs.attributes(path, "mode") == "file" then
        -- Filesystems that refuse to rename over an existing file: remove
        -- it first. If we crash right here, loadStrokes recovers the .tmp.
        os.remove(path)
        rok, rerr = os.rename(tmp, path)
    end
    if not rok then
        return nil, rerr   -- .tmp is kept: it's complete and loadStrokes can use it
    end
    pcall(ffiUtil.fsyncDirectory, path)
    return true
end

-- Handle document close
function Pencil:onCloseDocument()
    logger.info("Pencil: onCloseDocument called, strokes count =", #self.strokes)
    self:resetTransientInput(true)   -- in-progress stroke is saved below
    self:cancelAutosave()
    self:freeEraseSnapshot()
    self:freeSnapshotCache()
    if self._chip_tw then
        self._chip_tw:free()
        self._chip_tw = nil
    end
    if self.toolbar then self.toolbar:reset() end
    self:uninstallStylusButtonHook()
    self:uninstallPressureHook()

    -- Cancel any pending refresh
    self:cancelPendingRefresh()
    -- Drop any scheduled debounced save - we save unconditionally below.
    self:cancelPendingSave()
    self.dirty_groups = nil

    -- Save any in-progress stroke
    if self.current_stroke and #self.current_stroke.points >= 2 then
        logger.info("Pencil: saving in-progress stroke before close")
        self:anchorIfScroll(self.current_stroke)
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        self.current_stroke = nil
    end

    self:teardownPenInput()

    -- Run any pending deferred image captures synchronously before close so
    -- we don't lose a fresh annotation. Must happen before the final save so
    -- new image_path / image_rotation fields land in the strokes file.
    self:flushPendingCaptures()

    -- Final bookmark sync before close
    self:syncAllBookmarks()

    -- Always save strokes on close (even if empty, to clear any previous data)
    logger.info("Pencil: saving strokes on document close")
    self:saveStrokes()

    -- Clear state
    self.eraser_deleted = nil
    self.undo_stack = {}
    self.redo_stack = {}
    self.notes = {}

    if _active_pencil == self then _active_pencil = nil end
end

function Pencil:onSuspend()
    -- Same idea as onCloseDocument: don't lose a freshly drawn annotation
    -- across a device sleep.
    self:resetTransientInput()
    self:flushPendingCaptures()
    -- Strokes too: sleep is where a flat battery or crash would lose them
    self:cancelAutosave()
    self:flushDeferredWork()
    -- Give back the snapshot buffer while sleeping
    self:freeEraseSnapshot()
    self:freeSnapshotCache()
end

function Pencil:onResume()
    -- Pen events from before sleep never got their lift
    self:resetTransientInput()
end

-- Rotation / screen size change: snapshots and on-screen selections are in
-- the old geometry.
function Pencil:onSetDimensions()
    self:resetTransientInput(true)
    self.lasso_selection = nil
    self:freeEraseSnapshot()
    self:freeSnapshotCache()
end

-- Handle reader ready (document fully loaded)
function Pencil:onReaderReady()
    logger.info("Pencil: onReaderReady called")
    logger.info("Pencil: doc_settings available:", self.ui.doc_settings ~= nil)
    if self.ui.doc_settings then
        logger.info("Pencil: sidecar_dir:", self.ui.doc_settings.doc_sidecar_dir)
    end

    -- Force reload strokes (in case they weren't loaded in init)
    if #self.strokes == 0 then
        self:loadStrokes()
    end
    logger.info("Pencil: after loadStrokes, strokes count =", #self.strokes,
        "groups =", #self.annotation_groups)

    -- Sync annotation group bookmarks now that UI modules are ready
    self:syncAllBookmarks()

    -- Re-setup touch zones if enabled
    if self:isPluginOn() and not self.touch_zones_registered then
        self:setupPenInput()
    end

    -- Lazy backfill: any group on the currently visible page that's missing
    -- an image (e.g. created in an older version, or capture was lost mid-
    -- session) gets re-captured now that ReaderView can paint the page.
    self:backfillMissingImages()
end

-- Handle read settings (document opened) - backup in case onReaderReady not called
function Pencil:onReadSettings(config)
    logger.dbg("Pencil: onReadSettings called")
    -- Only load if not already loaded
    if not self.strokes or #self.strokes == 0 then
        self:loadStrokes()
    end
    -- Re-setup touch zones if enabled (in case they were torn down)
    if self:isPluginOn() and not self.touch_zones_registered then
        self:setupPenInput()
    end
end

-- Handle page changes (paging mode)
function Pencil:onPageUpdate(pageno)
    self:resetTransientInput(true)   -- stroke handling follows below
    self:freeEraseSnapshot()
    self.lasso_selection = nil
    self.lasso_path = nil
    -- Clear any in-progress stroke when page changes
    if self.current_stroke and #self.current_stroke.points >= 2 then
        -- Save the stroke before clearing. The inline saveStrokes below covers
        -- everything in self.strokes, so drop any queued debounced save first.
        self:cancelPendingSave()
        self:anchorIfScroll(self.current_stroke)
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        self:pushUndo({ type = "add", stroke_idx = #self.strokes })
        self:flushDirtyGroups()
        self:saveStrokes()
    else
        -- No in-progress stroke, but a debounced save may still be queued from
        -- earlier strokes on this page. Persist it before navigating away.
        self:flushDeferredWork()
    end
    self.current_stroke = nil
    self.eraser_deleted = nil
    -- Re-schedule capture for any group on the newly visible page that's
    -- still missing an image (e.g. user turned past the original page before
    -- the debounce fired).
    self:backfillMissingImages()
end

-- Paged documents: moving within one page (the lower half of a PDF page
-- that is taller than the screen) changes only the visible area, not the
-- page number, so no PageUpdate arrives. Treat a new screen like a page turn.
function Pencil:onViewRecalculate()
    local vkey = self:getViewKey()
    if vkey ~= self._last_vkey then
        local had = self._last_vkey ~= nil
        self._last_vkey = vkey
        if had then
            self:onPageUpdate()
        end
    end
end

-- Handle position changes (rolling/scroll mode)
function Pencil:onUpdatePos()
    self:freeEraseSnapshot()
    self.lasso_selection = nil
    self.lasso_path = nil
    -- Clear any in-progress stroke when position changes
    if self.current_stroke and #self.current_stroke.points >= 2 then
        self:cancelPendingSave()
        self:anchorIfScroll(self.current_stroke)
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        self:pushUndo({ type = "add", stroke_idx = #self.strokes })
        self:flushDirtyGroups()
        self:saveStrokes()
    else
        self:flushDeferredWork()
    end
    self.current_stroke = nil
    self.eraser_deleted = nil
    self:backfillMissingImages()
end

return Pencil
