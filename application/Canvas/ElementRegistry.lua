local Element = require "application.Canvas.Element"

-- Maps an element's `type` to the module that knows how to handle it.
--
-- A type definition is a plain table:
--
--   name           string, the value stored in element.type
--   defaultSize()  -> width, height
--   defaultProps() -> table, this type's per-element data
--   draw(element, context)         context carries { zoom }
--   hitTest(element, x, y)               optional, defaults to the element's rect
--   hitTestHandle(element, x, y, zoom)   optional, returns a handle name or nil
--   minSize()                            optional, -> minWidth, minHeight for resize
--   textFields(element)                  optional, -> the editable text on this
--                                        element (see textFields below)
--
-- A type that holds other elements implements a further optional group, dispatched
-- generically by application/Canvas/Containment.lua so nothing outside that module
-- (Board included) has to know a concrete container type exists:
--
--   childIds(element)                    -> the ids this element lays out
--   minSizeFor(element, document)        -> minimum size *for this instance*, which
--                                           for a container depends on its contents
--   layoutChildren(element, document)    writes each child's rect
--   dropTarget(element, x, y, document)  -> where a drop at this point would land,
--                                           plus the rect to preview it with
--   withChild(element, drop, childId)    -> a props update adding that child
--   withoutChild(element, childId)       -> a props update removing it, or nil
--   remapIds(element, idMap)             rewrites stored ids after a paste
--
-- Adding shapes, notes, images or containers later is a new file plus one
-- register() call -- nothing here or in Document needs to know about them.
--
-- One definition is special: the fallback (setFallback), used for element types this
-- build has never heard of. Board files outlive builds, so an unregistered type has
-- to be something the app can carry rather than something it dies on.
local ElementRegistry = {}

local DEFAULT_MIN_SIZE = 20

local definitions = {}
local fallback

function ElementRegistry:register(definition)
    assert(type(definition.name) == "string", "element type definition needs a name")
    assert(not definitions[definition.name], "element type already registered: " .. definition.name)
    definitions[definition.name] = definition
    return definition
end

-- The definition used for element types this build doesn't have -- a board written by
-- a newer version, or one whose type module didn't load. It isn't registered under a
-- name of its own; elements keep their real `type`, so they save back verbatim and
-- start working again the moment that type is registered.
function ElementRegistry:setFallback(definition)
    fallback = definition
    return definition
end

-- Strict lookup: errors on a type nobody registered. Used where an unknown type is a
-- programming mistake rather than data (creating an element, mainly).
function ElementRegistry:get(elementType)
    local definition = definitions[elementType]
    if not definition then
        error("unknown element type: " .. tostring(elementType), 2)
    end
    return definition
end

-- Lookup for elements that may have come out of a file: falls back to the placeholder
-- definition instead of erroring. Everything that draws or hit-tests an existing
-- element goes through this.
function ElementRegistry:resolve(elementType)
    local definition = definitions[elementType]
    if definition then
        return definition
    end
    if fallback then
        return fallback
    end
    error("unknown element type and no fallback registered: " .. tostring(elementType), 2)
end

function ElementRegistry:has(elementType)
    return definitions[elementType] ~= nil
end

-- Builds an element at the given world position using its type's defaults.
function ElementRegistry:create(elementType, x, y)
    local definition = self:get(elementType)
    local width, height = definition.defaultSize()
    return Element.new(elementType, x, y, width, height, definition.defaultProps())
end

function ElementRegistry:draw(element, context)
    self:resolve(element.type).draw(element, context)
end

function ElementRegistry:hitTest(element, x, y)
    local definition = self:resolve(element.type)
    if definition.hitTest then
        return definition.hitTest(element, x, y)
    end
    return element:containsPoint(x, y)
end

-- Returns a handle name ("move", "resize-se" and friends) or nil if the point isn't
-- on a handle. Used to decide what a drag starting here should do.
function ElementRegistry:hitTestHandle(element, x, y, zoom)
    local definition = self:resolve(element.type)
    if definition.hitTestHandle then
        return definition.hitTestHandle(element, x, y, zoom)
    end
    return nil
end

-- The element's editable text, in the order it should be tabbed/F2'd through. Each
-- field describes where its text is drawn, in world coordinates, so an inline editor
-- can put a caret exactly where the label was:
--
--   prop                        the key in element.props this field edits
--   x, y, width, height         the *text* rect, not the widget around it
--   font, color                 theme tokens, matching how the type draws it
--   hit                         optional { x, y, width, height }, a larger region
--                               that counts as "click here to edit this" (a panel's
--                               whole header, rather than just the title text)
--
-- Types that hold no text don't implement it, which is why this returns a shared
-- empty list rather than nil -- callers iterate without checking.
local NO_TEXT_FIELDS = {}

function ElementRegistry:textFields(element)
    local definition = self:resolve(element.type)
    if definition.textFields then
        return definition.textFields(element)
    end
    return NO_TEXT_FIELDS
end

function ElementRegistry:textFieldAt(element, x, y)
    for _, field in ipairs(self:textFields(element)) do
        local region = field.hit or field
        if x >= region.x and x <= region.x + region.width
            and y >= region.y and y <= region.y + region.height then
            return field
        end
    end
    return nil
end

