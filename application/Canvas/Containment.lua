local ElementRegistry = require "application.Canvas.ElementRegistry"
local SetProps = require "application.Canvas.commands.SetProps"
local ResizeElement = require "application.Canvas.commands.ResizeElement"

-- Which elements hold which other elements, and everything that follows from it:
-- laying children out, finding what a drag would drop into, and attaching or
-- detaching one.
--
-- This is the seam that keeps `Board` free of concrete types. Board asks whether the
-- element under the pointer has a parent, not whether it's in a container; the
-- answer comes from the type definition's optional containment hooks (see
-- ElementRegistry's header), so a second type that holds children -- a frame, a
-- group -- needs nothing here or in Board.
--
-- Containment is *derived from the parent*, not stored on the child: an element
-- names the ids it lays out, and nothing points the other way. One authority means
-- there's no pair of fields that can disagree, and it's what lets a container be
-- copied, deleted and undone as a plain element. The cost is that finding a child's
-- parent is a scan, which is fine at the size a board reaches and only happens on a
-- press or a frame's layout pass.
--
-- attach() and detach() apply their change to the document immediately *and* return
-- the commands describing it, which is the same bargain the drag gestures make:
-- the edit has to be visible while the pointer is still down, so what comes back is
-- recorded with pushApplied rather than executed (see gestures/Gesture.lua).
local Containment = {}

-- ── Reading the tree ─────────────────────────────────────────────────────

-- The element that lays `id` out, or nil if nothing does.
function Containment.parentOf(document, id)
    for _, element in ipairs(document.elements) do
        local children = ElementRegistry:childIds(element)
        if children then
            for _, childId in ipairs(children) do
                if childId == id then
                    return element
                end
            end
        end
    end
    return nil
end

