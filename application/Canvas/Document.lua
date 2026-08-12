local Class = require "lib.util.Class"
local Serialize = require "lib.util.Serialize"
local History = require "application.Canvas.History"
local Element = require "application.Canvas.Element"
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

-- Bumped when the shape of a saved board changes in a way an older build can't read.
-- Written into every file from day one so there's always something to branch on.
Document.SCHEMA_VERSION = 1

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

-- The ids in `selection`, back-to-front in document order.
--
-- Selection is a hash set, so iterating it directly yields ids in whatever order Lua
-- hashed them -- which differs between runs and is invisible until something
-- order-sensitive depends on it. Anything that inserts, removes or reorders several
-- elements as one step (delete, raise, and later copy/paste and align) has to have a
-- defined order, so it comes from here, where order actually means something.
--
-- Ids for elements no longer in the document are dropped, which is what makes this
-- safe to call against a selection that outlived an undo.
function Document:selectedIds(selection)
    local ids = {}
    for _, element in ipairs(self.elements) do
        if selection:contains(element.id) then
            ids[#ids + 1] = element.id
        end
    end
    return ids
end

-- Every id on the board, in the same order. For Select All.
function Document:allIds()
    local ids = {}
    for index, element in ipairs(self.elements) do
        ids[index] = element.id
    end
    return ids
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

-- ── Persistence ──────────────────────────────────────────────────────────

-- The element list and a schema version, and nothing else. Selection and History are
-- view state, so they aren't in the file (see CLAUDE.md) -- an opened board starts
-- with nothing selected and an empty undo stack.
function Document:toData()
    -- Marked as an array so an empty board still writes "elements": [].
    local elements = Serialize.array({})
    for index, element in ipairs(self.elements) do
        elements[index] = element:toData()
    end

    return {
        version = Document.SCHEMA_VERSION,
        elements = elements,
    }
end

-- Rebuilds a Document from decoded file data.
--
-- Returns the document and a (possibly empty) list of warning strings, or nil and a
-- message if the data can't be read at all. The split matters: a board referencing an
-- element type this build doesn't have is a warning -- the elements come through
-- untouched and save back verbatim -- while a duplicate id or a non-numeric
-- coordinate is a refusal, because guessing would silently lose content.
function Document.fromData(data)
    if type(data) ~= "table" then
        return nil, "file does not contain a board object"
    end
    if type(data.version) ~= "number" then
        return nil, "file is missing a schema version"
    end
    if data.version > Document.SCHEMA_VERSION then
        return nil, ("file uses schema version %s; this build reads up to %d")
            :format(tostring(data.version), Document.SCHEMA_VERSION)
    end
    if data.elements ~= nil and type(data.elements) ~= "table" then
        return nil, "'elements' is not a list"
    end

    local document = Document.new()
    local warnings = {}
    local reportedTypes = {}

    for index, raw in ipairs(data.elements or {}) do
        local element, err = Element.fromData(raw)
        if not element then
            return nil, ("element %d: %s"):format(index, err)
        end
        if document.byId[element.id] then
            return nil, ("element %d: id %s appears twice"):format(index, element.id)
        end

        if not ElementRegistry:has(element.type) and not reportedTypes[element.type] then
            reportedTypes[element.type] = true
            table.insert(warnings, ("Unknown element type '%s' -- kept as-is"):format(element.type))
        end

        document:insert(element)
    end

    return document, warnings
end

-- An opaque marker for "which sequence of edits this document currently reflects",
-- used for dirty tracking. See History:getStateToken.
function Document:getStateToken()
    return self.history:getStateToken()
end

-- ── Editing ──────────────────────────────────────────────────────────────

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
