--[[--
Plugin side of the floating toolbar: actions, flyout menus, show/hide
and dragging. Layout and painting live in lib/toolbar.lua.

@module pencil.toolbar_control
--]]--

local Device = require("device")
local Geom = require("ui/geometry")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local Common = require("pencil/common")
local TOOL_PEN = Common.TOOL_PEN
local TOOL_HIGHLIGHTER = Common.TOOL_HIGHLIGHTER
local TOOL_ERASER = Common.TOOL_ERASER
local TOOL_LASSO = Common.TOOL_LASSO
local TOOL_NOTE = Common.TOOL_NOTE
local SIDE_BUTTON_TOOLS = Common.SIDE_BUTTON_TOOLS
local SIDE_BUTTON_DEFAULT = Common.SIDE_BUTTON_DEFAULT
local sideButtonToolName = Common.sideButtonToolName
local snapshotFits = Common.snapshotFits
local unionRect = Common.unionRect

local Pencil = {}

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
    if kind == TOOL_PEN or kind == TOOL_HIGHLIGHTER or kind == TOOL_ERASER then
        -- Only the stroke width, the same list for every tool. (The pen
        -- used to offer fountain pen / marker / pencil here too; the pen is
        -- just a pen now.)
        local level = self:getWidthLevel(kind)
        local sample_type = (kind == TOOL_PEN and "line") or (kind == TOOL_ERASER and "ring") or "bar"
        for i, w in ipairs(TOOL_WIDTHS[kind]) do
            table.insert(rows, {
                id = "w:" .. kind .. ":" .. i,
                text = WIDTH_LABELS[i],
                -- Pen and marker draw in raw pixels; the eraser's size is
                -- scaled (getEraserRadius), so its sample is too: the menu
                -- shows the real eraser size.
                sample = { type = sample_type,
                           width = (kind == TOOL_ERASER) and Screen:scaleBySize(w) or w },
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
        -- Picking a tool means the pen draws with THAT tool: a stale "side
        -- button held" (release missed) must not keep overriding it
        self.side_button_down = false
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
    if tool then
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

return Pencil
