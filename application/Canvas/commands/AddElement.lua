local Class = require "lib.util.Class"

-- Adds an element to the document.
--
-- Holds the element itself rather than a description of it, so undo/redo returns the
-- same object with the same id -- which is what keeps other commands referring to it
-- (a MoveElements recorded afterwards) valid across the round trip.
local AddElement = Class.extend()

function AddElement.new(element, index)
    return setmetatable({ element = element, index = index }, AddElement)
end

function AddElement:apply(document)
    document:insert(self.element, self.index)
end

function AddElement:revert(document)
    -- Remember where it sat, so a redo restores z-order rather than pushing to front.
    local _, index = document:remove(self.element.id)
    self.index = index
end

return AddElement
