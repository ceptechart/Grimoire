local Class = require "lib.util.Class"

-- Removes a set of elements from the document.
--
-- Takes an id list rather than a single id so a multi-selection delete is one undo
-- step. Stores each removed element and the index it held (`Document:remove` already
-- returns both), so revert reinserts every element exactly where it was rather than
-- pushing it to the front.
local RemoveElements = Class.extend()

function RemoveElements.new(ids)
    return setmetatable({ ids = ids, removed = nil }, RemoveElements)
end

function RemoveElements:apply(document)
    local removed = {}
    for _, id in ipairs(self.ids) do
        local element, index = document:remove(id)
        if element then
            table.insert(removed, { element = element, index = index })
        end
    end
    self.removed = removed
end

function RemoveElements:revert(document)
    -- Backwards, and that direction is load-bearing. Each index was recorded against
    -- the array as it stood at that moment, so the last removal is the only one whose
    -- index is still valid against the array as it is now; putting that element back
    -- restores the state the second-to-last removal was recorded against, and so on.
    --
    -- Replaying forwards instead lands elements at the wrong depth, and -- when the
    -- ids arrive in an order that removed a high index first -- writes past the end of
    -- a now-shorter array, leaving a hole in it.
    for index = #self.removed, 1, -1 do
        local entry = self.removed[index]
        document:insert(entry.element, entry.index)
    end
end

return RemoveElements
