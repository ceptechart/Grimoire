local Class = require "lib.util.Class"
local Container = require "application.UI.Elements.Container"

-- A dropdown: a vertical list of items that is hidden until opened, and closes on
-- the next click anywhere.
local VerticalMenu = Class.extend(Container)

function VerticalMenu.new()
    local menu = Container.init(setmetatable({}, VerticalMenu))

    menu.items = menu:addItemGroup({})
    menu.visible = false
    menu.anchor = nil

    return menu
end

-- The anchor is the widget that opens this menu. Clicks on it are left alone so its
-- own handler (typically a toggle) can run; treating them as outside clicks would
-- close and reopen the menu in the same frame.
function VerticalMenu:withAnchor(anchor)
    self.anchor = anchor
    return self
end

function VerticalMenu:addItem(item)
    table.insert(self.items, item)
    return self
end

function VerticalMenu:getDefaultWidth()
    self:equalizeItemWidths()
    return self.padding.x * 2 + self:getBorderWidth() * 2 + Container.maxWidth(self.items)
end

function VerticalMenu:getHeight()
    return Container.sumHeight(self.items, self.itemSpacing)
        + self.padding.y * 2
        + self:getBorderWidth() * 2
end

-- Gives every item a minWidth equal to the widest item's own default width,
-- so the whole column lines up evenly.
function VerticalMenu:equalizeItemWidths()
    local maxWidth = 0
    for _, item in ipairs(self.items) do
        maxWidth = math.max(maxWidth, item:getDefaultWidth())
    end

    for _, item in ipairs(self.items) do
        item:withMinWidth(maxWidth)
    end
end

function VerticalMenu:layout()
    self:equalizeItemWidths()

    local border = self:getBorderWidth()
    local x = self.position.x + self.padding.x + border
    local y = self.position.y + self.padding.y + border

    for _, item in ipairs(self.items) do
        item:withPosition(x, y)
        y = y + item:getHeight() + self.itemSpacing
    end
end

function VerticalMenu:open()
    self.visible = true
    self:layout()
end

function VerticalMenu:close()
    self.visible = false
end

function VerticalMenu:toggle()
    if self.visible then
        self:close()
    else
        self:open()
    end
end

function VerticalMenu:draw()
    if not self.visible then
        return
    end
    Container.draw(self)
end

function VerticalMenu:mousemoved(x, y, dx, dy, istouch)
    if not self.visible then
        return
    end
    Container.mousemoved(self, x, y, dx, dy, istouch)
end

function VerticalMenu:mousepressed(x, y, button, istouch, presses)
    if not self.visible then
        return false
    end

    if self.anchor and self.anchor:containsPoint(x, y) then
        return false
    end

    local inside = self:containsPoint(x, y)
    if inside then
        self:layout()
        self:forwardToItems("mousepressed", x, y, button, istouch, presses)
    end

    self:close()
    return inside
end

function VerticalMenu:mousereleased(x, y, button, istouch, presses)
    if not self.visible then
        return false
    end
    return Container.mousereleased(self, x, y, button, istouch, presses)
end

function VerticalMenu:wheelmoved(x, y)
    if not self.visible then
        return false
    end
    return Container.wheelmoved(self, x, y)
end

return VerticalMenu
