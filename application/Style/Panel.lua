local Class = require "lib.util.Class"
local Theme = require "application.Style.Theme"
local Shadow = require "application.Style.Shadow"

-- A reusable background style: fill, border, corner radius, optional drop shadow.
--
-- A Panel is not a widget. It has no position of its own and is drawn into a rect
-- supplied by whoever owns it, so a single instance can back every button in a
-- given state without any of them interfering with each other.
--
-- Colors accept a theme token or a literal Color; radii and weights accept a theme
-- metric token or a number. Both are resolved at draw time.
local Panel = Class.extend()

function Panel.new()
    return setmetatable({
        color = "surface",
        lineColor = "border",
        lineWeight = "borderWidth",
        cornerRadius = "cornerRadius",
        shadow = false,
        shadowColor = "shadow",
        shadowOffsetX = "shadowOffset",
        shadowOffsetY = "shadowOffset",
        shadowBlur = "shadowBlur",
    }, Panel)
end

function Panel:withColor(color)
    self.color = color
    return self
end

function Panel:withLineColor(color)
    self.lineColor = color
    return self
end

function Panel:withLineWeight(weight)
    self.lineWeight = weight
    return self
end

function Panel:withCornerRadius(radius)
    self.cornerRadius = radius
    return self
end

function Panel:withShadow(shadow)
    self.shadow = shadow
    return self
end

function Panel:withShadowColor(color)
    self.shadowColor = color
    return self
end

function Panel:withShadowOffset(x, y)
    self.shadowOffsetX = x
    self.shadowOffsetY = y
    return self
end

function Panel:withShadowBlur(blur)
    self.shadowBlur = blur
    return self
end

-- Widgets inset their content by this so the border never overlaps it.
function Panel:getLineWeight()
    return Theme:resolveMetric(self.lineWeight)
end

function Panel:getCornerRadius()
    return Theme:resolveMetric(self.cornerRadius)
end

function Panel:draw(x, y, width, height)
    local r, g, b, a = love.graphics.getColor()
    local cornerRadius = self:getCornerRadius()

    if self.shadow then
        Shadow:draw(x, y, width, height, cornerRadius,
            Theme:resolveColor(self.shadowColor),
            Theme:resolveMetric(self.shadowOffsetX),
            Theme:resolveMetric(self.shadowOffsetY),
            Theme:resolveMetric(self.shadowBlur))
    end

    -- Fully transparent fills and borders are the common case for the panels
    -- backing labels and idle buttons; skipping them avoids a per-frame draw call
    -- per widget that could never put a pixel on screen.
    local fill = Theme:resolveColor(self.color)
    if fill.a > 0 then
        love.graphics.setColor(fill:unpacked())
        love.graphics.rectangle("fill", x, y, width, height, cornerRadius, cornerRadius)
    end

    local line = Theme:resolveColor(self.lineColor)
    local lineWeight = self:getLineWeight()
    if lineWeight > 0 and line.a > 0 then
        local previousLineWidth = love.graphics.getLineWidth()
        love.graphics.setColor(line:unpacked())
        love.graphics.setLineWidth(lineWeight)
        love.graphics.rectangle("line", x, y, width, height, cornerRadius, cornerRadius)
        love.graphics.setLineWidth(previousLineWidth)
    end

    love.graphics.setColor(r, g, b, a)
end

return Panel
