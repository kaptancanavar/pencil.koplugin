--[[--
Annotation groups (strokes close in time and space) and their KOReader
bookmarks.

@module pencil.groups
--]]--

local Device = require("device")
local PencilGeometry = require("lib/geometry")
local Screen = Device.screen
local logger = require("logger")
local Common = require("pencil/common")
local TOOL_PEN = Common.TOOL_PEN
local TOOL_HIGHLIGHTER = Common.TOOL_HIGHLIGHTER
local GROUP_TIME_THRESHOLD_S = Common.GROUP_TIME_THRESHOLD_S
local GROUP_SPATIAL_THRESHOLD = Common.GROUP_SPATIAL_THRESHOLD

local Pencil = {}

-- Get an XPointer for a screen-space position on the current rolling-mode
-- page. Used to remember WHERE an annotation lives (so it can be re-resolved
-- to a post-rotation page) rather than just the top of the page it was
-- drawn on. Returns nil for paging docs or when the API is unavailable.
function Pencil:getXPointerAtBboxCenter(bbox)
    if not bbox then return nil end
    if not self.ui.rolling then return nil end
    if not self.ui.document or not self.ui.document.getTextFromPositions then
        return nil
    end
    local cx = math.floor((bbox.x0 + bbox.x1) / 2)
    local cy = math.floor((bbox.y0 + bbox.y1) / 2)
    local ok, range = pcall(self.ui.document.getTextFromPositions,
        self.ui.document, { x = cx, y = cy }, { x = cx, y = cy }, true)
    if ok and range and range.pos0 then
        return range.pos0
    end
    -- Fallback: nearest-line xpointer via the current scroll top.
    if self.ui.document.getXPointer then
        local ok2, xp = pcall(self.ui.document.getXPointer, self.ui.document)
        if ok2 and xp then return xp end
    end
    return nil
end

-- Resolve a group's page number in the current layout. For paging docs (PDF)
-- the saved group.page is stable. For rolling docs (EPUB) page numbers shift
-- with rotation / font / spacing changes, so re-derive from the saved
-- XPointer if we have one. Falls back to the original page number when no
-- XPointer was stored (older groups created before this code shipped).
function Pencil:getGroupCurrentPage(group)
    if not group then return nil end
    if self.ui.rolling and group.xpointer
            and self.ui.document and self.ui.document.getPageFromXPointer then
        local ok, pn = pcall(self.ui.document.getPageFromXPointer,
            self.ui.document, group.xpointer)
        if ok and pn then return pn end
    end
    return group.page
end

-- Lazily store / upgrade an XPointer for rolling-doc groups on the current
-- page. Two paths:
--   1. Legacy group with no xpointer: drop in the page-top xpointer so at
--      least same-rotation matching keeps working.
--   2. Group whose xpointer was stored at page-top (old buggy code) or for
--      any reason isn't marked precise: when we're on the same page AND in
--      the rotation the annotation was captured at, the bbox coords are
--      valid on the current screen, so we can resolve a precise per-bbox
--      xpointer. Mark xpointer_v2 to avoid repeated work.
function Pencil:backfillGroupXPointers()
    if not self.ui.rolling then return end
    if not self.ui.document or not self.ui.document.getXPointer
            or not self.ui.document.getPageFromXPointer then
        return
    end
    local cur_page = self:getCurrentPage()
    local cur_rot = Screen:getRotationMode()
    local cur_xp_top = nil
    for _, group in ipairs(self.annotation_groups or {}) do
        if group.page == cur_page then
            local upgraded = false
            if not group.xpointer_v2 and group.bbox
                    and (group.image_rotation == nil
                            or group.image_rotation == cur_rot) then
                local precise = self:getXPointerAtBboxCenter(group.bbox)
                if precise then
                    group.xpointer = precise
                    group.xpointer_v2 = true
                    self.image_data_dirty = true
                    upgraded = true
                end
            end
            if not upgraded and not group.xpointer then
                cur_xp_top = cur_xp_top or self.ui.document:getXPointer()
                if cur_xp_top then
                    group.xpointer = cur_xp_top
                    self.image_data_dirty = true
                end
            end
        end
    end
