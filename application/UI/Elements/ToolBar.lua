local Class = require "lib.util.Class"
local MathUtil = require "lib.util.math.MathUtil"
local Container = require "application.UI.Elements.Container"

-- A vertical column of buttons down one edge of the screen, with a toggle button
-- pinned above it that collapses the column away.
--
-- Collapsing slides the column sideways off the screen edge rather than folding it
-- up: the screen edge does the clipping, so there's no scissor to manage, and the
-- toggle stays exactly where it was so it can be found again. `layout` positions
-- items from the same animated offset that `draw` uses, so a half-open column
-- hit-tests against what's actually on screen.
--
-- The bar is generic over what the buttons do -- what tool they select, and which
-- one is currently active, belongs to whoever builds it (see UI.lua).
local ToolBar = Class.extend(Container)

local SLIDE_DURATION = 0.18
-- Clear of the screen edge at rest, so a rounded corner or a shadow can't peek back
-- in while the column is collapsed.
local HIDDEN_MARGIN = 8
-- Below this the animation is over; without it `approach` only ever asymptotes and
-- the bar would relayout forever.
local SETTLED = 0.001

function ToolBar.new()
    local bar = Container.init(setmetatable({}, ToolBar))

    -- Two groups so the toggle can be laid out separately (it doesn't slide) while
    -- Container still forwards input to both.
    bar.toggleItems = bar:addItemGroup({})
    bar.items = bar:addItemGroup({})

    bar.expanded = true
    bar.reveal = 1

    return bar
end

-- The button that opens and closes the column. Its onPress is left to the caller --
-- the icon it shows depends on which way the column is currently sitting, which is
-- also the caller's business.
function ToolBar:withToggle(button)
    self.toggleItems[1] = button
    return self
end

function ToolBar:getToggle()
    return self.toggleItems[1]
end

function ToolBar:addItem(item)
    table.insert(self.items, item)
    return self
end

function ToolBar:isExpanded()
    return self.expanded
end

function ToolBar:setExpanded(expanded)
    self.expanded = expanded and true or false
    return self
end

function ToolBar:toggle()
    return self:setExpanded(not self.expanded)
end

function ToolBar:getDefaultWidth()
    return math.max(
        Container.maxWidth(self.items),
        self:getToggle() and self:getToggle():getWidth() or 0)
end

function ToolBar:getHeight()
    local height = Container.sumHeight(self.items, self.itemSpacing)
    local toggle = self:getToggle()
    if toggle then
        height = height + toggle:getHeight() + self.itemSpacing
    end
    return height
end

-- Where the column sits this frame: its resting x when fully revealed, off the left
-- of the screen when fully collapsed.
function ToolBar:getItemX()
    local hiddenX = -Container.maxWidth(self.items) - HIDDEN_MARGIN
    return hiddenX + (self.position.x - hiddenX) * self.reveal
end

function ToolBar:layout()
    local y = self.position.y

    local toggle = self:getToggle()
    if toggle then
        toggle:withPosition(self.position.x, y)
        y = y + toggle:getHeight() + self.itemSpacing
    end

    local x = self:getItemX()
    for _, item in ipairs(self.items) do
        item:withPosition(x, y)
        y = y + item:getHeight() + self.itemSpacing
    end
end

function ToolBar:update(dt)
    local target = self.expanded and 1 or 0
    if self.reveal == target then
        return
    end

    self.reveal = MathUtil.approach(self.reveal, target, dt, SLIDE_DURATION)
    if math.abs(target - self.reveal) < SETTLED then
        self.reveal = target
    end
end

-- The buttons are separate circles with gaps between them, not one opaque strip, so
-- "over the toolbar" means over a button -- a click in the gap belongs to the canvas
-- underneath. This is also what makes the collapsed bar transparent to input without
-- a special case: its items are off screen, so nothing contains the pointer.
function ToolBar:containsPoint(x, y)
    for _, items in ipairs(self.itemGroups) do
        for _, item in ipairs(items) do
            if item:containsPoint(x, y) then
                return true
            end
        end
    end
    return false
end

function ToolBar:draw()
    self:layout()

    if self.reveal > 0 then
        for _, item in ipairs(self.items) do
            item:draw()
        end
    end

    local toggle = self:getToggle()
    if toggle then
        toggle:draw()
    end
end

return ToolBar
