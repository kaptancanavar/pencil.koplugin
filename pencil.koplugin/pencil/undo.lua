--[[--
Undo / redo of added, erased, moved and cleared strokes.

@module pencil.undo
--]]--

local UIManager = require("ui/uimanager")

local Pencil = {}

-- Undo last stroke
local UNDO_LIMIT = 100

-- Record a new undoable action. Any new action invalidates the redo history.
-- "add" actions also keep the stroke itself: stroke_idx alone goes stale as
-- soon as an earlier stroke is erased (indices shift), and undo then removed
-- the wrong stroke. The history is capped to bound memory.
function Pencil:pushUndo(action)
    if action.type == "add" and not action.stroke and action.stroke_idx then
        action.stroke = self.strokes[action.stroke_idx]
    end
    table.insert(self.undo_stack, action)
    if #self.undo_stack > UNDO_LIMIT then
        table.remove(self.undo_stack, 1)
    end
    self.redo_stack = {}
end

-- Current index of a stroke (nil if it's gone)
function Pencil:findStrokeIndex(stroke)
    for i = #self.strokes, 1, -1 do
        if self.strokes[i] == stroke then return i end
    end
end

function Pencil:undoLastStroke()
    if #self.undo_stack == 0 then return end

    local last_action = table.remove(self.undo_stack)
    self.lasso_selection = nil   -- its bbox may no longer match
    if last_action.type == "move" then
        self:shiftStrokes(last_action.strokes, -last_action.dx, -last_action.dy)
        table.insert(self.redo_stack, last_action)
        self:rebuildPageIndex()
        self:rebuildAnnotationGroups()
        self:scheduleDeferredWork()
        UIManager:setDirty(self.ui.dialog or self.ui, "ui")
    elseif last_action.type == "add" then
        -- Remove the stroke that was added (found by identity, see pushUndo)
        local stroke_idx
        if last_action.stroke then
            stroke_idx = self:findStrokeIndex(last_action.stroke)
        else
            stroke_idx = last_action.stroke_idx
        end
        local stroke = stroke_idx and self.strokes[stroke_idx]
        if stroke then
            table.remove(self.strokes, stroke_idx)
            table.insert(self.redo_stack, { type = "add", stroke = stroke })
            self:rebuildPageIndex()
            self:rebuildAnnotationGroups()
            self:scheduleDeferredWork()
            UIManager:setDirty(self.ui.dialog or self.ui, "ui")
        end
    elseif last_action.type == "delete" then
        -- Partial erase leaves pieces behind (stroke._split_into, possibly
        -- split again). Remove every such piece, then restore the originals.
        local pieces = {}
        local function collect(stroke)
            for _, piece in ipairs(stroke._split_into or {}) do
                pieces[piece] = true
                collect(piece)
            end
        end
        for _, stroke in ipairs(last_action.strokes) do
            collect(stroke)
        end
        -- Remember what we change, so redo can put it back exactly.
        local saved_split = {}
        for _, stroke in ipairs(last_action.strokes) do
            saved_split[stroke] = stroke._split_into
        end
        local removed_pieces = {}
        if next(pieces) then
            for i = #self.strokes, 1, -1 do
                if pieces[self.strokes[i]] then
                    table.insert(removed_pieces, 1, self.strokes[i])
                    table.remove(self.strokes, i)
                end
            end
        end
        -- Restore deleted strokes (skipping pieces that were erased again)
        local restored = {}
        for _, stroke in ipairs(last_action.strokes) do
            if not pieces[stroke] then
                stroke._split_into = nil
                table.insert(self.strokes, stroke)
                table.insert(restored, stroke)
            end
        end
        table.insert(self.redo_stack, {
            type = "delete",
            action = last_action,
            restored = restored,
            removed_pieces = removed_pieces,
            saved_split = saved_split,
        })
        self:rebuildPageIndex()
        self:rebuildAnnotationGroups()
        self:scheduleDeferredWork()
        UIManager:setDirty(self.ui.dialog or self.ui, "ui")
    end
end

-- Re-apply the last undone action.
function Pencil:redoLastStroke()
    if not self.redo_stack or #self.redo_stack == 0 then return end

    local entry = table.remove(self.redo_stack)
    self.lasso_selection = nil
    if entry.type == "move" then
        self:shiftStrokes(entry.strokes, entry.dx, entry.dy)
        table.insert(self.undo_stack, entry)
    elseif entry.type == "add" then
        table.insert(self.strokes, entry.stroke)
        -- Direct insert: pushUndo would clear the rest of the redo history.
        table.insert(self.undo_stack, { type = "add", stroke = entry.stroke, stroke_idx = #self.strokes })
    elseif entry.type == "delete" then
        -- Take the restored originals out again...
        local restored = {}
        for _, stroke in ipairs(entry.restored) do
            restored[stroke] = true
        end
        for i = #self.strokes, 1, -1 do
            if restored[self.strokes[i]] then
                table.remove(self.strokes, i)
            end
        end
        -- ...put the leftover pieces of a partial erase back...
        for _, piece in ipairs(entry.removed_pieces) do
            table.insert(self.strokes, piece)
        end
        -- ...and re-link originals to their pieces so a later undo works.
        for stroke, split in pairs(entry.saved_split) do
            stroke._split_into = split
        end
        table.insert(self.undo_stack, entry.action)
    end
    self:rebuildPageIndex()
    self:rebuildAnnotationGroups()
    self:scheduleDeferredWork()
    UIManager:setDirty(self.ui.dialog or self.ui, "ui")
end

return Pencil