-- Every id below `id`, at any depth. `seen` guards against a cycle, which the UI
-- can't build but a hand-edited file can.
function Containment.descendants(document, id, out, seen)
    out = out or {}
    seen = seen or {}
    if seen[id] then
        return out
    end
    seen[id] = true

    local element = document:getById(id)
    local children = element and ElementRegistry:childIds(element)
    for _, childId in ipairs(children or {}) do
        out[#out + 1] = childId
        Containment.descendants(document, childId, out, seen)
    end
    return out
end

-- `ids` plus everything inside them. Used for raising a group: a container has to
-- take its children up with it, or it would come to rest in front of them.
function Containment.withDescendants(document, ids)
    local out = {}
    local seen = {}
    for _, id in ipairs(ids) do
        if not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
        for _, childId in ipairs(Containment.descendants(document, id)) do
            if not seen[childId] then
                seen[childId] = true
                out[#out + 1] = childId
            end
        end
    end
    return out
end

-- `ids` minus anything an element also in `ids` lays out.
--
-- A move applies to these: a child whose container is being dragged is already
-- carried along by the layout, and moving it here as well would double every step
-- the pointer took.
function Containment.withoutContainedBy(document, ids)
    local dragged = {}
    for _, id in ipairs(ids) do
        dragged[id] = true
    end

    local out = {}
    for _, id in ipairs(ids) do
        local contained = false
        local seen = {}
        local parent = Containment.parentOf(document, id)
        while parent and not seen[parent.id] do
            seen[parent.id] = true
            if dragged[parent.id] then
                contained = true
                break
            end
            parent = Containment.parentOf(document, parent.id)
        end
        if not contained then
            out[#out + 1] = id
        end
    end
    return out
end

-- ── Layout ───────────────────────────────────────────────────────────────

local function layoutTree(document, element, visited)
    if visited[element.id] then
        return
    end
    visited[element.id] = true

    ElementRegistry:layoutChildren(element, document)

    for _, childId in ipairs(ElementRegistry:childIds(element) or {}) do
        local child = document:getById(childId)
        if child then
            layoutTree(document, child, visited)
        end
    end
end

-- Writes every laid-out element's rect from the element that owns it.
--
-- Run once a frame from Board:update, which is after that frame's input and before
-- its draw -- so a container dragged this frame takes its contents with it, and an
-- undo that moved one is followed on screen without anything having to notice.
-- Cheap and unconditional for the same reason Board:pruneSelection is: there's no
-- signal that reliably says "something that affects a layout changed", and the pass
-- is bounded by the number of elements on the board.
--
-- Outermost first, so a nested container is positioned by its parent before it
-- positions its own children. `visited` makes that safe against a file whose
-- containers form a cycle -- those elements simply never get laid out.
function Containment.layoutAll(document)
    local claimed = {}
    for _, element in ipairs(document.elements) do
        for _, childId in ipairs(ElementRegistry:childIds(element) or {}) do
            claimed[childId] = true
        end
    end

    local visited = {}
    for _, element in ipairs(document.elements) do
        if not claimed[element.id] then
            layoutTree(document, element, visited)
        end
    end
end

-- ── Attaching and detaching ──────────────────────────────────────────────

-- Takes an element out of whatever lays it out, so it can follow the pointer instead
-- of being snapped back by the next layout pass. Returns the command recording that,
-- or nil if it had no parent to leave.
--
-- The container is deliberately left at the size it grew to. Shrinking it back would
-- be a second guess at what the user wants, and it's one drag on the container's own
-- edge to undo either way.
function Containment.detach(document, id)
    local parent = Containment.parentOf(document, id)
    if not parent then
        return nil
    end

    local update = ElementRegistry:withoutChild(parent, id)
    if not update then
        return nil
    end

    -- capture reads the old values before apply writes the new ones over them.
    local command = SetProps.capture(parent, update)
    command:apply(document)
    return command
end

-- Puts an element into `container` at `drop` (see ContainerElement.dropTarget).
--
-- Returns the commands for it: the arrangement itself, plus a resize when the new
-- child doesn't fit -- a container grows to hold what's dropped into it rather than
-- squeezing its contents below the size they say they need. It only ever grows;
-- shrinking on removal would make a container flinch every time something was
-- dragged out of it.
function Containment.attach(document, container, drop, id)
    local commands = {}

    local command = SetProps.capture(container, ElementRegistry:withChild(container, drop, id))
    command:apply(document)
    commands[#commands + 1] = command

    local minWidth, minHeight = ElementRegistry:minSizeOf(container, document)
    local dWidth = math.max(0, minWidth - container.width)
    local dHeight = math.max(0, minHeight - container.height)
    if dWidth > 0 or dHeight > 0 then
        local grow = ResizeElement.new(container.id, 0, 0, dWidth, dHeight)
        grow:apply(document)
        commands[#commands + 1] = grow
    end

    return commands
end

-- What a drop at (x, y) would land in, and where: the container plus its drop
-- descriptor, or nil.
--
-- Front-to-back, so the topmost thing under the pointer decides -- and a child
-- resolves to the container that lays it out, since dragging over the elements
-- already in a container is how you say where in it the new one goes. Anything else
-- occludes: a free element covering a container means the pointer is over that
-- element, not over the container behind it.
--
-- The dragged element and everything inside it are skipped rather than treated as
-- occluders. A container being dragged is under the pointer the whole time by
-- definition, and it can't be dropped into itself.
function Containment.dropTargetAt(document, x, y, dragged)
    local blocked = { [dragged.id] = true }
    for _, id in ipairs(Containment.descendants(document, dragged.id)) do
        blocked[id] = true
    end

    for index = #document.elements, 1, -1 do
        local element = document.elements[index]
        if not blocked[element.id] and element:containsPoint(x, y) then
            local target = element
            if not ElementRegistry:isContainer(target) then
                target = Containment.parentOf(document, element.id)
            end

            if target and not blocked[target.id] and ElementRegistry:isContainer(target) then
                local drop = ElementRegistry:dropTarget(target, x, y, document)
                if drop then
                    return target, drop
                end
            end
            return nil
        end
    end
    return nil
end

return Containment
