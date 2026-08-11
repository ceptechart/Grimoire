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

-- Re-attaches behaviour to a plain table read back from a save file.
function Element.restore(data)
    data.props = data.props or {}
    return setmetatable(data, Element)
end

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
