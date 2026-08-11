local Class = require "lib.util.Class"
local History = require "application.Canvas.History"
local ElementRegistry = require "application.Canvas.ElementRegistry"

-- The board's contents: an ordered list of elements plus the undo history.
--
-- `elements` is stored back-to-front, so drawing walks it forwards and hit testing
-- walks it backwards. Array order *is* z-order; there's no separate z field to keep
-- in sync.
--
-- insert/remove are raw mutations. Commands call them; application code should go
-- through execute() so the change lands on the undo stack.
local Document = Class.extend()

function Document.new()
    return setmetatable({
        elements = {},
        byId = {},
        history = History.new(),
    }, Document)
end

function Document:insert(element, index)
    index = index or #self.elements + 1
    table.insert(self.elements, index, element)
    self.byId[element.id] = element
    return element
end

-- Returns the removed element and the index it held, which is what a command needs
-- to put it back exactly where it was.
function Document:remove(id)
    local element = self.byId[id]
    if not element then
        return nil
    end

    for index, candidate in ipairs(self.elements) do
        if candidate.id == id then
            table.remove(self.elements, index)
            self.byId[id] = nil
            return element, index
        end
    end
end

function Document:getById(id)
    return self.byId[id]
end

function Document:indexOf(id)
    for index, element in ipairs(self.elements) do
        if element.id == id then
            return index
        end
    end
end

-- Pulls an element out and appends it, putting it in front of everything else.
-- Returns the index it came from, or nil if it was already frontmost.
function Document:raiseToFront(id)
    local index = self:indexOf(id)
    if not index or index == #self.elements then
        return nil
    end

    local element = self:remove(id)
    self:insert(element)
    return index
end

-- Raises a whole group to the front as a block, preserving their order relative to
-- each other. Returns a list of { id, fromIndex, toIndex } for elements that
-- actually moved, in the form ReorderElement expects -- so a group drag can undo its
-- raise the same way a single-element drag does.
function Document:raiseAllToFront(ids)
    local idSet = {}
    for _, id in ipairs(ids) do
        idSet[id] = true
    end

    -- Processed in current z-order (not `ids` order) and raised one at a time, so
    -- the group keeps its internal order once every member sits above everything
    -- that wasn't part of it.
    local ordered = {}
    for _, element in ipairs(self.elements) do
        if idSet[element.id] then
            table.insert(ordered, element.id)
        end
    end

    local raised = {}
    for _, id in ipairs(ordered) do
        local fromIndex = self:raiseToFront(id)
        if fromIndex then
            table.insert(raised, { id = id, fromIndex = fromIndex, toIndex = self:indexOf(id) })
        end
    end
    return raised
end

function Document:count()
    return #self.elements
end

-- Front-to-back, so the topmost element under the point wins.
function Document:elementAt(x, y)
    for index = #self.elements, 1, -1 do
        local element = self.elements[index]
        if ElementRegistry:hitTest(element, x, y) then
            return element
        end
    end
end

-- Like elementAt, but also reports which handle (if any) the point landed on.
-- Search stops at the first element hit whether or not it had a handle there:
-- an element occludes whatever is behind it. zoom is needed because resize grab
-- zones are a constant size on screen, not in world space.
function Document:handleAt(x, y, zoom)
    for index = #self.elements, 1, -1 do
        local element = self.elements[index]
        local handle = ElementRegistry:hitTestHandle(element, x, y, zoom)
        if handle then
            return element, handle
        end
        if ElementRegistry:hitTest(element, x, y) then
            return element, nil
        end
    end
end

function Document:execute(command)
    return self.history:execute(command, self)
end

function Document:pushApplied(command)
    return self.history:pushApplied(command)
end

function Document:undo()
    return self.history:undo(self)
end

function Document:redo()
    return self.history:redo(self)
end

return Document
