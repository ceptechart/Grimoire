local Class = require "lib.util.Class"

-- Base for the pointer gestures on the board: move, resize, marquee, create.
--
-- All four have the same life cycle -- begun by a press, advanced by every move,
-- resolved into an undo step by the release -- so Board holds exactly one of them at
-- a time in `self.gesture` and drives it through this interface rather than
-- branching on which kind it is. Adding a gesture (space-pan, drawing a connector,
-- group-resize) is a file here plus the one line in Board:mousepressed that picks it.
--
-- Subclasses implement:
--
--   update()          advance the live edit; called after every pointer move.
--   finish()          -> command, alreadyApplied
--                     Resolve the gesture. `command` may be nil for a gesture that
--                     changed nothing undoable (a marquee, or a drag that ended
--                     where it started). `alreadyApplied` distinguishes the two ways
--                     a gesture can have touched the document -- see below.
--   draw()            optional. Whatever the gesture needs on screen that isn't
--                     already an element: the marquee rect, the pending element.
--                     Called inside the canvas transform, so it draws in world space.
--
-- The `alreadyApplied` flag is the drag/create split that History cares about. Move
-- and resize mutate their elements live every frame so they follow the pointer, so
-- their command records a change already in the document (pushApplied). Create builds
-- its element outside the document entirely and only adds it on release, so its
-- command is the change happening for the first time (execute).
--
-- A gesture captures the document at construction. That's safe because swapping
-- documents drops the gesture (see Board:setDocument) -- a gesture holding ids from a
-- document that's been closed has nothing to resolve against.
local Gesture = Class.extend()

function Gesture.init(gesture, board, worldX, worldY)
    gesture.board = board
    gesture.document = board.document
    gesture.selection = board.selection

    gesture.startX, gesture.startY = worldX, worldY
    gesture.currentX, gesture.currentY = worldX, worldY

    return gesture
end

-- Called by Board on every pointer move, in world coordinates.
function Gesture:move(worldX, worldY)
    self.currentX, self.currentY = worldX, worldY
    self:update()
end

-- Pointer travel since the press, which is what every gesture actually works in:
-- deltas survive a pan or zoom mid-drag, absolute positions don't.
function Gesture:getDelta()
    return self.currentX - self.startX, self.currentY - self.startY
end

function Gesture:update()
end

function Gesture:finish()
    return nil, false
end

return Gesture
