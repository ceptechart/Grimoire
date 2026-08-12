local Class = require "lib.util.Class"
local Gesture = require "application.Canvas.gestures.Gesture"
local RectResize = require "application.Canvas.RectResize"
local ElementRegistry = require "application.Canvas.ElementRegistry"
local Containment = require "application.Canvas.Containment"
local Composite = require "application.Canvas.commands.Composite"
local ResizeElement = require "application.Canvas.commands.ResizeElement"
local ReorderElement = require "application.Canvas.commands.ReorderElement"

-- Dragging one element's edge or corner.
--
-- Deliberately single-element: resizing a group means scaling each member's rect
-- proportionally inside the group's bounding box, which is a different operation
-- from shifting one rect's edges. Board narrows the selection to the grabbed element
-- before starting this.
--
-- Like a move, the element is reshaped live and finish() records what already
-- happened.
local ResizeGesture = Class.extend(Gesture)

function ResizeGesture.new(board, element, handle, worldX, worldY)
    local gesture = Gesture.init(setmetatable({}, ResizeGesture), board, worldX, worldY)

    gesture.id = element.id
    gesture.handle = handle
    gesture.origin = { x = element.x, y = element.y, width = element.width, height = element.height }

    -- minSizeOf rather than minSize: a container's minimum is its contents', not its
    -- type's static default, so grabbing its own edge can't shrink it past what's
    -- laid out inside it. The same call answers the type default for anything else.
    gesture.minWidth, gesture.minHeight = ElementRegistry:minSizeOf(element, gesture.document)

    -- Raised together with whatever it lays out, not on its own -- raising just the
    -- element would put it past its own children in document order (append-to-front
    -- is a move to the *end* of the array), which draws it in front of the very
    -- things it's supposed to sit behind. withDescendants is a no-op list of one for
    -- anything that isn't a container, so this is exactly the old behaviour there.
    gesture.raised = gesture.document:raiseAllToFront(
        Containment.withDescendants(gesture.document, { element.id }))

    return gesture
end

function ResizeGesture:update()
    local element = self.document:getById(self.id)
    if not element then
        return
    end

    local dx, dy = self:getDelta()
    element.x, element.y, element.width, element.height =
        RectResize.apply(self.handle, self.origin, dx, dy, self.minWidth, self.minHeight)
end

function ResizeGesture:finish()
    local commands = {}

    for _, raise in ipairs(self.raised) do
        table.insert(commands, ReorderElement.new(raise.id, raise.fromIndex, raise.toIndex))
    end

    local element = self.document:getById(self.id)
    if element then
        local dx = element.x - self.origin.x
        local dy = element.y - self.origin.y
        local dWidth = element.width - self.origin.width
        local dHeight = element.height - self.origin.height
        if dx ~= 0 or dy ~= 0 or dWidth ~= 0 or dHeight ~= 0 then
            table.insert(commands, ResizeElement.new(self.id, dx, dy, dWidth, dHeight))
        end
    end

    return Composite.of(commands), true
end

return ResizeGesture
