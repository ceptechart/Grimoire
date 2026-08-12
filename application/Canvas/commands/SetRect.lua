local Class = require "lib.util.Class"

-- Sets an element's whole rect, recording what it was.
--
-- The one geometry command that stores absolute rects rather than a delta, and the
-- reason is containment: an element that joins a container stops owning its own
-- geometry, and the rect it ends up with is whatever the layout gives it. There's no
-- delta anyone can compute after the fact -- undo has to put back the rect the
-- element had before the drag, not subtract the distance the pointer travelled from
-- wherever the layout has since put it.
--
-- Same shape as SetProps, which stores old and new values for the same reason: both
-- are captured up front, so apply and revert stay exact inverses however far the user
-- walks the stack.
local SetRect = Class.extend()

local function copy(rect)
    return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

function SetRect.new(id, oldRect, newRect)
    return setmetatable({
        id = id,
        oldRect = copy(oldRect),
        newRect = copy(newRect),
    }, SetRect)
end

-- Whether the two rects differ at all, so a caller can skip recording a drag that
-- changed nothing.
function SetRect.differs(a, b)
    return a.x ~= b.x or a.y ~= b.y or a.width ~= b.width or a.height ~= b.height
end

local function assign(document, id, rect)
    local element = document:getById(id)
    -- Skip silently: the element may have been removed by a later command the user
    -- has since undone past. Same rule as MoveElements.
    if not element then
        return
    end

    element.x, element.y = rect.x, rect.y
    element.width, element.height = rect.width, rect.height
end

function SetRect:apply(document)
    assign(document, self.id, self.newRect)
end

function SetRect:revert(document)
    assign(document, self.id, self.oldRect)
end

return SetRect
