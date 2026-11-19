--[[--
Handwritten sticky notes: a writing pad that opens over the page (like the
Kindle Scribe's sticky notes). The pen writes on it directly; the eraser end
or side button erases whole strokes.

Ink is stored on the note as note.ink = { strokes = { {w=, points={{x,y},..}} } }
in pad units: the canvas is INK_UNITS wide whatever the screen, so a note
looks the same after rotation or on another device.

@module pencil.notepad
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local PencilGeometry = require("lib/geometry")
local Screen = Device.screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local time = require("ui/time")
local Common = require("pencil/common")
local TOOL_PEN = Common.TOOL_PEN

local INK_UNITS = 1000      -- canvas width in pad units
local INK_ASPECT = 0.7      -- canvas height / width
local REFRESH_MS = 16       -- live ink refresh throttle (as in addRawPoint)

local function copyStrokes(strokes)
    local out = {}
    for i, s in ipairs(strokes or {}) do
        local pts = {}
        for j, p in ipairs(s.points or {}) do pts[j] = { x = p.x, y = p.y } end
        out[i] = { w = s.w, points = pts }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Canvas: white area that paints the ink. paintTo records where it is on
-- screen; the pad uses that rect for hit tests and live drawing.
-- ---------------------------------------------------------------------------

local InkCanvas = Widget:extend{
    width = nil,
    height = nil,
    strokes = nil,
    plugin = nil,
}

function InkCanvas:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function InkCanvas:scale()
    return self.width / INK_UNITS
end

function InkCanvas:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    local s = self:scale()
    for _, stroke in ipairs(self.strokes) do
        self:paintStroke(bb, stroke, s)
    end
end

function InkCanvas:paintStroke(bb, stroke, s)
    local pts = stroke.points
    local w = math.max(1, math.floor(stroke.w * s + 0.5))
    local x0, y0 = self.dimen.x, self.dimen.y
    if #pts == 1 then
        local h = math.floor(w / 2)
        bb:paintRect(math.floor(x0 + pts[1].x * s) - h, math.floor(y0 + pts[1].y * s) - h,
            w, w, Blitbuffer.COLOR_BLACK)
        return
    end
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        self.plugin:drawLineSegment(bb,
            math.floor(x0 + a.x * s), math.floor(y0 + a.y * s),
            math.floor(x0 + b.x * s), math.floor(y0 + b.y * s),
            w, Blitbuffer.COLOR_BLACK)
    end
end

-- ---------------------------------------------------------------------------
-- The pad itself
-- ---------------------------------------------------------------------------

local NotePad = InputContainer:extend{
    name = "PencilNotePad",
    plugin = nil,
    note = nil,         -- existing note, or nil for a new one
    on_save = nil,      -- function(strokes) called by "Fertig"/tap outside
    on_delete = nil,    -- function() for an existing note
    on_close = nil,     -- function() after the pad is gone, whatever happened
}

function NotePad:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    -- Same size in portrait and landscape: based on the short side
    local cw = math.floor(math.min(W, H) * 0.86)
    local ch = math.floor(cw * INK_ASPECT)
    self.strokes = copyStrokes(self.note and self.note.ink and self.note.ink.strokes)
    self.undo = {}
    self.canvas = InkCanvas:new{ width = cw, height = ch, strokes = self.strokes, plugin = self.plugin }

    local pad = self
    local row = {}
    if self.note then
        table.insert(row, { text = "Löschen", callback = function() pad:finish("delete") end })
    end
    table.insert(row, { text = "Rückgängig", callback = function() pad:undoLast() end })
    table.insert(row, { text = "Abbrechen", callback = function() pad:finish("cancel") end })
    table.insert(row, { text = "Fertig", callback = function() pad:finish("save") end })
    local buttons = ButtonTable:new{
        width = cw,
        buttons = { row },
        zero_sep = true,
        show_parent = self,
    }
    local gap = Size.padding.default
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.large,
        VerticalGroup:new{
            align = "left",
            TextWidget:new{
                text = self.note and "Notiz" or "Neue Notiz",
                face = Font:getFace("tfont"),
            },
            VerticalSpan:new{ width = gap },
            FrameContainer:new{
                bordersize = Size.border.thin,
                padding = 0,
                margin = 0,
                self.canvas,
            },
            VerticalSpan:new{ width = gap },
            buttons,
        },
    }
    local fs = self.frame:getSize()
    self.dimen = Geom:new{
        x = math.floor((W - fs.w) / 2),
        y = math.floor((H - fs.h) / 2),
        w = fs.w, h = fs.h,
    }
    self[1] = self.frame
    if Device:isTouchDevice() then
        self.ges_events.TapOutside = {
            GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = W, h = H } },
        }
    end
end

