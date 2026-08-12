local Class = require "lib.util.Class"
local Gesture = require "application.Canvas.gestures.Gesture"
local Composite = require "application.Canvas.commands.Composite"
local MoveElements = require "application.Canvas.commands.MoveElements"
local ReorderElement = require "application.Canvas.commands.ReorderElement"

-- Dragging the current selection around the board.
--
-- The whole selection moves rigidly, and it's raised to the front on grab -- both
-- effects happen live, every frame, so the elements follow the pointer. finish()
-- therefore records what already happened rather than doing it again.
local MoveGesture = Class.extend(Gesture)

function MoveGesture.new(board, worldX, worldY)
    local gesture = Gesture.init(setmetatable({}, MoveGesture), board, worldX, worldY)

    gesture.ids = gesture.document:selectedIds(gesture.selection)
    gesture.raised = gesture.document:raiseAllToFront(gesture.ids)

    -- Positions are captured up front and every frame's move is computed from them,
    -- rather than accumulating per-frame deltas: accumulating drifts, and it makes an
    -- element that was added or removed mid-drag desync from the rest of the group.
    gesture.origins = {}
    for _, id in ipairs(gesture.ids) do
        local element = gesture.document:getById(id)
        gesture.origins[id] = { x = element.x, y = element.y }
    end

    return gesture
end

function MoveGesture:update()
    local dx, dy = self:getDelta()

    for _, id in ipairs(self.ids) do
        local element = self.document:getById(id)
        local origin = self.origins[id]
        if element and origin then
            element:setPosition(origin.x + dx, origin.y + dy)
        end
    end
end

-- One undo step for the whole gesture, so Ctrl+Z returns every moved element to
-- where it was -- and to the depth it was at -- when the drag started, rather than
-- stepping back through every frame of it or leaving the group raised.
function MoveGesture:finish()
    local commands = {}

    for _, raise in ipairs(self.raised) do
        table.insert(commands, ReorderElement.new(raise.id, raise.fromIndex, raise.toIndex))
    end

    -- The group moved rigidly, so any one member's delta describes the whole gesture.
    -- Measured off the element rather than off the pointer so a move that the element
    -- didn't actually take (it was deleted mid-drag) records nothing.
    local sampleId = self.ids[1]
    if sampleId then
        local element = self.document:getById(sampleId)
        local origin = self.origins[sampleId]
        if element and origin then
            local dx = element.x - origin.x
            local dy = element.y - origin.y
            if dx ~= 0 or dy ~= 0 then
                table.insert(commands, MoveElements.new(self.ids, dx, dy))
            end
        end
    end

    return Composite.of(commands), true
end

return MoveGesture
