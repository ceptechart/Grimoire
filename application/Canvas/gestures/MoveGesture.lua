local Class = require "lib.util.Class"
local Theme = require "application.Style.Theme"
local Canvas = require "application.Canvas.Canvas"
local Gesture = require "application.Canvas.gestures.Gesture"
local Containment = require "application.Canvas.Containment"
local Composite = require "application.Canvas.commands.Composite"
local MoveElements = require "application.Canvas.commands.MoveElements"
local ReorderElement = require "application.Canvas.commands.ReorderElement"
local SetRect = require "application.Canvas.commands.SetRect"

-- Dragging the current selection around the board, and in and out of containers.
--
-- The whole selection moves rigidly, and it's raised to the front on grab -- both
-- effects happen live, every frame, so the elements follow the pointer. finish()
-- therefore records what already happened rather than doing it again.
--
-- Containment rides on the same drag rather than being a gesture of its own, because
-- it *is* the same drag: dragging an element out of a container, into another one, or
-- to a different slot in the one it's in are all "pick this up and put it down
-- somewhere", and splitting them would mean deciding which one had begun before the
-- pointer had said. So a drag that starts on an element some container lays out takes
-- it out of that container, and a drag that ends over one puts it in.
local MoveGesture = Class.extend(Gesture)

-- Screen pixels of travel before a drag counts as a drag. Below it nothing is
-- detached and nothing is dropped, which is what keeps a plain click on a child's
-- header from quietly popping it out of its container and putting it back somewhere
-- else. Same idea as CreateGesture's CLICK_THRESHOLD, and in screen pixels for the
-- same reason: it's a measure of pointer jitter, which doesn't scale with zoom.
local DRAG_THRESHOLD = 4

function MoveGesture.new(board, worldX, worldY)
    local gesture = Gesture.init(setmetatable({}, MoveGesture), board, worldX, worldY)

    local selected = gesture.document:selectedIds(gesture.selection)

    -- What actually gets moved. An element whose container is also in the selection
    -- is carried by that container's layout, so moving it here as well would double
    -- every step the pointer took.
    gesture.ids = Containment.withoutContainedBy(gesture.document, selected)

    -- Raised with their contents, so a container comes to rest behind the children it
    -- lays out rather than in front of them. raiseAllToFront keeps the group's
    -- internal order, so "behind" stays true afterwards.
    gesture.raised = gesture.document:raiseAllToFront(
        Containment.withDescendants(gesture.document, selected))

    -- Positions are captured up front and every frame's move is computed from them,
    -- rather than accumulating per-frame deltas: accumulating drifts, and it makes an
    -- element that was added or removed mid-drag desync from the rest of the group.
    gesture.origins = {}
    for _, id in ipairs(gesture.ids) do
        local element = gesture.document:getById(id)
        gesture.origins[id] = { x = element.x, y = element.y }
    end

    -- Only a one-element drag can be dropped into a container: a drop descriptor
    -- names a single slot, and there's no obvious answer for what a group of four
    -- should mean. A group is still detached from whatever held it, since that's the
    -- part the user can see happening.
    if #gesture.ids == 1 then
        local element = gesture.document:getById(gesture.ids[1])
        gesture.dragged = element
        gesture.originRect = {
            x = element.x, y = element.y,
            width = element.width, height = element.height,
        }
    end

    gesture.detached = {}

    return gesture
end

-- Takes everything being dragged out of whatever lays it out, so the pointer -- and
-- not the next layout pass -- decides where it goes.
--
-- Deferred until the drag passes the threshold rather than done on the press, so a
-- click that happens to land on a child's title bar leaves the container alone.
function MoveGesture:detach()
    for _, id in ipairs(self.ids) do
        local command = Containment.detach(self.document, id)
        if command then
            self.detached[#self.detached + 1] = command
        end
    end
end

-- Whether the containment of anything moved, which is what decides how the dragged
-- element's geometry gets recorded (see finish).
function MoveGesture:rearranged()
    return #self.detached > 0 or self.drop ~= nil
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

    if not self.dragging then
        local threshold = DRAG_THRESHOLD / Canvas.zoom
        if math.abs(dx) < threshold and math.abs(dy) < threshold then
            return
        end
        self.dragging = true
        self:detach()
    end

    if self.dragged then
        self.dropTarget, self.drop = Containment.dropTargetAt(
            self.document, self.currentX, self.currentY, self.dragged)
    end
end

-- One undo step for the whole gesture, so Ctrl+Z returns every moved element to
-- where it was -- and to the depth it was at, and to the container it came out of --
-- when the drag started, rather than stepping back through every frame of it.
function MoveGesture:finish()
    local commands = {}

    for _, raise in ipairs(self.raised) do
        commands[#commands + 1] = ReorderElement.new(raise.id, raise.fromIndex, raise.toIndex)
    end

    for _, command in ipairs(self.detached) do
        commands[#commands + 1] = command
    end

    if self.drop and self.dropTarget then
        for _, command in ipairs(Containment.attach(
            self.document, self.dropTarget, self.drop, self.dragged.id)) do
            commands[#commands + 1] = command
        end
    end

    if self.dragged and self:rearranged() then
        -- Settled here rather than at the next frame's pass, so the rect recorded
        -- below is the one the element will actually be sitting at.
        Containment.layoutAll(self.document)

        -- An element that has joined or left a container doesn't have a delta any
        -- more: on the way in its rect becomes whatever the layout gives it, and undo
        -- has to put back the rect it had before the drag rather than subtract the
        -- distance the pointer travelled. Hence a SetRect over a MoveElements -- and
        -- only for the dragged element, since everything else in a group drag kept
        -- its own geometry.
        if SetRect.differs(self.dragged, self.originRect) then
            commands[#commands + 1] = SetRect.new(self.dragged.id, self.originRect, self.dragged)
        end

        return Composite.of(commands), true
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
                commands[#commands + 1] = MoveElements.new(self.ids, dx, dy)
            end
        end
    end

    return Composite.of(commands), true
end

-- The slot the element would land in if it were let go here. Drawn over the elements
-- but under the selection outlines, like the other gestures that draw -- it belongs
-- in front of the container it's describing, and it shouldn't wash out the outline of
-- what's being dragged.
function MoveGesture:draw()
    if not self.drop then
        return
    end

    local r, g, b, a = love.graphics.getColor()
    local previousLineWidth = love.graphics.getLineWidth()
    local radius = Theme:metric("cornerRadius")

    love.graphics.setColor(Theme:color("dropTargetFill"):unpacked())
    love.graphics.rectangle("fill", self.drop.x, self.drop.y, self.drop.width, self.drop.height, radius, radius)

    love.graphics.setColor(Theme:color("dropTargetBorder"):unpacked())
    -- Two screen pixels whatever the zoom, like every other hairline drawn in world
    -- space -- doubled because this one has to read through the ghost over it.
    love.graphics.setLineWidth(2 / Canvas.zoom)
    love.graphics.rectangle("line", self.drop.x, self.drop.y, self.drop.width, self.drop.height, radius, radius)

    love.graphics.setLineWidth(previousLineWidth)
    love.graphics.setColor(r, g, b, a)
end

return MoveGesture