-- Always centered, whatever position UIManager passes
function NotePad:paintTo(bb)
    self.frame:paintTo(bb, self.dimen.x, self.dimen.y)
end

function NotePad:onTapOutside(_, ges)
    if ges and ges.pos and ges.pos:notIntersectWith(self.dimen) then
        self:finish("save")
    end
    return true
end

function NotePad:onCloseWidget()
    if self.plugin.note_pad == self then
        self.plugin.note_pad = nil
    end
end

function NotePad:finish(how)
    if self.closed then return end
    self.closed = true
    -- Release the pen right away (not only via CloseWidget): a pad that
    -- stayed registered would swallow every pen contact on the page
    if self.plugin.note_pad == self then self.plugin.note_pad = nil end
    UIManager:close(self)
    if how == "save" and self.on_save then
        self.on_save(self.strokes)
    elseif how == "delete" and self.on_delete then
        self.on_delete()
    end
    if self.on_close then self.on_close() end
end

-- Repaint the canvas into the framebuffer and refresh it
function NotePad:repaintCanvas()
    local d = self.canvas.dimen
    if not d then return end
    self.canvas:paintTo(Screen.bb, d.x, d.y)
    Screen:refreshUI(d.x, d.y, d.w, d.h)
end

function NotePad:undoLast()
    local a = table.remove(self.undo)
    if not a then return end
    if a.type == "add" then
        for i = #self.strokes, 1, -1 do
            if self.strokes[i] == a.stroke then table.remove(self.strokes, i) break end
        end
    elseif a.type == "erase" then
        for _, s in ipairs(a.strokes) do table.insert(self.strokes, s) end
    end
    self:repaintCanvas()
end

-- Screen point -> pad units, clamped into the canvas
function NotePad:toUnits(sx, sy, margin)
    local d = self.canvas.dimen
    margin = margin or 0
    sx = math.max(d.x + margin, math.min(d.x + d.w - 1 - margin, sx))
    sy = math.max(d.y + margin, math.min(d.y + d.h - 1 - margin, sy))
    local s = self.canvas:scale()
    return math.floor((sx - d.x) / s * 10 + 0.5) / 10,
           math.floor((sy - d.y) / s * 10 + 0.5) / 10,
           sx, sy
end

function NotePad:insideCanvas(sx, sy)
    local d = self.canvas.dimen
    return d and sx >= d.x and sx < d.x + d.w and sy >= d.y and sy < d.y + d.h
end

-- Live ink: draw the new segment straight into the framebuffer and refresh
-- only its area, throttled like the page pen (addRawPoint).
function NotePad:addDirty(x, y, w, h)
    local r = self.dirty
    if r then
        local x1, y1 = math.max(r.x + r.w, x + w), math.max(r.y + r.h, y + h)
        r.x, r.y = math.min(r.x, x), math.min(r.y, y)
        r.w, r.h = x1 - r.x, y1 - r.y
    else
        self.dirty = { x = x, y = y, w = w, h = h }
    end
end

function NotePad:flushDirty(force)
    local r = self.dirty
    if not r then return end
    local now = time.now()
    if not force and self.last_refresh and time.to_ms(now - self.last_refresh) < REFRESH_MS then
        return
    end
    self.last_refresh = now
    self.dirty = nil
    local d = self.canvas.dimen
    local x = math.max(d.x, math.floor(r.x))
    local y = math.max(d.y, math.floor(r.y))
    local w = math.min(d.x + d.w, math.ceil(r.x + r.w)) - x
    local h = math.min(d.y + d.h, math.ceil(r.y + r.h)) - y
    if w <= 0 or h <= 0 then return end
    if Device:isKindle() then
        Screen:refreshFast(x, y, w, h)   -- A2/DU: black ink keeps up with the pen
    else
        Screen:refreshUI(x, y, w, h)
    end
end

function NotePad:penWidthPx()
    local ts = self.plugin.tool_settings[TOOL_PEN]
    return math.max(2, math.floor((ts and ts.width) or 3))
end

function NotePad:beginStroke(sx, sy)
    local wpx = self:penWidthPx()
    self.cur = { w = wpx / self.canvas:scale(), points = {} }
    self.cur_wpx = wpx
    table.insert(self.strokes, self.cur)
    table.insert(self.undo, { type = "add", stroke = self.cur })
    self.last_sx, self.last_sy = nil, nil
    self:addPoint(sx, sy)
end

