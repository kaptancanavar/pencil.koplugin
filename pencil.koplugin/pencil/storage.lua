--[[--
Saving and loading strokes (pencil_strokes.lua in the sidecar dir).

@module pencil.storage
--]]--

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local ffiUtil = require("ffi/util")
local Common = require("pencil/common")
local TOOL_PEN = Common.TOOL_PEN

local Pencil = {}

-- Get the pencil strokes file path for this document
function Pencil:getStrokesFilePath()
    if not self.ui or not self.ui.doc_settings then
        logger.warn("Pencil: doc_settings not available")
        return nil
    end
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        return sidecar_dir .. "/pencil_strokes.lua"
    end
    logger.warn("Pencil: sidecar_dir not available")
    return nil
end

-- Load strokes from our own file
function Pencil:loadStrokes()
    local filepath = self:getStrokesFilePath()
    logger.info("Pencil: loadStrokes - filepath =", filepath)

    if not filepath then
        logger.warn("Pencil: no filepath available for loading strokes")
        self.strokes = {}
        self.page_strokes = {}
        return
    end

    -- Read a strokes file; nil + reason if missing or unusable
    local function readStrokesFile(path)
        if lfs.attributes(path, "mode") ~= "file" then return nil, "missing" end
        local ok, data = pcall(dofile, path)
        if ok and type(data) == "table" and type(data.strokes) == "table" then
            return data
        end
        return nil, ok and "unexpected content" or tostring(data)
    end

    local data, reason = readStrokesFile(filepath)
    local recovered = false
    if not data and reason ~= "missing" then
        -- Damaged (e.g. power loss mid-write with an older version of this
        -- plugin). Move it aside so no later save can overwrite it, then
        -- fall back to the previous version.
        local aside = filepath .. ".broken-" .. os.date("%Y%m%d-%H%M%S")
        os.rename(filepath, aside)
        logger.err("Pencil: strokes file unreadable (", reason, "), moved to", aside)
    end
    local from_backup = false
    if not data then
        -- A complete .tmp (crash between writing and renaming it) is newer
        -- than .old; a truncated one doesn't parse and is skipped.
        data = readStrokesFile(filepath .. ".tmp") or readStrokesFile(filepath .. ".old")
        from_backup = data ~= nil
        recovered = from_backup and reason ~= "missing"
    end
    if recovered then
        logger.warn("Pencil: restored strokes from backup", filepath .. ".old")
        UIManager:nextTick(function()
            UIManager:show(InfoMessage:new{
                text = _("Pencil: the annotation file was damaged. The last backup was restored."),
                timeout = 4,
            })
        end)
    end
    if not data then
        logger.info("Pencil: no strokes file (or nothing recoverable):", filepath)
        self.strokes = {}
        self.page_strokes = {}
        self.notes = {}
        -- Safe to save now: a damaged file was moved aside above
        self.strokes_loaded = true
        return
    end

    do
        -- Convert saved strokes back to usable format. A single malformed
        -- entry is skipped instead of failing the whole book.
        self.strokes = {}
        local skipped = 0
        for _, saved in ipairs(data.strokes) do
            local sok, stroke = pcall(self.strokeFromSaved, self, saved)
            if sok and stroke and type(stroke.points) == "table" and stroke.page then
                table.insert(self.strokes, stroke)
            else
                skipped = skipped + 1
            end
        end
        if skipped > 0 then
            logger.warn("Pencil: skipped", skipped, "malformed strokes")
        end
        self:rebuildPageIndex()
        self.notes = {}
        for _, n in ipairs(type(data.notes) == "table" and data.notes or {}) do
            if type(n) == "table" and type(n.x) == "number" and type(n.y) == "number"
                    and n.page ~= nil and type(n.text) == "string" then
                table.insert(self.notes, n)
            end
        end

        -- Load annotation groups or bootstrap from v1 data. Saved groups
        -- refer to strokes by index, so after skipping any they're rebuilt.
        if skipped == 0 and type(data.annotation_groups) == "table" and #data.annotation_groups > 0 then
            self.annotation_groups = data.annotation_groups
            logger.info("Pencil: loaded", #self.annotation_groups, "annotation groups")
        else
            -- v1 data or no groups — bootstrap by running grouping on all strokes
            -- skip_bookmark=true because annotation module isn't ready yet during load
            logger.info("Pencil: bootstrapping annotation groups from strokes")
            self.annotation_groups = {}
            local sorted = {}
            for i, stroke in ipairs(self.strokes) do
                table.insert(sorted, { idx = i, dt = stroke.datetime or 0 })
            end
            table.sort(sorted, function(a, b) return a.dt < b.dt end)
            for _, entry in ipairs(sorted) do
                self:assignStrokeToGroup(entry.idx, true)
            end
        end

        self.strokes_loaded = true
        if from_backup or skipped > 0 then
            -- Write the recovered state back as the main file
            self:scheduleDeferredWork()
        end
        logger.info("Pencil: loaded", #self.strokes, "strokes from", filepath)
    end
end

-- Convert stroke for saving (remove non-serializable values)
function Pencil:strokeToSaveable(stroke)
    return {
        page = stroke.page,
        vkey = stroke.vkey,
        anchor = stroke.anchor or nil,   -- then points are page coordinates
        tool = stroke.tool,
        width = stroke.width,
        alpha = stroke.alpha,
        datetime = stroke.datetime,
        points = (stroke.anchor and stroke.dpts) or stroke.points,
        color_name = stroke.color_name,  -- Save color name for persistence
        pen_type = stroke.pen_type,
    }
end

-- Convert saved stroke back to usable format
function Pencil:strokeFromSaved(saved)
    local tool = saved.tool or TOOL_PEN
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]

    -- Look up color from color_name
    local color = tool_settings.color
    if saved.color_name then
        for _, color_info in ipairs(self.available_colors) do
            if color_info.name == saved.color_name then
                color = color_info.color
                break
            end
        end
    end

    local stroke = {
        page = saved.page,
        vkey = type(saved.vkey) == "string" and saved.vkey or nil,
        tool = saved.tool,
        width = saved.width or tool_settings.width,
        color = color,
        color_name = saved.color_name,
        alpha = saved.alpha or tool_settings.alpha,
        datetime = saved.datetime,
        points = saved.points,
        pen_type = saved.pen_type,
    }
    if saved.anchor == true and type(saved.points) == "table" then
        -- page coordinates; stroke.points gets projected before first use
        stroke.anchor = true
        local d, pts = {}, {}
        for i, pt in ipairs(saved.points) do
            d[i] = { x = pt.x, y = pt.y, p = pt.p }
            pts[i] = { x = pt.x, y = pt.y, p = pt.p }
        end
        stroke.dpts, stroke.points = d, pts
    end
    return stroke
end

-- Save strokes to our own file
function Pencil:saveStrokes()
    local filepath = self:getStrokesFilePath()
    logger.info("Pencil: saveStrokes - filepath =", filepath, "strokes count =", #self.strokes)

    if not filepath then
        logger.warn("Pencil: no filepath available for saving strokes")
        return
    end

    -- Safety: don't save empty data if strokes were never successfully loaded
    -- (prevents data loss if a crash causes save before load completes)
    if #self.strokes == 0 and not self.strokes_loaded then
        logger.warn("Pencil: refusing to save empty strokes (strokes never loaded)")
        return
    end

    -- Ensure the directory exists
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        local ok, err = lfs.mkdir(sidecar_dir)
        if not ok and err ~= "File exists" then
            logger.warn("Pencil: failed to create sidecar dir:", err)
        end
    end

    -- Convert strokes to saveable format (remove non-serializable values)
    local saveable_strokes = {}
    for i, stroke in ipairs(self.strokes) do
        saveable_strokes[i] = self:strokeToSaveable(stroke)
    end

    -- Serialize and write. Version 3 marks files that may contain image_path /
    -- image_rotation fields on annotation groups; older readers can ignore
    -- those fields and continue to use the strokes directly.
    local data = {
        version = 3,
        strokes = saveable_strokes,
        annotation_groups = self.annotation_groups,
        notes = self.notes,   -- sticky notes (optional; older readers ignore it)
    }

    local ok, err = self:writeFileAtomic(filepath, "return " .. require("dump")(data) .. "\n")
    if ok then
        self.strokes_dirty = false
        logger.info("Pencil: saved", #self.strokes, "strokes to", filepath)
    else
        -- strokes_dirty stays set: the next page change / autosave retries
        logger.err("Pencil: failed to save strokes:", filepath, "error:", err)
    end
end

-- Write a file so that a crash or power loss at any moment leaves either the
-- old or the new version, never a half-written one: write to .tmp, fsync,
-- then rename over the original. The previous version is kept as .old (like
-- KOReader's own settings, only if it's over a minute old, so a burst of
-- saves doesn't rotate a good backup away).
function Pencil:writeFileAtomic(path, content)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return nil, err end
    local wok, werr = f:write(content)
    if wok then pcall(ffiUtil.fsyncOpenedFile, f) end
    local cok, cerr = f:close()
    if not wok or not cok then
        os.remove(tmp)   -- e.g. disk full: keep the existing file untouched
        return nil, werr or cerr
    end
    local mtime = lfs.attributes(path, "modification")
    if mtime and mtime < os.time() - 60 then
        os.remove(path .. ".old")
        os.rename(path, path .. ".old")
    end
    local rok, rerr = os.rename(tmp, path)
    if not rok and lfs.attributes(path, "mode") == "file" then
        -- Filesystems that refuse to rename over an existing file: remove
        -- it first. If we crash right here, loadStrokes recovers the .tmp.
        os.remove(path)
        rok, rerr = os.rename(tmp, path)
    end
    if not rok then
        return nil, rerr   -- .tmp is kept: it's complete and loadStrokes can use it
    end
    pcall(ffiUtil.fsyncDirectory, path)
    return true
end

return Pencil
