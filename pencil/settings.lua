--[[--
Plugin settings (G_reader_settings) and the global on/off state.

@module pencil.settings
--]]--

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local ffiUtil = require("ffi/util")
local T = ffiUtil.template
local Common = require("pencil/common")
local TOOL_PEN = Common.TOOL_PEN
local TOOL_HIGHLIGHTER = Common.TOOL_HIGHLIGHTER
local TOOL_ERASER = Common.TOOL_ERASER
local PEN_TYPE_PEN = Common.PEN_TYPE_PEN
local SIDE_BUTTON_DEFAULT = Common.SIDE_BUTTON_DEFAULT
local sideButtonToolName = Common.sideButtonToolName

local Pencil = {}

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
    local sb = settings.side_button_tool
    if type(sb) == "string" and sb:match("^pen:") then
        sb = "pen:pen"   -- fountain pen / marker / pencil were removed: plain pen
    end
    self.side_button_tool = sideButtonToolName(sb) and sb or SIDE_BUTTON_DEFAULT
    -- The pen is always a plain pen (the type choice was removed from the
    -- toolbar); an old saved fountain/marker/pencil choice no longer applies.
    -- Existing strokes keep their own type.
    self.tool_settings[TOOL_PEN].pen_type = PEN_TYPE_PEN
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

return Pencil
