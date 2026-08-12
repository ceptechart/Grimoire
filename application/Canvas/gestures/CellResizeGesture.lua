local Class = require "lib.util.Class"
local Gesture = require "application.Canvas.gestures.Gesture"
local RectResize = require "application.Canvas.RectResize"
local ElementRegistry = require "application.Canvas.ElementRegistry"
local ContainerLayout = require "application.Canvas.ContainerLayout"
local ContainerElement = require "application.Canvas.elements.ContainerElement"
local Containment = require "application.Canvas.Containment"
local Composite = require "application.Canvas.commands.Composite"
local SetProps = require "application.Canvas.commands.SetProps"
local ResizeElement = require "application.Canvas.commands.ResizeElement"

-- Dragging the edge of an element that a container lays out.
--
-- An element inside a container doesn't own its rect, so the plain ResizeGesture has
-- nothing to write to -- the next layout pass would put it straight back. What the
-- drag moves instead is the boundary it grabbed: the split node either side of that
-- boundary trade space against each other, so the container's own size doesn't
-- change and neither does anything outside the pair.
--
-- The boundary isn't necessarily the grabbed element's *own* row or column: if its
-- immediate parent has nothing on that side (a lone cell in a row, say), the search
-- walks up the tree looking for the first ancestor split that runs the drag's axis
-- *and* has a live neighbour there, and trades at that level instead -- which is what
-- makes "resize the row this is in" and "resize the whole block of rows this sits
-- inside" the same gesture at two different depths, the same way MoveGesture's drop
-- makes "join this row" and "span the whole container" the same drop at two
-- different scopes. Reaching the tree's root without finding one means the edge
-- really is the container's own, and that's what resizes instead.
--
-- Like the other drags, the edit happens live every frame and finish() records what
-- has already happened.
local CellResizeGesture = Class.extend(Gesture)

-- Weight changes below this are the drag not having moved rather than a resize, and
-- recording one would put an undo step on the stack that undoes nothing.
local EPSILON = 1e-9

