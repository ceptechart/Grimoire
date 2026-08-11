local Class = require "lib.util.Class"

-- Moves a set of elements by a world-space delta.
--
-- Stores ids rather than element references so it stays valid across an
-- undo/redo cycle that removed and re-inserted the element, and stores a delta
-- rather than before/after positions so it composes with whatever else moved them
-- in between.
local MoveElements = Class.extend()

function MoveElements.new(ids, dx, dy)
    return setmetatable({ ids = ids, dx = dx, dy = dy }, MoveElements)
end

function MoveElements:shift(document, dx, dy)
    for _, id in ipairs(self.ids) do
        local element = document:getById(id)
        -- Skip silently: the element may have been deleted by a later command that
        -- has since been undone past.
        if element then
            element:move(dx, dy)
        end
    end
end

function MoveElements:apply(document)
    self:shift(document, self.dx, self.dy)
end

function MoveElements:revert(document)
    self:shift(document, -self.dx, -self.dy)
end

return MoveElements
