local Class = require "lib.util.Class"

local BoundingBox = Class.extend()

function BoundingBox.new(x, y, width, height)
    return setmetatable({
        x = x or 0,
        y = y or 0,
        width = width or 0,
        height = height or 0,
    }, BoundingBox)
end

-- Mutating setter, so callers that recompute a box every frame (widget hit tests)
-- can reuse one instance instead of allocating.
function BoundingBox:set(x, y, width, height)
    self.x = x or 0
    self.y = y or 0
    self.width = width or 0
    self.height = height or 0
    return self
end

function BoundingBox:containsXY(x, y)
    return x >= self.x and x <= self.x + self.width
       and y >= self.y and y <= self.y + self.height
end

function BoundingBox:containsPoint(point)
    return self:containsXY(point.x, point.y)
end

return BoundingBox
