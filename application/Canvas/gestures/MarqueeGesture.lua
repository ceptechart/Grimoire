local Class = require "lib.util.Class"
local Theme = require "application.Style.Theme"
local Canvas = require "application.Canvas.Canvas"
local Gesture = require "application.Canvas.gestures.Gesture"

-- Dragging a rectangle across empty canvas to select what it touches.
--
-- The only gesture that produces no command: selection is view state, not board
-- content, so nothing it does belongs on the undo stack.
local MarqueeGesture = Class.extend(Gesture)

-- Shift-drag adds to the selection instead of replacing it, so the starting set is
-- kept and the rect's contents are unioned onto it on every move -- recomputed from
-- scratch each time rather than accumulated, so shrinking the rect back off an
-- element deselects it again.
function MarqueeGesture.new(board, worldX, worldY, additive)
    local gesture = Gesture.init(setmetatable({}, MarqueeGesture), board, worldX, worldY)

    gesture.base = additive and gesture.document:selectedIds(gesture.selection) or {}
    if not additive then
        gesture.selection:clear()
    end

    return gesture
end

-- The rect the drag currently describes, normalized so it's valid dragged in any
-- direction.
function MarqueeGesture:getRect()
    local minX = math.min(self.startX, self.currentX)
    local minY = math.min(self.startY, self.currentY)
    local maxX = math.max(self.startX, self.currentX)
    local maxY = math.max(self.startY, self.currentY)
    return minX, minY, maxX, maxY
end

function MarqueeGesture:update()
    local minX, minY, maxX, maxY = self:getRect()

    self.selection:clear()
    for _, id in ipairs(self.base) do
        self.selection:add(id)
    end

    -- Any overlap counts, rather than full containment. Most editors switch between
    -- the two depending on drag direction; this is the simpler half of that.
    for _, element in ipairs(self.document.elements) do
        local overlaps = element.x <= maxX and element.x + element.width >= minX
            and element.y <= maxY and element.y + element.height >= minY
        if overlaps then
            self.selection:add(element.id)
        end
    end
end

function MarqueeGesture:draw()
    local minX, minY, maxX, maxY = self:getRect()
    local width, height = maxX - minX, maxY - minY

    local r, g, b, a = love.graphics.getColor()
    local previousLineWidth = love.graphics.getLineWidth()

    love.graphics.setColor(Theme:color("marqueeFill"):unpacked())
    love.graphics.rectangle("fill", minX, minY, width, height)

    love.graphics.setColor(Theme:color("marqueeBorder"):unpacked())
    -- One screen pixel whatever the zoom, like every other hairline drawn in world
    -- space.
    love.graphics.setLineWidth(1 / Canvas.zoom)
    love.graphics.rectangle("line", minX, minY, width, height)

    love.graphics.setLineWidth(previousLineWidth)
    love.graphics.setColor(r, g, b, a)
end

return MarqueeGesture