function CellResizeGesture.new(board, container, child, handle, worldX, worldY)
    local gesture = Gesture.init(setmetatable({}, CellResizeGesture), board, worldX, worldY)

    gesture.containerId = container.id
    gesture.handle = handle
    -- Never written to: it's the `old` half of this gesture's undo step, and every
    -- edit builds a fresh tree over the top (see ContainerLayout's header).
    gesture.originTree = container.props.layout
    gesture.originRect = {
        x = container.x, y = container.y,
        width = container.width, height = container.height,
    }
    gesture.minWidth, gesture.minHeight = ElementRegistry:minSizeOf(container, gesture.document)

    -- The path to the grabbed leaf, captured once against the layout as it stands at
    -- the press -- every frame's trade is computed from these same origin sizes and
    -- the *total* pointer travel, not accumulated per frame, for the same reason
    -- MoveGesture captures its origins: accumulating drifts, and it makes a drag that
    -- clamps at a minimum and comes back not land where it started. The structure a
    -- path walks (which node is whose sibling) can't change mid-drag -- only weights
    -- do -- so one path serves the whole gesture.
    local layout = ElementRegistry:contentLayout(container, gesture.document)
    gesture.path = layout.root and ContainerLayout.pathToLeaf(layout.root, child.id) or {}

    return gesture
end

-- Walks `self.path` from the grabbed leaf's immediate parent up toward the root,
-- returning the first split running `axis` that has a live neighbour in the
-- direction `sign` (-1 toward its start, +1 toward its end). `a`/`b` are the two
-- resolved nodes that would trade space; `parentRaw`/`indexPath`/`indexA`/`indexB`
-- locate them in the *stored* tree for ContainerLayout.withPairWeight to write to.
-- Nil means the drag reached the top without finding one -- the true outer edge.
function CellResizeGesture:findBoundary(axis, sign)
    for depth = #self.path, 1, -1 do
        local entry = self.path[depth]
        if entry.resolved.direction == axis then
            local neighbourIndex = entry.resolvedIndex + sign
            local neighbour = entry.resolved.children[neighbourIndex]
            if neighbour then
                local a = entry.resolved.children[entry.resolvedIndex]
                local indexPath = {}
                for level = 1, depth - 1 do
                    indexPath[level] = self.path[level].rawIndex
                end
                return a, neighbour, indexPath, entry.rawIndex,
                    ContainerLayout.indexOfRaw(entry.resolved.raw, neighbour.raw)
            end
        end
    end
    return nil
end

-- Moves the boundary between two neighbouring nodes by `growth`, clamped so neither
-- goes under the minimum size of what it holds. Returns the sizes the pair ends up
-- at, and whether that's anywhere other than where they started.
local function trade(a, b, growth)
    local total = a.size + b.size
    local size = math.max(a.min, math.min(a.size + growth, total - b.min))
    return size, total - size, math.abs(size - a.size) > EPSILON
end

-- Finds the boundary for one axis and, if there is one, appends the weight change it
-- implies to `changes`. Returns false when there's nothing to trade with -- the
-- caller's signal to fall through to resizing the container along that edge instead.
function CellResizeGesture:tradeBoundary(changes, axis, sign, delta)
    local a, b, indexPath, indexA, indexB = self:findBoundary(axis, sign)
    if not a then
        return false
    end

    local minAWidth, minAHeight = ContainerLayout.minSize(a.raw, self.document, ContainerElement.GAP)
    local minBWidth, minBHeight = ContainerLayout.minSize(b.raw, self.document, ContainerElement.GAP)
    local sizeA = axis == "row" and a.width or a.height
    local sizeB = axis == "row" and b.width or b.height
    local minA = axis == "row" and minAWidth or minAHeight
    local minB = axis == "row" and minBWidth or minBHeight

    -- Dragging the edge closest to the start of the pair (sign -1: west or north)
    -- outward is a negative delta and grows the first of the two, so the direction
    -- the handle faces is also the sign of the growth it implies.
    local newSizeA, newSizeB, moved = trade({ size = sizeA, min = minA }, { size = sizeB, min = minB }, sign * delta)
    local weightA, weightB = ContainerLayout.splitWeight(
        (a.raw.weight or 1) + (b.raw.weight or 1), newSizeA, newSizeB)

    changes[#changes + 1] = { indexPath = indexPath, indexA = indexA, weightA = weightA, indexB = indexB, weightB = weightB }
    self.changed = self.changed or moved
    return true
end

function CellResizeGesture:update()
    local container = self.document:getById(self.containerId)
    -- The suffix is parsed rather than searched for in the whole handle name, because
    -- "resize" itself contains an s and an e.
    local suffix = self.handle:match("^resize%-(%a+)$")
    if not container or not suffix then
        return
    end

    local dx, dy = self:getDelta()
    local changes = {}
    -- The edges with no boundary to trade at, which fall through to the container.
    -- Column (n/s) first, then row (w/e), so the handle this builds reads the way
    -- RectResize's own names do ("resize-ne", never "resize-en").
    local containerEdges = ""

    local columnSign = suffix:find("n") and -1 or suffix:find("s") and 1
    if columnSign and not self:tradeBoundary(changes, "column", columnSign, dy) then
        containerEdges = containerEdges .. (columnSign < 0 and "n" or "s")
    end

    local rowSign = suffix:find("w") and -1 or suffix:find("e") and 1
    if rowSign and not self:tradeBoundary(changes, "row", rowSign, dx) then
        containerEdges = containerEdges .. (rowSign < 0 and "w" or "e")
    end

    if #changes > 0 then
        local tree = self.originTree
        for _, change in ipairs(changes) do
            tree = ContainerLayout.withPairWeight(
                tree, change.indexPath, change.indexA, change.weightA, change.indexB, change.weightB)
        end
        container.props.layout = tree
    end

    if containerEdges ~= "" then
        container.x, container.y, container.width, container.height = RectResize.apply(
            "resize-" .. containerEdges, self.originRect, dx, dy, self.minWidth, self.minHeight)
    end
end

function CellResizeGesture:finish()
    local commands = {}
    local container = self.document:getById(self.containerId)

    if container then
        if self.changed then
            commands[#commands + 1] = SetProps.new(self.containerId,
                { layout = container.props.layout }, { layout = self.originTree })
        end

        local dx = container.x - self.originRect.x
        local dy = container.y - self.originRect.y
        local dWidth = container.width - self.originRect.width
        local dHeight = container.height - self.originRect.height
        if dx ~= 0 or dy ~= 0 or dWidth ~= 0 or dHeight ~= 0 then
            commands[#commands + 1] = ResizeElement.new(self.containerId, dx, dy, dWidth, dHeight)
        end

        -- The children's rects follow from the weights and the container's rect, so
        -- they're settled here rather than waiting for the next frame's pass -- a
        -- release is where a caller expects the board to be finished moving.
        Containment.layoutAll(self.document)
    end

    return Composite.of(commands), true
end

return CellResizeGesture