function NotePad:addPoint(sx, sy)
    local wpx = self.cur_wpx
    local half = math.floor(wpx / 2)
    local ux, uy
    ux, uy, sx, sy = self:toUnits(sx, sy, half)
    if self.last_sx == sx and self.last_sy == sy then return end
    table.insert(self.cur.points, { x = ux, y = uy })
    if self.last_sx then
        self.plugin:drawLineSegment(Screen.bb, self.last_sx, self.last_sy, sx, sy, wpx, Blitbuffer.COLOR_BLACK)
        self:addDirty(math.min(sx, self.last_sx) - half - 2, math.min(sy, self.last_sy) - half - 2,
            math.abs(sx - self.last_sx) + wpx + 4, math.abs(sy - self.last_sy) + wpx + 4)
    else
        Screen.bb:paintRect(sx - half, sy - half, wpx, wpx, Blitbuffer.COLOR_BLACK)
        self:addDirty(sx - half - 2, sy - half - 2, wpx + 4, wpx + 4)
    end
    self.last_sx, self.last_sy = sx, sy
    self:flushDirty(false)
end

function NotePad:endStroke()
    self.cur = nil
    self:flushDirty(true)
end

-- Eraser end / side button: remove whole strokes under the eraser
function NotePad:eraseAt(sx, sy)
    if not self:insideCanvas(sx, sy) then return end
    local ux, uy = self:toUnits(sx, sy)
    local r = self.plugin:getEraserRadius() / self.canvas:scale()
    local removed = {}
    for i = #self.strokes, 1, -1 do
        local s = self.strokes[i]
        if PencilGeometry.isPointNearStroke(ux, uy, s, r + s.w / 2) then
            table.insert(removed, table.remove(self.strokes, i))
        end
    end
    if #removed > 0 then
        table.insert(self.undo, { type = "erase", strokes = removed })
        self:repaintCanvas()
    end
end

-- Raw pen events while the pad is open (called from dispatchStylusSlot).
-- A contact that starts on the canvas writes or erases; any other contact
-- is passed on (return false) so it becomes a normal tap on the buttons or
-- outside the pad. The decision is made at touch-down and kept until lift.
function NotePad:handleStylusSlot(slot)
    local p = self.plugin
    local contact = slot.id ~= nil and slot.id >= 0
    if not contact then
        local mode = self.contact_mode
        self.contact_mode = nil
        if mode == "draw" then self:endStroke() end
        return mode ~= "pass" and mode ~= nil
    end
    local mode = self.contact_mode
    if mode == "pass" then return false end
    if slot.x == nil or slot.y == nil then
        -- Wacom touch-down frame without a position: decide on the next one
        -- (held back like the toolbar does, see dispatchStylusSlot)
        return true
    end
    local sx, sy = p:transformCoordinates(slot.x, slot.y)
    if not mode then
        if self.closed or UIManager:getTopmostVisibleWidget() ~= self
                or not self:insideCanvas(sx, sy) then
            self.contact_mode = "pass"
            return false
        end
        local erasing = (p.swap_eraser_and_highlighter and slot.tool == 3)
            or (not p.swap_eraser_and_highlighter and slot.tool == 2)
        if erasing then
            self.contact_mode = "erase"
        else
            self.contact_mode = "draw"
            self:beginStroke(sx, sy)
            return true
        end
        mode = self.contact_mode
    end
    if mode == "draw" then
        self:addPoint(sx, sy)
    elseif mode == "erase" then
        self:eraseAt(sx, sy)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Plugin side
-- ---------------------------------------------------------------------------

local Pencil = {}

local function removeNote(self, note)
    for i, n in ipairs(self.notes) do
        if n == note then table.remove(self.notes, i) return end
    end
end

-- Open the writing pad for an existing note (index) or a new one at (x, y)
function Pencil:openInkNote(index, x, y)
    if self.note_pad then return end
    local note = index and self.notes[index]
    local page, vkey = self:getCurrentPage(), self:getViewKey()
    local pad
    pad = NotePad:new{
        plugin = self,
        note = note,
        on_save = function(strokes)
            local has_ink = false
            for _, s in ipairs(strokes) do
                if #s.points > 0 then has_ink = true break end
            end
            if note then
                if has_ink then
                    note.ink = { strokes = strokes }
                    note.text = nil
                else
                    removeNote(self, note)   -- everything erased: the note goes
                end
                self:scheduleDeferredWork()
            elseif has_ink and x and y then
                local n = { page = page, vkey = vkey, x = x, y = y,
                            ink = { strokes = strokes }, datetime = os.time() }
                if self:isScrollMode() then self:anchorNote(n) end
                table.insert(self.notes, n)
                self:scheduleDeferredWork()
            end
        end,
        on_delete = function()
            removeNote(self, note)
            self:scheduleDeferredWork()
        end,
        on_close = function()
            self:leaveNoteMode()
            UIManager:setDirty(self.ui.dialog or self.ui, "ui")
        end,
    }
    self.note_pad = pad
    UIManager:show(pad)
end

return Pencil
