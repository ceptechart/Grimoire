local Class = require "lib.util.Class"
local Theme = require "application.Style.Theme"
local Widget = require "application.UI.Elements.Widget"

-- Text and/or an icon, optionally on a Panel.
local Label = Class.extend(Widget)

function Label.new(text)
    local label = Widget.init(setmetatable({}, Label))

    label.text = text or ""
    label.font = "small"
    label.color = "foreground"
    label.icon = nil
    label.iconSize = nil
    label.iconSpacing = 4
    label.shadow = false
    label.shadowColor = "shadow"
    label.shadowOffsetX = 1
    label.shadowOffsetY = 1

    return label
end

function Label:withText(text)
    self.text = text or ""
    return self
end

function Label:withFont(font)
    self.font = font
    return self
end

function Label:withColor(color)
    self.color = color
    return self
end

function Label:withIcon(icon, spacing)
    self.icon = icon
    self.iconSpacing = spacing or self.iconSpacing
    return self
end

-- Draws the icon at an explicit height instead of matching the text. For buttons
-- whose size comes from the icon rather than the other way round -- an icon button
-- with no text has nothing to match against.
function Label:withIconSize(size)
    self.iconSize = size
    return self
end

function Label:withShadow(shadow)
    self.shadow = shadow
    return self
end

function Label:withShadowColor(color)
    self.shadowColor = color
    return self
end

function Label:getFont()
    return Theme:font(self.font)
end

-- Icons are scaled so their height matches the text's line height, unless an
-- explicit iconSize says otherwise.
function Label:getIconScale()
    return (self.iconSize or self:getFont():getHeight()) / self.icon:getHeight()
end

function Label:getIconWidth()
    if not self.icon then
        return 0
    end
    return self.icon:getWidth() * self:getIconScale()
end

function Label:getIconHeight()
    if not self.icon then
        return 0
    end
    return self.icon:getHeight() * self:getIconScale()
end

function Label:getContentWidth()
    local width = self:getFont():getWidth(self.text)

    if self.icon then
        width = width + self:getIconWidth()
        if self.text ~= "" then
            width = width + self.iconSpacing
        end
    end

    return width
end

-- The taller of the text and the icon. Without an explicit iconSize the two match by
-- construction, so this only differs for icon buttons -- and the font's height stays
-- the floor, so a row of labels keeps one height whether or not it has icons.
function Label:getContentHeight()
    return math.max(self:getFont():getHeight(), self:getIconHeight())
end

function Label:getDefaultWidth()
    return self:getContentWidth() + self.padding.x * 2 + self:getBorderWidth() * 2
end

function Label:getHeight()
    return self:getContentHeight() + self.padding.y * 2 + self:getBorderWidth() * 2
end

function Label:draw()
    if self.panel then
        self.panel:draw(self.position.x, self.position.y, self:getWidth(), self:getHeight())
    end

    local r, g, b, a = love.graphics.getColor()
    local color = Theme:resolveColor(self.color)
    local border = self:getBorderWidth()

    local contentX = self.position.x + self.padding.x + border
    local contentY = self.position.y + self.padding.y + border
    -- Text and icon are centred against each other rather than sharing a top edge,
    -- which is a no-op unless an explicit iconSize made them different heights.
    local contentHeight = self:getContentHeight()
    local textX = contentX

    if self.icon then
        local scale = self:getIconScale()
        love.graphics.setColor(color:unpacked())
        love.graphics.draw(self.icon, contentX,
            contentY + (contentHeight - self:getIconHeight()) / 2, 0, scale, scale)

        textX = textX + self:getIconWidth()
        if self.text ~= "" then
            textX = textX + self.iconSpacing
        end
    end

    if self.text ~= "" then
        local font = self:getFont()
        local previousFont = love.graphics.getFont()
        love.graphics.setFont(font)

        local textY = contentY + (contentHeight - font:getHeight()) / 2

        if self.shadow then
            love.graphics.setColor(Theme:resolveColor(self.shadowColor):unpacked())
            love.graphics.print(self.text, textX + self.shadowOffsetX, textY + self.shadowOffsetY)
        end

        love.graphics.setColor(color:unpacked())
        love.graphics.print(self.text, textX, textY)

        love.graphics.setFont(previousFont)
    end

    love.graphics.setColor(r, g, b, a)
end

return Label
