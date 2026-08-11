local Class = require "lib.util.Class"

-- Undo/redo stacks over a Document.
--
-- A command is any table with:
--
--   apply(document)    perform the change (also used for redo)
--   revert(document)   undo it
--
-- apply and revert must be exact inverses and must be safe to run repeatedly as the
-- user walks the stack, so a command stores what it needs to reconstruct both
-- directions (a delta, or a removed element and its index) rather than reading the
-- current state when it runs.
--
-- Two ways in, because interactive edits and one-shot edits differ:
--
--   execute()     applies the command, then records it. For menu actions and
--                 anything else where the change hasn't happened yet.
--   pushApplied() records a command whose effect is already in the document.
--                 A drag mutates positions live so the user can see them follow the
--                 pointer; applying the finished command again would double the move.
local History = Class.extend()

local DEFAULT_LIMIT = 200

function History.new(limit)
    return setmetatable({
        undoStack = {},
        redoStack = {},
        limit = limit or DEFAULT_LIMIT,
    }, History)
end

function History:execute(command, document)
    command:apply(document)
    self:pushApplied(command)
    return command
end

function History:pushApplied(command)
    table.insert(self.undoStack, command)

    -- The redo branch is only reachable by undoing back to it; a new edit discards it.
    if #self.redoStack > 0 then
        self.redoStack = {}
    end

    if #self.undoStack > self.limit then
        table.remove(self.undoStack, 1)
    end

    return command
end

function History:undo(document)
    local command = table.remove(self.undoStack)
    if not command then
        return false
    end

    command:revert(document)
    table.insert(self.redoStack, command)
    return true
end

function History:redo(document)
    local command = table.remove(self.redoStack)
    if not command then
        return false
    end

    command:apply(document)
    table.insert(self.undoStack, command)
    return true
end

-- An opaque marker for the document's current state, for dirty tracking: take one
-- when the file is written, compare it against the current one to ask "has anything
-- changed since?".
--
-- The command on top of the undo stack identifies the whole sequence of edits that
-- produced the current state, which makes undoing back to the point of the last save
-- report clean again. A monotonic counter can't do that, and neither can a manual
-- dirty flag. `false` rather than nil for the empty stack, so a caller can hold the
-- marker in a table field without the field vanishing.
function History:getStateToken()
    return self.undoStack[#self.undoStack] or false
end

function History:canUndo()
    return #self.undoStack > 0
end

function History:canRedo()
    return #self.redoStack > 0
end

function History:clear()
    self.undoStack = {}
    self.redoStack = {}
end

return History
