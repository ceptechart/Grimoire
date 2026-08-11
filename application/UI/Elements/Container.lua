local Class = require "lib.util.Class"
local Widget = require "application.UI.Elements.Widget"

-- Base for widgets that lay out and route input to lists of children.
--
-- Children live in one or more groups (a menu bar has left/center/right, a vertical
-- menu has a single list). Subclasses register their groups at construction and
-- Container handles drawing and input routing across all of them.
local Container = Class.extend(Widget)

function Container.init(container)
    Widget.init(container)
    container.itemSpacing = 0
    container.itemGroups = {}
    return container
end

-- Returns the list it was given so subclasses can hold onto it:
--   bar.leftItems = bar:addItemGroup({})
function Container:addItemGroup(items)
    table.insert(self.itemGroups, items)
    return items
end

function Container:withItemSpacing(spacing)
    self.itemSpacing = spacing
    return self
end

-- Measurement helpers, shared by containers that stack along either axis.
function Container.sumWidth(items, spacing)
    local width = 0
    for i, item in ipairs(items) do
        width = width + item:getWidth()
        if i > 1 then
            width = width + spacing
        end
    end
    return width
end

function Container.sumHeight(items, spacing)
    local height = 0
    for i, item in ipairs(items) do
        height = height + item:getHeight()
        if i > 1 then
            height = height + spacing
        end
    end
    return height
end

function Container.maxWidth(items)
    local width = 0
    for _, item in ipairs(items) do
        width = math.max(width, item:getWidth())
    end
    return width
end

function Container.maxHeight(items)
    local height = 0
    for _, item in ipairs(items) do
        height = math.max(height, item:getHeight())
    end
    return height
end

-- Positions children. Subclasses override; called before drawing and before hit
-- testing so children are never tested against stale positions.
function Container:layout()
end

-- Items that don't implement the callback are skipped, so Labels can sit in a
-- container without pretending to handle input.
function Container:forwardToItems(event, ...)
    local consumed = false

    for _, items in ipairs(self.itemGroups) do
        for _, item in ipairs(items) do
            local callback = item[event]
            if callback and callback(item, ...) then
                consumed = true
            end
        end
    end

    return consumed
end

function Container:drawItems()
    for _, items in ipairs(self.itemGroups) do
        for _, item in ipairs(items) do
            item:draw()
        end
    end
end

function Container:draw()
    self:layout()

    if self.panel then
        self.panel:draw(self.position.x, self.position.y, self:getWidth(), self:getHeight())
    end

    self:drawItems()
end

-- A container is an opaque surface: pointer input landing anywhere on it is
-- consumed, whether or not a child wanted it. Otherwise a middle-click or a scroll
-- over the menu bar would also reach the canvas underneath.
function Container:mousemoved(x, y, dx, dy, istouch)
    self:layout()
    self:forwardToItems("mousemoved", x, y, dx, dy, istouch)
    -- Deliberately does not consume; see InputManager's broadcast note.
end

function Container:mousepressed(x, y, button, istouch, presses)
    self:layout()
    self:forwardToItems("mousepressed", x, y, button, istouch, presses)
    return self:containsPoint(x, y)
end

function Container:mousereleased(x, y, button, istouch, presses)
    self:forwardToItems("mousereleased", x, y, button, istouch, presses)
    return self:containsPoint(x, y)
end

function Container:wheelmoved(x, y)
    -- LOVE doesn't pass a position with wheel events.
    return self:containsPoint(love.mouse.getPosition())
end

return Container
