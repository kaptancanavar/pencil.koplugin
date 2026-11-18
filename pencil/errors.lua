--[[--
Error isolation: guards around everything that runs in KOReader's main loop.

@module pencil.errors
--]]--

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Pencil = {}

-- ---------------------------------------------------------------------------
-- Error isolation. Pen events, repaints, gestures and scheduled callbacks all
-- run inside KOReader's main loop, where an uncaught Lua error kills the app.
-- Everything we hook into goes through these guards instead.
-- ---------------------------------------------------------------------------

local ERROR_WINDOW_S = 10
local ERROR_LIMIT = 5

-- Log an error (each distinct message once per session, to keep the log small)
function Pencil:reportError(where, err)
    self._seen_errors = self._seen_errors or {}
    local key = where .. ":" .. tostring(err)
    if not self._seen_errors[key] then
        self._seen_errors[key] = true
        -- The reporter itself must never throw
        pcall(logger.err, "Pencil: error in", where, ":", tostring(err), debug.traceback("", 2))
    end
end

-- Stylus callback wrapper. On error: drop the half-finished gesture and let
-- the event through to KOReader. Too many errors in a short time: switch the
-- pen hook off for this document (reading keeps working) and say so once.
function Pencil:guardedStylusSlot(input, slot)
    local ok, res = pcall(self.handleStylusSlot, self, input, slot)
    if ok then return res end
    self:reportError("pen input", res)
    pcall(self.resetTransientInput, self)
    local now = os.time()
    local e = self._input_errors
    if not e or now - e.since > ERROR_WINDOW_S then
        e = { since = now, count = 0 }
        self._input_errors = e
    end
    e.count = e.count + 1
    if e.count >= ERROR_LIMIT and not self._input_disabled then
        self._input_disabled = true
        UIManager:nextTick(function()
            pcall(self.teardownStylusCallback, self)
            UIManager:show(InfoMessage:new{
                text = _("Pencil: pen input stopped after repeated errors. Reopen the book to retry. Details are in crash.log."),
                timeout = 5,
            })
        end)
    end
    return false
end

-- registerTouchZones, with every handler error-isolated (false = not handled,
-- so the gesture falls through to KOReader instead of crashing it)
function Pencil:registerZonesSafely(zones)
    for _, zone in ipairs(zones) do
        if zone.handler then
            zone.handler = self:guard("gesture " .. tostring(zone.id), zone.handler, false)
        end
    end
    self.ui:registerTouchZones(zones)
end

-- UIManager:nextTick with error isolation
function Pencil:defer(fn)
    UIManager:nextTick(function()
        local ok, err = pcall(fn)
        if not ok then self:reportError("deferred", err) end
    end)
end

-- Wrap a function so errors are logged instead of crashing the main loop.
-- Returns `fallback` on error (false for gesture handlers = "not handled").
function Pencil:guard(where, fn, fallback)
    return function(...)
        local ok, res = pcall(fn, ...)
        if ok then return res end
        self:reportError(where, res)
        return fallback
    end
end

return Pencil
