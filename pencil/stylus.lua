--[[--
Raw stylus input: the stylus callback, its dispatch to the tools, Sony DHW
and the pen pressure hook.

@module pencil.stylus
--]]--

local Device = require("device")
local PencilGeometry = require("lib/geometry")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local Common = require("pencil/common")
local TOOL_PEN = Common.TOOL_PEN
local TOOL_ERASER = Common.TOOL_ERASER
local TOOL_LASSO = Common.TOOL_LASSO
local TOOL_NOTE = Common.TOOL_NOTE
local COLOR_PICKER_TOLERANCE_PIXELS = Common.COLOR_PICKER_TOLERANCE_PIXELS

local Pencil = {}

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

-- Setup stylus callback for lowest latency pen capture
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

-- ---------------------------------------------------------------------------
-- Pen pressure: KOReader doesn't keep ABS_PRESSURE for Wacom pens, so we
-- watch the raw EV_ABS events passing through Input:handleTouchEv.
-- ---------------------------------------------------------------------------

local EV_ABS = 3
local ABS_PRESSURE = 0x18
local DEFAULT_PRESSURE_MAX = 4095
-- Instance the (installed once) hook reports to
local pressure_owner = nil

function Pencil:installPressureHook()
    local input = Device.input
    if not input or type(input.handleTouchEv) ~= "function" then return end
    pressure_owner = self
    if input._pencil_touch_wrapper and input.handleTouchEv == input._pencil_touch_wrapper then
        return   -- already in place
    end
    local orig = input.handleTouchEv
    local wrapper = function(inp, ev)
        if ev and ev.type == EV_ABS and ev.code == ABS_PRESSURE then
            local owner = pressure_owner
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
    if pressure_owner == self then
        pressure_owner = nil
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

return Pencil
