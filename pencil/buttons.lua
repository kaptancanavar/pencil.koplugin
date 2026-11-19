--[[--
Hardware buttons: eraser/stylus keys, the pen's side button and the
quick tool menu.

@module pencil.buttons
--]]--

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local ffiUtil = require("ffi/util")
local T = ffiUtil.template
local time = require("ui/time")
local Common = require("pencil/common")
local TOOL_PEN = Common.TOOL_PEN
local TOOL_HIGHLIGHTER = Common.TOOL_HIGHLIGHTER
local TOOL_ERASER = Common.TOOL_ERASER
local TOOL_LASSO = Common.TOOL_LASSO
local TOOL_NOTE = Common.TOOL_NOTE
local SIDE_BUTTON_DEFAULT = Common.SIDE_BUTTON_DEFAULT

local Pencil = {}

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
    -- Clear the held state FIRST, whatever is on screen: released while a
    -- menu / sticky note was open, the flag used to stay set, and every
    -- later stroke came out as highlighter (startRawStroke) until restart.
    local was_down = self.side_button_down
    self.side_button_down = false
    if not self:isEnabled() or self:isOverlayActive() then return false end

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

-- ---------------------------------------------------------------------------
-- Pen side button: a short press without touching the screen shows/hides
-- the toolbar. (Holding it while writing still erases, handled by Input.)
-- KOReader has no key event for this button on Kindle, so we look at the
-- raw EV_KEY BTN_STYLUS events passing through Input:handleKeyBoardEv.
-- ---------------------------------------------------------------------------

local BTN_STYLUS = 0x14b   -- linux/input-event-codes.h
-- Instance the (installed once) hook reports to
local side_button_owner = nil

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
    side_button_owner = self
    if input._pencil_kbd_orig then return end   -- already wrapped
    local orig = input.handleKeyBoardEv
    input._pencil_kbd_orig = orig
    input.handleKeyBoardEv = function(inp, ev)
        local owner = side_button_owner
        if owner and ev and ev.code == BTN_STYLUS then
            local ok, err = pcall(owner.onStylusSideButton, owner, ev.value)
            if not ok then logger.warn("Pencil: side button hook", err) end
        end
        return orig(inp, ev)
    end
end

function Pencil:uninstallStylusButtonHook()
    if side_button_owner == self then
        side_button_owner = nil
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

return Pencil
