local Class = require "lib.util.Class"
local Gesture = require "application.Canvas.gestures.Gesture"
local ContentScroll = require "application.Canvas.ContentScroll"

-- Dragging an element's scrollbar thumb.
--
-- The second gesture that produces no command, for the same reason MarqueeGesture
-- doesn't: how far something is scrolled is view state, not board content, so
-- nothing it does belongs on the undo stack. It's a gesture at all -- rather than a
-- flag on Board -- because it is one: a press starts it, moves advance it, the
-- release ends it, and Board already has exactly one place to keep that.
--
-- It holds the element's *id* rather than the element, matching every command in
-- the codebase: a drag can outlive the table it started on (an undo mid-drag can
-- remove and reinsert the element), and an id survives that where a reference
-- doesn't.
local ScrollGesture = Class.extend(Gesture)

-- `grab` is how far down the thumb the press landed, preserved for the whole drag
-- so the thumb tracks the pointer instead of jumping to centre on it.
function ScrollGesture.new(board, element, worldX, worldY, grab)
    local gesture = Gesture.init(setmetatable({}, ScrollGesture), board, worldX, worldY)

    gesture.elementId = element.id
    gesture.grab = grab
    ContentScroll.setDragging(element.id)

    return gesture
end

function ScrollGesture:update()
    local element = self.document:getById(self.elementId)
    if element then
        ContentScroll.dragTo(element, self.currentY, self.grab)
    end
end

function ScrollGesture:finish()
    ContentScroll.setDragging(nil)
    return nil, false
end

return ScrollGesture
