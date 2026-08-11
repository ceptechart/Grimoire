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
--
-- Adding shapes, notes, images or containers later is a new file plus one
-- register() call -- nothing here or in Document needs to know about them.
local ElementRegistry = {}

local DEFAULT_MIN_SIZE = 20

local definitions = {}

function ElementRegistry:register(definition)
    assert(type(definition.name) == "string", "element type definition needs a name")
    assert(not definitions[definition.name], "element type already registered: " .. definition.name)
    definitions[definition.name] = definition
    return definition
end

function ElementRegistry:get(elementType)
    local definition = definitions[elementType]
    if not definition then
        error("unknown element type: " .. tostring(elementType), 2)
    end
    return definition
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
    self:get(element.type).draw(element, context)
end

function ElementRegistry:hitTest(element, x, y)
    local definition = self:get(element.type)
    if definition.hitTest then
        return definition.hitTest(element, x, y)
    end
    return element:containsPoint(x, y)
end

-- Returns a handle name ("move", "resize-se" and friends) or nil if the point isn't
-- on a handle. Used to decide what a drag starting here should do.
function ElementRegistry:hitTestHandle(element, x, y, zoom)
    local definition = self:get(element.type)
    if definition.hitTestHandle then
        return definition.hitTestHandle(element, x, y, zoom)
    end
    return nil
end

function ElementRegistry:minSize(elementType)
    local definition = self:get(elementType)
    if definition.minSize then
        return definition.minSize()
    end
    return DEFAULT_MIN_SIZE, DEFAULT_MIN_SIZE
end

return ElementRegistry
