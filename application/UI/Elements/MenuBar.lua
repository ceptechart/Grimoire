local Class = require "lib.util.Class"
local Container = require "application.UI.Elements.Container"

-- A horizontal bar with three item groups: left-aligned, centered, right-aligned.
local MenuBar = Class.extend(Container)

function MenuBar.new()
    local menuBar = Container.init(setmetatable({}, MenuBar))

    menuBar.leftItems = menuBar:addItemGroup({})
    menuBar.centerItems = menuBar:addItemGroup({})
    menuBar.rightItems = menuBar:addItemGroup({})

    return menuBar
end

function MenuBar:addLeftItem(item)
    table.insert(self.leftItems, item)
    return self
end

function MenuBar:addCenterItem(item)
    table.insert(self.centerItems, item)
    return self
end

function MenuBar:addRightItem(item)
    table.insert(self.rightItems, item)
    return self
end

function MenuBar:getContentWidth()
    return Container.sumWidth(self.leftItems, self.itemSpacing)
        + Container.sumWidth(self.centerItems, self.itemSpacing)
        + Container.sumWidth(self.rightItems, self.itemSpacing)
end

function MenuBar:getDefaultWidth()
    return self.padding.x * 2 + self:getBorderWidth() * 2 + self:getContentWidth()
end

function MenuBar:getHeight()
    local tallest = math.max(
        Container.maxHeight(self.leftItems),
        Container.maxHeight(self.centerItems),
        Container.maxHeight(self.rightItems))
    return tallest + self.padding.y * 2 + self:getBorderWidth() * 2
end

function MenuBar:layout()
    local border = self:getBorderWidth()
    local width = self:getWidth()
    local contentTop = self.position.y + self.padding.y + border
    local contentHeight = self:getHeight() - self.padding.y * 2 - border * 2

    local function itemY(item)
        return contentTop + (contentHeight - item:getHeight()) / 2
    end

    local x = self.position.x + self.padding.x + border
    for _, item in ipairs(self.leftItems) do
        item:withPosition(x, itemY(item))
        x = x + item:getWidth() + self.itemSpacing
    end

    x = self.position.x + width - self.padding.x - border
    for i = #self.rightItems, 1, -1 do
        local item = self.rightItems[i]
        x = x - item:getWidth()
        item:withPosition(x, itemY(item))
        x = x - self.itemSpacing
    end

    x = self.position.x + (width - Container.sumWidth(self.centerItems, self.itemSpacing)) / 2
    for _, item in ipairs(self.centerItems) do
        item:withPosition(x, itemY(item))
        x = x + item:getWidth() + self.itemSpacing
    end
end

return MenuBar
