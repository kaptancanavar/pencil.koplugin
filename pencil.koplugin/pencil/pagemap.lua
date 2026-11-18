--[[--
Which strokes belong to which screen: page and view keys, the page index
and page-anchored strokes in continuous scroll mode.

@module pencil.pagemap
--]]--

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local ffiUtil = require("ffi/util")
local T = ffiUtil.template

local Pencil = {}

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

return Pencil
