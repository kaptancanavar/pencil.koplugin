--[[--
Deferred work: settle refresh after writing, autosave, pending bookmark
syncs.

@module pencil.scheduling
--]]--

local Device = require("device")
local Geom = require("ui/geometry")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Pencil = {}

-- Schedule a delayed refresh after writing stops
function Pencil:scheduleDelayedRefresh()
    -- Cancel any existing pending refresh
    self:cancelPendingRefresh()

    -- UIManager:scheduleIn returns NOTHING — we must keep our own
    -- reference to the function we scheduled so cancelPendingRefresh can
    -- unschedule it by identity. Previously this was bugged: scheduling
    -- assigned nil to pending_refresh, so cancel never fired, and every
    -- stroke piled another 600ms timer onto the queue. Fast consecutive
    -- strokes blew past the timer and KOReader committed mid-write.
    local body
    local action = function()
        local ok, err = pcall(body)
        if not ok then self:reportError("settle refresh", err) end
    end
    body = function()
        self.pending_refresh = nil
        local region
        if self.sony_dhw_active and self.dirty_region then
            local r = self.dirty_region
            self.dirty_region = nil
            local rx = math.max(0, math.floor(r.x))
            local ry = math.max(0, math.floor(r.y))
            local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
            local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
            region = Geom:new{x = rx, y = ry, w = rw, h = rh}
            UIManager:setDirty(self.view, "fast", region)
            logger.dbg("Pencil: delayed refresh triggered (partial",
                       rx, ry, rw, rh, ")")
        else
            -- Kindle: "fast" is 1-bit A2 there, which turns the gray
            -- highlighter white and leaves text jagged. The settle-refresh
            -- after writing needs the gray-capable "ui" waveform.
            if self.settle_repaint then
                -- A highlighter preview (dot pattern) is on screen: repaint the
                -- page so the stroke is redrawn in its real gray.
                -- "partial" = REAGL on Kindle: grayscale without flashing.
                -- ("ui" is AUTO there and picks the flashing GC16 as soon as
                -- gray is present, which made the marker pop to black.)
                self.settle_repaint = false
                local r = self.settle_region
                self.settle_region = nil
                if r and self:isOverlayActive() then
                    -- A menu/dialog opened meanwhile: painting the page
                    -- directly would draw over it. Let UIManager repaint the
                    -- window stack in order instead.
                    UIManager:setDirty(self.ui.dialog or self.ui, "partial")
                elseif r then
                    -- Repaint the page, but refresh ONLY the new marker area,
                    -- directly with REAGL. Going through UIManager refreshed
                    -- the whole screen, and every 6th partial refresh gets
                    -- promoted to a flashing full refresh: all markers on the
                    -- page blinked black.
                    local x = math.max(0, math.floor(r.x0))
                    local y = math.max(0, math.floor(r.y0))
                    local w = math.min(Screen:getWidth(), math.ceil(r.x1)) - x
                    local h = math.min(Screen:getHeight(), math.ceil(r.y1)) - y
                    self.view:paintTo(Screen.bb, 0, 0)
                    if w > 0 and h > 0 then
                        Screen:refreshPartial(x, y, w, h)
                    end
                else
                    UIManager:setDirty(self.ui.dialog or self.ui, "partial")
                end
            else
                UIManager:setDirty(self.view, Device:isKindle() and "ui" or "fast")
            end
            logger.dbg("Pencil: delayed refresh triggered (full)")
        end
        -- The setDirty above queues a repaint for the next UI tick.
        -- Wipe the StylusView overlay AFTER that tick has had a chance
        -- to commit KOReader's page-with-strokes — scheduleIn(0.3)
        -- (roughly two DU waveform periods) gives the EPD time to flush.
        -- Doing it inline would clear the overlay before the page repaints,
        -- flashing the strokes off the screen briefly.
        if self.sony_dhw_active then
            UIManager:scheduleIn(0.3, function()
                local ok, android = pcall(require, "android")
                if ok and android and android.stylusOverlayClear then
                    android.stylusOverlayClear()
                end
            end)
        end
    end
    self.pending_refresh = action
    UIManager:scheduleIn(self.refresh_delay_ms / 1000, action)
end

-- Cancel pending refresh (called when new stroke starts)
function Pencil:cancelPendingRefresh()
    if self.pending_refresh then
        UIManager:unschedule(self.pending_refresh)
        self.pending_refresh = nil
    end
end

-- Mark strokes as dirty. Actual disk write is deferred until the user
-- changes page or closes the document — saving on every stroke caused
-- visible inter-stroke pauses on slow flash. flushDeferredWork is the
-- single drain point; see onPageUpdate / onUpdatePos / onCloseDocument.
-- Strokes are written on page change / close / suspend, and at the latest
-- AUTOSAVE_S after the first unsaved change, so a crash or flat battery
-- can't take a long session on one page with it.
local AUTOSAVE_S = 20

function Pencil:scheduleDeferredWork()
    self.strokes_dirty = true
    if self._autosave_fn then return end
    self._autosave_fn = function()
        self._autosave_fn = nil
        if self.pen_down or self.erasing then
            -- Never write mid-gesture; try again shortly
            return self:scheduleDeferredWork()
        end
        local ok, err = pcall(self.flushDeferredWork, self)
        if not ok then self:reportError("autosave", err) end
    end
    UIManager:scheduleIn(AUTOSAVE_S, self._autosave_fn)
end

function Pencil:cancelAutosave()
    if self._autosave_fn then
        UIManager:unschedule(self._autosave_fn)
        self._autosave_fn = nil
    end
end

function Pencil:cancelPendingSave()
    if self.pending_save then
        UIManager:unschedule(self.pending_save)
        self.pending_save = nil
    end
end

-- Run any pending deferred work immediately. Called before close, page change,
-- or any path that must persist state synchronously.
function Pencil:flushDeferredWork()
    local has_dirty_groups = self.dirty_groups and next(self.dirty_groups)
    if not self.strokes_dirty and not has_dirty_groups then
        return
    end
    self:cancelPendingSave()
    self:flushDirtyGroups()
    self:saveStrokes()
end

-- Sync bookmarks for any groups marked dirty since the last flush. No-op when
-- the experimental bookmark sync feature is off or nothing is pending.
function Pencil:flushDirtyGroups()
    if not self.dirty_groups then return end
    if not self.experimental_bookmark_sync then
        self.dirty_groups = nil
        return
    end
    for _, group in pairs(self.dirty_groups) do
        self:syncGroupBookmark(group)
    end
    self.dirty_groups = nil
end

return Pencil
