--[[--
Pencil plugin for KOReader.
Enables freehand drawing and annotation with stylus on supported devices.

@module koplugin.pencil
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local PencilToolbar = require("lib/toolbar")
local Screen = Device.screen
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local ffiUtil = require("ffi/util")
local T = ffiUtil.template
local Common = require("pencil/common")
local TOOL_PEN = Common.TOOL_PEN
local TOOL_HIGHLIGHTER = Common.TOOL_HIGHLIGHTER
local TOOL_ERASER = Common.TOOL_ERASER

-- Check if device supports touch input
if not Device:isTouchDevice() then
    return { disabled = true }
end

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

-- The methods live in pencil/, one file per feature, and are mixed into
-- the class here. Required now: KOReader only puts the plugin folder on
-- package.path while it loads main.lua.
for _, name in ipairs({
    "errors",
    "stylus",
    "stroke",
    "texthighlight",
    "debuglog",
    "settings",
    "menu",
    "buttons",
    "undo",
    "gestures",
    "scheduling",
    "colorpicker",
    "pagemap",
    "groups",
    "images",
    "render",
    "erase",
    "toolbar_control",
    "lasso",
    "notes",
    "notepad",
    "storage",
}) do
    for k, v in pairs(require("pencil/" .. name)) do
        Pencil[k] = v
    end
end

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

-- Handle document close
function Pencil:onCloseDocument()
    logger.info("Pencil: onCloseDocument called, strokes count =", #self.strokes)
    if self.note_pad then
        pcall(self.note_pad.finish, self.note_pad, "save")   -- saved below
    end
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

    self:releaseBookmarkHook()
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
