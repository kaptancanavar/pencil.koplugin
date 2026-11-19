--[[--
Native KOReader text highlights made with the pen (ReaderHighlight).

@module pencil.texthighlight
--]]--

local UIManager = require("ui/uimanager")
local logger = require("logger")

local Pencil = {}

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

-- Screen boxes of the saved text highlights, collected ONCE per eraser
-- gesture (finishErase / abortErase drop the cache). Looking them up on
-- every pen event asked the document to measure every highlight of the
-- book (EPUB: getScreenBoxesFromPositions per highlight) 100+ times a
-- second, which is what made the eraser end crawl in books with highlights.
-- Entries keep the annotation item itself: indices shift after a removal.
function Pencil:getHighlightEraseBoxes()
    if self._hl_boxes then return self._hl_boxes end
    local list = {}
    self._hl_boxes = list
    if not (self.ui and self.ui.annotation and self.ui.annotation.annotations
            and self.ui.view and self.ui.document) then
        return list
    end
    local doc, view = self.ui.document, self.ui.view
    local is_paging = self.ui.paging ~= nil
    local page = is_paging and self:getCurrentPage() or nil
    for _, item in ipairs(self.ui.annotation.annotations) do
        -- drawer is nil for page-bookmarks; only text highlights have it set.
        if item.drawer and item.pos0 and item.pos1 then
            local boxes
            if is_paging then
                if item.page == page and view.pageToScreenTransform then
                    local ok, got = pcall(doc.getPageBoxesFromPositions, doc, page, item.pos0, item.pos1)
                    if ok and got then
                        boxes = {}
                        for _, b in ipairs(got) do
                            local ok2, sb = pcall(view.pageToScreenTransform, view, page, b)
                            if ok2 and sb then boxes[#boxes + 1] = sb end
                        end
                    end
                end
            else
                -- Rolling mode (EPUB): screen coordinates directly
                local ok, got = pcall(doc.getScreenBoxesFromPositions, doc, item.pos0, item.pos1, true)
                if ok then boxes = got end
            end
            if boxes and #boxes > 0 then
                list[#list + 1] = { item = item, boxes = boxes }
            end
        end
    end
    return list
end

local function circleHitsBox(cx, cy, r, b)
    local nx = math.max(b.x, math.min(cx, b.x + b.w))
    local ny = math.max(b.y, math.min(cy, b.y + b.h))
    local dx, dy = nx - cx, ny - cy
    return dx * dx + dy * dy <= r * r
end

-- Delete a KOReader text highlight touched by the eraser circle at the given
-- screen position (the whole circle counts, like for strokes, not just the
-- pen tip). Used by the eraser-end pass in dispatchStylusSlot.
-- removeItemByIndex emits AnnotationsModified and does the logical cleanup,
-- but on e-ink its setDirty is not strong enough to clear the highlight's
-- painted pixels from the framebuffer, so a UI-mode setDirty is forced.
function Pencil:eraseHighlightAtScreenPos(screen_x, screen_y)
    local list = self:getHighlightEraseBoxes()
    if #list == 0 then return false end
    local r = self:getEraserRadius()
    for li, e in ipairs(list) do
        for _, b in ipairs(e.boxes) do
            if circleHitsBox(screen_x, screen_y, r, b) then
                table.remove(list, li)
                local index
                for i, it in ipairs(self.ui.annotation.annotations) do
                    if it == e.item then index = i break end
                end
                if not index or not (self.ui.bookmark and self.ui.bookmark.removeItemByIndex) then
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
        end
    end
    return false
end

return Pencil