end

-- Assign a newly-added stroke to an annotation group (or create a new one).
-- Called after a stroke is finalized and inserted into self.strokes.
-- @param stroke_idx number  index of the stroke in self.strokes
-- @param skip_bookmark boolean  if true, skip bookmark sync (used during bootstrap)
-- @param skip_sig boolean  if true, leave group.sig to the caller (bulk
--        regrouping computes it once per group afterwards, not per stroke)
function Pencil:assignStrokeToGroup(stroke_idx, skip_bookmark, skip_sig)
    local stroke = self.strokes[stroke_idx]
    if not stroke then return end

    local bbox = PencilGeometry.computeStrokeBbox(stroke)
    if not bbox then return end

    local stroke_time = stroke.datetime or 0
    local best_group = nil

    for _, group in ipairs(self.annotation_groups) do
        if group.page == stroke.page then
            local time_diff = math.abs(stroke_time - (group.datetime_last or group.datetime or 0))
            if time_diff <= GROUP_TIME_THRESHOLD_S then
                local dist = PencilGeometry.bboxDistance(bbox, group.bbox)
                if dist <= GROUP_SPATIAL_THRESHOLD then
                    best_group = group
                    break
                end
            end
        end
    end

    if best_group then
        -- Merge into existing group
        table.insert(best_group.stroke_indices, stroke_idx)
        best_group.bbox = PencilGeometry.bboxUnion(best_group.bbox, bbox)
        best_group.datetime_last = math.max(best_group.datetime_last or 0, stroke_time)
        -- Update tool to majority
        local pen_count, hl_count = 0, 0
        for _, si in ipairs(best_group.stroke_indices) do
            local s = self.strokes[si]
            if s then
                if s.tool == TOOL_HIGHLIGHTER then hl_count = hl_count + 1
                else pen_count = pen_count + 1 end
            end
        end
        best_group.tool = hl_count > pen_count and TOOL_HIGHLIGHTER or TOOL_PEN
        if not skip_sig then best_group.sig = self:groupSignature(best_group) end
        if not skip_bookmark then
            self:markGroupDirty(best_group)
            -- A merged stroke invalidates the previously captured image (bbox
            -- grew); re-schedule the deferred capture.
            self:removeGroupImage(best_group)
            self:scheduleGroupImageCapture(best_group)
        end
    else
        -- Create new group
        local group = {
            id = "pencil_" .. os.date("%Y%m%d%H%M%S") .. "_" .. stroke_idx,
            page = stroke.page,
            stroke_indices = { stroke_idx },
            bbox = bbox,
            datetime = stroke_time,
            datetime_last = stroke_time,
            tool = (stroke.tool == TOOL_HIGHLIGHTER) and TOOL_HIGHLIGHTER or TOOL_PEN,
        }
        -- For rolling/EPUB docs, capture an XPointer AT THE ANNOTATION'S
        -- POSITION (bbox center) so we can re-resolve which page the
        -- annotation falls on after rotation / font change. CRITICAL: only
        -- valid when we're actually viewing the page this stroke was drawn
        -- on, because getTextFromPositions reads from the currently
        -- rendered page. During a full rebuild (after erase / undo) we
        -- process strokes from every page; for off-current-page strokes
        -- we skip the xpointer and let getGroupCurrentPage fall back to
        -- the saved group.page number. Backfill upgrades them later.
        if stroke.page == self:getCurrentPage() then
            local annot_xp = self:getXPointerAtBboxCenter(bbox)
            if annot_xp then
                group.xpointer = annot_xp
                group.xpointer_v2 = true
            end
        end
        if not skip_sig then group.sig = self:groupSignature(group) end
        table.insert(self.annotation_groups, group)
        if not skip_bookmark then
            self:markGroupDirty(group)
            self:scheduleGroupImageCapture(group)
        end
    end
end

