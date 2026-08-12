local Class = require "lib.util.Class"
local Theme = require "application.Style.Theme"
local Canvas = require "application.Canvas.Canvas"
local Gesture = require "application.Canvas.gestures.Gesture"
local ElementRegistry = require "application.Canvas.ElementRegistry"
local AddElement = require "application.Canvas.commands.AddElement"

-- Dragging out a new element of a given type, for any tool carrying a `createType`.
--
-- The element is built up front and reshaped live, exactly like a resize -- it *is*
-- the preview, and on release it's what gets added, so there's no second construction
-- step that could disagree with what the drag showed. It's drawn through its own type
-- definition rather than as an outline, faded until it's real, which costs a new
-- element type nothing.
--
-- The one gesture that leaves the document alone until release, hence the only one
-- whose command is executed rather than recorded as already-applied.
local CreateGesture = Class.extend(Gesture)

-- How solid the pending element looks. Enough to read its real colors and title, not
-- enough to mistake for something already on the board.
local PREVIEW_OPACITY = 0.5

-- Rect size, in screen pixels, below which a finished gesture counts as a click
-- rather than a drag. Screen rather than world so it stays a measure of pointer
-- jitter at any zoom.
local CLICK_THRESHOLD = 10

function CreateGesture.new(board, elementType, worldX, worldY)
    local gesture = Gesture.init(setmetatable({}, CreateGesture), board, worldX, worldY)

    gesture.element = ElementRegistry:create(elementType, worldX, worldY)
    gesture.minWidth, gesture.minHeight = ElementRegistry:minSize(elementType)

    -- What a click (as opposed to a drag) produces. Read off the fresh element rather
    -- than re-derived, so the two can't drift -- and read before the collapse below,
    -- which overwrites them.
    gesture.defaultWidth = gesture.element.width
    gesture.defaultHeight = gesture.element.height

    -- Collapse the preview onto the press point: until the pointer moves, the gesture
    -- has described no rect at all, and showing a default-sized element here would be
    -- the preview jumping to a shape the pointer never asked for.
    gesture:update()

    return gesture
end

-- The rect the gesture currently describes.
--
-- `clamped` is what separates the two callers, and it's the whole rule: **the preview
-- is the pointer's rect and nothing else**, sub-minimum sizes included, so it can
-- never move anywhere the pointer didn't -- while every size rule (the type's
-- minimum, and the click that makes a default-sized element) lands once at release,
-- when the element becomes real. Deciding either mid-drag is what made the preview
-- jump between a sliver and a full-sized panel.
function CreateGesture:getRect(clamped)
    local dx, dy = self:getDelta()
    local width, height = math.abs(dx), math.abs(dy)

    if clamped then
        -- Too small in both directions to have been a deliberate drag: treat it as a
        -- click on the spot and make the type's default-sized element there.
        if width * Canvas.zoom < CLICK_THRESHOLD and height * Canvas.zoom < CLICK_THRESHOLD then
            return self.startX, self.startY, self.defaultWidth, self.defaultHeight
        end

        width = math.max(width, self.minWidth)
        height = math.max(height, self.minHeight)
    end

    -- The press point stays on a corner whichever way the drag went, so a rect the
    -- clamp had to grow extends away from it rather than back past the pointer.
    return dx < 0 and self.startX - width or self.startX,
        dy < 0 and self.startY - height or self.startY,
        width, height
end

function CreateGesture:applyRect(clamped)
    local x, y, width, height = self:getRect(clamped)
    self.element:setPosition(x, y)
    self.element.width = width
    self.element.height = height
end

function CreateGesture:update()
    self:applyRect(false)
end

function CreateGesture:finish()
    -- Now that it's becoming a real element it has to obey its type's minimum size,
    -- which the preview was free to ignore.
    self:applyRect(true)

    -- Selected as it lands, so the thing just made is the thing being acted on -- and
    -- so switching back to the select tool has something under the pointer already.
    self.selection:set(self.element.id)

    return AddElement.new(self.element), false
end

-- In front of everything, which is where it's about to land. The fade goes through
-- Theme rather than through the element type, so every type gets it for free.
function CreateGesture:draw()
    Theme:pushOpacity(PREVIEW_OPACITY)
    ElementRegistry:draw(self.element, self.board:getDrawContext())
    Theme:popOpacity()
end

return CreateGesture
