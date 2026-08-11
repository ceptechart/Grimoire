local Class = require "lib.util.Class"
local Id = require "lib.util.Id"

-- One thing on the board.
--
-- Elements are deliberately plain, serializable data: id, type, a world-space rect,
-- and a `props` table holding whatever that type needs. All behaviour -- how to draw
-- it, what counts as a hit, where its handles are -- lives in the type definition
-- registered with ElementRegistry, keyed by `type`.
--
-- That split is what makes the model the save format: writing an element out is
-- writing these fields, with no behaviour to reconstruct beyond re-attaching the
-- metatable.
local Element = Class.extend()

function Element.new(elementType, x, y, width, height, props)
    return setmetatable({
        id = Id.new(),
        type = elementType,
        x = x or 0,
        y = y or 0,
        width = width or 0,
        height = height or 0,
        props = props or {},
    }, Element)
end

-- ── Persistence ──────────────────────────────────────────────────────────

-- The save format for one element: exactly the fields above, nothing derived.
--
-- `props` goes over by reference rather than being copied -- the caller is about to
-- encode it, not hold onto it.
function Element:toData()
    return {
        id = self.id,
        type = self.type,
        x = self.x,
        y = self.y,
        width = self.width,
        height = self.height,
        props = self.props,
    }
end

local GEOMETRY_FIELDS = { "x", "y", "width", "height" }

-- Rebuilds an element from decoded file data, validating as it goes: this is where
-- untrusted data becomes a live object, so a bad field has to come back as a message
-- rather than as a half-built element that crashes three frames later.
--
-- An unrecognised `type` is deliberately *not* an error -- see ElementRegistry's
-- fallback. Missing geometry defaults to 0 so a hand-edited file that leaves a field
-- out still opens.
function Element.fromData(data)
    if type(data) ~= "table" then
        return nil, "expected an object"
    end
    if type(data.id) ~= "string" or data.id == "" then
        return nil, "missing 'id'"
    end
    if type(data.type) ~= "string" or data.type == "" then
        return nil, "missing 'type'"
    end
    if data.props ~= nil and type(data.props) ~= "table" then
        return nil, "'props' must be an object"
    end

    local geometry = {}
    for _, field in ipairs(GEOMETRY_FIELDS) do
        local value = data[field]
        if value == nil then
            value = 0
        elseif type(value) ~= "number" then
            return nil, ("'%s' must be a number, got %s"):format(field, type(value))
        end
        geometry[field] = value
    end

    local element = Element.new(data.type,
        geometry.x, geometry.y, geometry.width, geometry.height, data.props)
    element.id = data.id
    return element
end

-- ── Geometry ─────────────────────────────────────────────────────────────

-- Deliberately allocation-free: this runs for every element on every hit test.
function Element:containsPoint(x, y)
    return x >= self.x and x <= self.x + self.width
       and y >= self.y and y <= self.y + self.height
end

function Element:move(dx, dy)
    self.x = self.x + dx
    self.y = self.y + dy
end

function Element:setPosition(x, y)
    self.x = x
    self.y = y
end

return Element