-- Content fingerprint of a group's strokes, independent of their indices.
-- A rebuild uses it to recognize groups whose strokes didn't change, so they
-- keep their id, captured image and XPointer. Anchored strokes use their page
-- coordinates: their screen points change with every scroll.
-- O(1) per stroke: time, tool, width, point count and end points. Every edit
-- that reaches a rebuild (partial erase, lasso move, undo) changes at least
-- one of them. Summing all points made this O(points) and, as it runs on
-- every pen lift, writing got slower the fuller the page was.
function Pencil:groupSignature(group)
    local keys = {}
    for _, idx in ipairs(group.stroke_indices or {}) do
        local stroke = self.strokes[idx]
        local pts = stroke and ((stroke.anchor and stroke.dpts) or stroke.points)
        local n = pts and #pts or 0
        if n > 0 then
            local a, b = pts[1], pts[n]
            keys[#keys + 1] = string.format("%s:%s:%s:%d:%.2f,%.2f:%.2f,%.2f",
                tostring(stroke.datetime), tostring(stroke.tool), tostring(stroke.width), n,
                a.x, a.y, b.x, b.y)
        end
    end
    table.sort(keys)
    return table.concat(keys, ";")
end

-- Mark a group as needing a bookmark sync on the next deferred-work flush.
-- Keeps the heavy getPageXPointer / annotation insertion off the writing path.
function Pencil:markGroupDirty(group)
    if not self.experimental_bookmark_sync then return end
    self.dirty_groups = self.dirty_groups or {}
    self.dirty_groups[group.id] = group
end

-- Rebuild all annotation groups from scratch by re-running the grouping algorithm
-- on all existing strokes sorted by datetime. Called after erase/undo operations.
function Pencil:rebuildAnnotationGroups()
    local ok, err = pcall(function()
        -- Remove all existing bookmarks for pencil groups, and cancel any
        -- pending image captures (group ids will change).
        local old_by_sig = {}
        for _, group in ipairs(self.annotation_groups) do
            self:removeGroupBookmark(group)
            self:cancelGroupImageCapture(group.id)
            if group.sig then old_by_sig[group.sig] = group end
        end

        self.annotation_groups = {}

        -- Build list of {index, datetime} sorted by datetime. Ties keep
        -- stroke order, so unchanged strokes regroup the same way every time.
        local sorted = {}
        for i, stroke in ipairs(self.strokes) do
            table.insert(sorted, { idx = i, dt = stroke.datetime or 0 })
        end
        table.sort(sorted, function(a, b)
            if a.dt ~= b.dt then return a.dt < b.dt end
            return a.idx < b.idx
        end)

        -- Re-assign each stroke
        for _, entry in ipairs(sorted) do
            self:assignStrokeToGroup(entry.idx, nil, true)
        end
        for _, group in ipairs(self.annotation_groups) do
            group.sig = self:groupSignature(group)
        end

        -- Groups whose strokes are unchanged keep their identity: the image
        -- (on every page, not just the visible one) and the XPointer.
        local kept = {}
        for _, group in ipairs(self.annotation_groups) do
            local old = group.sig and old_by_sig[group.sig]
            if old then
                old_by_sig[group.sig] = nil
                self:cancelGroupImageCapture(group.id)
                group.id = old.id
                group.image_path, group.image_rotation = old.image_path, old.image_rotation
                if old.xpointer then
                    group.xpointer, group.xpointer_v2 = old.xpointer, old.xpointer_v2
                end
                kept[group.id] = group
                if not group.image_path then
                    self:scheduleGroupImageCapture(group)
                end
            end
        end
        -- A fresh id may equal a kept one (same second, same stroke index)
        for _, group in ipairs(self.annotation_groups) do
            if kept[group.id] and kept[group.id] ~= group then
                self:cancelGroupImageCapture(group.id)
                while kept[group.id] do group.id = group.id .. "b" end
                self:scheduleGroupImageCapture(group)
            end
        end
    end)
    if not ok then
        logger.warn("Pencil: rebuildAnnotationGroups failed:", err)
        self.annotation_groups = self.annotation_groups or {}
    end
    -- Any JPEGs whose stem no longer matches a current group.id are now stale.
    self:purgeOrphanImages()
end

