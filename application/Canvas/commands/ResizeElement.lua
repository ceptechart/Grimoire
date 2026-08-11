local Class = require "lib.util.Class"

-- Resizes (and, for a west/north handle, repositions) a single element by a delta.
--
-- Scoped to one element: a future group-resize would need to scale each element's
-- rect proportionally within the group's bounding box, which is a different and
-- more complex operation than this delta-shift.
local ResizeElement = Class.extend()

function ResizeElement.new(id, dx, dy, dWidth, dHeight)
    return setmetatable({ id = id, dx = dx, dy = dy, dWidth = dWidth, dHeight = dHeight }, ResizeElement)
end

function ResizeElement:shift(document, sign)
    local element = document:getById(self.id)
    if element then
        element.x = element.x + self.dx * sign
        element.y = element.y + self.dy * sign
        element.width = element.width + self.dWidth * sign
        element.height = element.height + self.dHeight * sign
    end
end

function ResizeElement:apply(document)
    self:shift(document, 1)
end

function ResizeElement:revert(document)
    self:shift(document, -1)
end

return ResizeElement
