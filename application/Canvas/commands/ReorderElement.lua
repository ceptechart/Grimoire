local Class = require "lib.util.Class"

-- Moves an element to a different position in the document's z-order.
--
-- Both indices are positions in the array *after* the element has been pulled out of
-- it, since that's the only way they stay meaningful in both directions: removing an
-- element shifts everything above it down by one, so an index recorded against the
-- full array would be off by one when reverting a raise.
local ReorderElement = Class.extend()

function ReorderElement.new(id, fromIndex, toIndex)
    return setmetatable({ id = id, fromIndex = fromIndex, toIndex = toIndex }, ReorderElement)
end

function ReorderElement:moveTo(document, index)
    local element = document:remove(self.id)
    if element then
        document:insert(element, index)
    end
end

function ReorderElement:apply(document)
    self:moveTo(document, self.toIndex)
end

function ReorderElement:revert(document)
    self:moveTo(document, self.fromIndex)
end

return ReorderElement
