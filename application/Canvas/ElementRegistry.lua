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

function ElementRegistry:minSize(elementType)
    local definition = self:resolve(elementType)
    if definition.minSize then
        return definition.minSize()
    end
    return DEFAULT_MIN_SIZE, DEFAULT_MIN_SIZE
end

return ElementRegistry
