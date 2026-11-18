--[[--
Experimental color / width picker (hold the pen still to open it).

@module pencil.colorpicker
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local Size = require("ui/size")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local ffiUtil = require("ffi/util")
local T = ffiUtil.template
local time = require("ui/time")
local Common = require("pencil/common")
local TOOL_PEN = Common.TOOL_PEN
local COLOR_PICKER_DELAY_MS = Common.COLOR_PICKER_DELAY_MS

local Pencil = {}

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

return Pencil