-- Get page number for bookmark display (always numeric).
function Pencil:getPageNumber(page_ref)
    if type(page_ref) == "number" then
        return page_ref
    end
    -- For XPointer (rolling docs), try to convert
    if self.ui.document and self.ui.document.getPageFromXPointer then
        local pn = self.ui.document:getPageFromXPointer(page_ref)
        if pn then return pn end
    end
    return 0
end

-- Get the bookmark page reference for a group.
-- For paging mode (PDF), this is the page number.
-- For rolling mode (EPUB), this must be an XPointer.
function Pencil:getBookmarkPageRef(group_page)
    if self.ui.rolling and self.ui.document and self.ui.document.getPageXPointer then
        -- group.page is a number (from getCurrentPage), convert back to XPointer
        return self.ui.document:getPageXPointer(group_page)
    end
    return group_page
end

-- Sync a group's bookmark into KOReader's annotation system.
function Pencil:syncGroupBookmark(group)
    if not self.experimental_bookmark_sync then return end
    if not self.ui or not self.ui.annotation then
        logger.dbg("Pencil: annotation module not available, skipping bookmark sync")
        return
    end
    if not self.ui.annotation.annotations then
        logger.dbg("Pencil: annotations not loaded yet, skipping bookmark sync")
        return
    end

    local ok, err = pcall(function()
        -- Remove existing bookmark for this group first
        self:removeGroupBookmark(group)

        local pageno = self:getPageNumber(group.page)
        local bookmark_page = self:getBookmarkPageRef(group.page)
        local chapter = ""
        if self.ui.toc and self.ui.toc.getTocTitleByPage then
            chapter = self.ui.toc:getTocTitleByPage(bookmark_page) or ""
        end

        local datetime = group.id  -- use group id as unique datetime key
        group.bookmark_datetime = datetime

        local item = {
            page = bookmark_page,
            datetime = datetime,
            text = string.format("Pencil annotation on page %d", pageno),
            chapter = chapter,
        }

        if self.ui.annotation.addItem then
            self.ui.annotation:addItem(item)
            logger.dbg("Pencil: synced bookmark for group", group.id, "on page", pageno)
        else
            logger.warn("Pencil: annotation.addItem not available")
        end
    end)
    if not ok then
        logger.warn("Pencil: bookmark sync failed:", err)
    end
end

-- Remove a group's bookmark from KOReader's annotation system.
function Pencil:removeGroupBookmark(group)
    if not self.experimental_bookmark_sync then return end
    if not self.ui or not self.ui.annotation then return end
    if not group.bookmark_datetime then return end

    local ok, err = pcall(function()
        local annotations = self.ui.annotation.annotations
        if not annotations then return end

        for i, ann in ipairs(annotations) do
            if ann.datetime == group.bookmark_datetime then
                table.remove(annotations, i)
                logger.dbg("Pencil: removed bookmark for group", group.id)
                return
            end
        end
    end)
    if not ok then
        logger.warn("Pencil: bookmark removal failed:", err)
    end
end

-- Remove ALL pencil bookmarks from KOReader's annotation system.
-- Used before re-syncing to avoid duplicates.
-- Note: always runs regardless of feature flag, so disabling cleans up.
function Pencil:removeAllPencilBookmarks()
    if not self.ui or not self.ui.annotation then return end
    local annotations = self.ui.annotation.annotations
    if not annotations then return end

    -- Remove in reverse order to maintain indices
    for i = #annotations, 1, -1 do
        if annotations[i].datetime and annotations[i].datetime:match("^pencil_") then
            table.remove(annotations, i)
        end
    end
end

-- Sync all annotation groups to bookmarks (used after load/rebuild).
function Pencil:syncAllBookmarks()
    if not self.experimental_bookmark_sync then return end

    -- Clean slate: remove all pencil bookmarks first to avoid duplicates
    self:removeAllPencilBookmarks()

    for _, group in ipairs(self.annotation_groups) do
        self:syncGroupBookmark(group)
    end
    logger.info("Pencil: synced", #self.annotation_groups, "annotation group bookmarks")
end

return Pencil