-- Re-reads a field by name, which is how an open editor tracks a rect that moves:
-- the field tables are built on demand from the element's current geometry, so a
-- stored one goes stale the moment the element is dragged or resized.
function ElementRegistry:textField(element, prop)
    for _, field in ipairs(self:textFields(element)) do
        if field.prop == prop then
            return field
        end
    end
    return nil
end

-- Double-clicking a spot on an element that isn't one of its text fields -- an
-- image's body, say, rather than its title. `setProp(values)` lets the type record
-- an undoable change without knowing anything about Document or commands; Board
-- supplies it bound to this element's live id, the same indirection beginTextEdit's
-- onCommit uses so a callback that fires later (an async file dialog, here) can't
-- write into a document the element has since left.
--
-- Optional, so this is the one dispatch in the "containment" group's shape (see the
-- header) that lives down here instead: every other element type answers false/nil
-- for it implicitly, by not being asked in the first place -- Board only calls this
-- after a text field lookup has already come up empty.
function ElementRegistry:handleDoubleClick(element, x, y, setProp)
    local definition = self:resolve(element.type)
    if definition.handleDoubleClick then
        return definition.handleDoubleClick(element, x, y, setProp)
    end
    return false
end

function ElementRegistry:minSize(elementType)
    local definition = self:resolve(elementType)
    if definition.minSize then
        return definition.minSize()
    end
    return DEFAULT_MIN_SIZE, DEFAULT_MIN_SIZE
end

-- The minimum size of one particular element, rather than of its type.
--
-- Same answer as minSize for everything that doesn't hold other elements. A container
-- is the exception: its minimum is whatever its contents need, so it changes as they
-- come and go, and a caller with an element in hand should ask this instead.
function ElementRegistry:minSizeOf(element, document)
    local definition = self:resolve(element.type)
    if definition.minSizeFor then
        return definition.minSizeFor(element, document)
    end
    return self:minSize(element.type)
end

-- ── Containment ──────────────────────────────────────────────────────────
--
-- Thin dispatch for the optional hooks a type that holds other elements implements
-- (see the header). Everything here answers nil/false for a type that doesn't, so
-- Containment can ask any element without checking what it is first.

function ElementRegistry:childIds(element)
    local definition = self:resolve(element.type)
    return definition.childIds and definition.childIds(element) or nil
end

function ElementRegistry:isContainer(element)
    return self:resolve(element.type).dropTarget ~= nil
end

function ElementRegistry:layoutChildren(element, document)
    local definition = self:resolve(element.type)
    if definition.layoutChildren then
        definition.layoutChildren(element, document)
    end
end

-- The live geometry of an element's contents -- the split tree a container currently
-- resolves to, in world coordinates. What a cell resize drags the edges of.
function ElementRegistry:contentLayout(element, document)
    local definition = self:resolve(element.type)
    return definition.contentLayout and definition.contentLayout(element, document) or nil
end

function ElementRegistry:dropTarget(element, x, y, document)
    local definition = self:resolve(element.type)
    return definition.dropTarget and definition.dropTarget(element, x, y, document) or nil
end

function ElementRegistry:withChild(element, drop, childId)
    return self:resolve(element.type).withChild(element, drop, childId)
end

function ElementRegistry:withoutChild(element, childId)
    local definition = self:resolve(element.type)
    return definition.withoutChild and definition.withoutChild(element, childId) or nil
end

-- Puts an element's props into the shape its type expects, for an element that has
-- just come off disk. A board file is JSON anything could have written -- and
-- hand-editing one is deliberately supported -- so a type storing structure in props
-- (a container's split tree) repairs what it can here and drops what it can't,
-- rather than every reader of that structure defending against it.
--
-- Only registered types get this: an element the fallback stands in for keeps its
-- props byte-for-byte, which is the whole point of the fallback.
function ElementRegistry:normalize(element)
    local definition = definitions[element.type]
    if definition and definition.normalizeProps then
        definition.normalizeProps(element)
    end
end

-- Rewrites ids stored inside props after a paste, which mints new ones. Called with
-- a map of old id -> new id covering everything that came in with the paste; ids
-- outside it refer to elements that weren't copied and are dropped.
function ElementRegistry:remapIds(element, idMap)
    local definition = self:resolve(element.type)
    if definition.remapIds then
        definition.remapIds(element, idMap)
    end
end

-- ── Derived geometry and cross-element references ───────────────────────────
--
-- For a type whose geometry depends on another element rather than owning its own
-- (a line connecting two panels): a chance to recompute itself every frame, the same
-- point Containment.layoutAll runs at -- after that frame's input, before its draw.
-- Optional; everything else no-ops here implicitly, by not defining the hook.
function ElementRegistry:updateGeometry(element, document)
    local definition = self:resolve(element.type)
    if definition.updateGeometry then
        definition.updateGeometry(element, document)
    end
end

-- The ids of other elements this one's identity depends on -- what should be removed
-- along with it, the same way a container's children are gathered for a delete, but
-- in the opposite direction: a line depends on the panels it connects, not the other
-- way around. nil for anything that doesn't reference another element's id.
function ElementRegistry:dependsOn(element)
    local definition = self:resolve(element.type)
    return definition.dependsOn and definition.dependsOn(element) or nil
end

return ElementRegistry
