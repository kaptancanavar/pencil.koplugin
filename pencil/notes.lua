--[[--
Sticky notes.

@module pencil.notes
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local Common = require("pencil/common")
local TOOL_PEN = Common.TOOL_PEN
local TOOL_NOTE = Common.TOOL_NOTE

local Pencil = {}

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
            -- Just the icon, no frame: looks smaller on the page. The white
            -- underlay is only as big as the icon so text doesn't show
            -- through it. The tap area (getNoteRect) stays as large as before.
            local r = self:getNoteRect(n)
            local icon = self.toolbar:getIcon("note")
            local is = self.toolbar.icon_size
            local ix = r.x + math.floor((r.w - is) / 2)
            local iy = r.y + math.floor((r.h - is) / 2)
            bb:paintRect(ix, iy, is, is, Blitbuffer.COLOR_WHITE)
            icon:paintTo(bb, ix, iy)
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

-- New notes and handwritten ones open the writing pad (pencil/notepad.lua).
-- Notes typed before handwriting existed keep their keyboard dialog.
function Pencil:openNoteDialog(index, x, y)
    local note = index and self.notes[index]
    if not (note and note.text and not note.ink) then
        return self:openInkNote(index, x, y)
    end
    return self:openTextNoteDialog(index)
end

function Pencil:openTextNoteDialog(index)
    local note = index and self.notes[index]
    if not note then return end
    local dialog
    local function done()
        UIManager:close(dialog)
        self:leaveNoteMode()
        UIManager:setDirty(self.ui.dialog or self.ui, "ui")
    end
    local row = {}
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
            if text == "" then
                for i, n in ipairs(self.notes) do
                    if n == note then table.remove(self.notes, i) break end
                end
            else
                note.text = text
            end
            self:scheduleDeferredWork()
            done()
        end,
    })
    dialog = InputDialog:new{
        title = "Notiz",
        input = note.text,
        allow_newline = true,
        buttons = { row },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return Pencil
