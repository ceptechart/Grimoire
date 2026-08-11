local Theme = require "application.Style.Theme"
local Panel = require "application.Style.Panel"
local RectResize = require "application.Canvas.RectResize"

-- A plain rectangle with a title bar. The first element type, and the one meant as
-- the base every other rectangular type follows: draw, hit test, a header that acts
-- as a drag handle, and resize zones along its edges via the shared RectResize.
local PanelElement = { name = "panel" }

local HEADER_HEIGHT = 28
local TITLE_PADDING = 8
local DEFAULT_WIDTH = 240
local DEFAULT_HEIGHT = 160
local MIN_WIDTH = 160
local MIN_HEIGHT = HEADER_HEIGHT + 48

-- Shared by every panel element, like the UI's chrome panels: it carries style, not
-- position, and is drawn into whatever rect it's handed.
local bodyPanel = Panel.new()
    :withColor("elementSurface")
    :withLineColor("elementBorder")
    :withShadow(true)

function PanelElement.defaultSize()
    return DEFAULT_WIDTH, DEFAULT_HEIGHT
end

function PanelElement.defaultProps()
    return { title = "Panel" }
end

function PanelElement.minSize()
    return MIN_WIDTH, MIN_HEIGHT
end

function PanelElement.getHeaderHeight()
    return HEADER_HEIGHT
end

-- Edges and corners resize (checked first, since those zones are only a few pixels
-- wide and would otherwise be shadowed by the much larger header/body zones); the
-- header is the drag handle; the body just selects.
function PanelElement.hitTestHandle(element, x, y, zoom)
    local resizeHandle = RectResize.hitTest(x, y, element.x, element.y, element.width, element.height, zoom)
    if resizeHandle then
        return resizeHandle
    end

    if x >= element.x and x <= element.x + element.width
        and y >= element.y and y <= element.y + HEADER_HEIGHT then
        return "move"
    end

    return nil
end

function PanelElement.draw(element, context)
    bodyPanel:draw(element.x, element.y, element.width, element.height)

    local r, g, b, a = love.graphics.getColor()
    local radius = Theme:metric("cornerRadius")

    -- Rounded where it meets the panel's top corners, square where it meets the
    -- body: draw the rounded rect, then patch over its bottom corners.
    love.graphics.setColor(Theme:color("elementHeader"):unpacked())
    love.graphics.rectangle("fill", element.x, element.y, element.width, HEADER_HEIGHT, radius, radius)
    love.graphics.rectangle("fill", element.x, element.y + HEADER_HEIGHT - radius, element.width, radius)

    local previousLineWidth = love.graphics.getLineWidth()
    love.graphics.setColor(Theme:color("elementBorder"):unpacked())
    love.graphics.setLineWidth(1 / context.zoom)
    love.graphics.line(
        element.x, element.y + HEADER_HEIGHT,
        element.x + element.width, element.y + HEADER_HEIGHT)
    love.graphics.setLineWidth(previousLineWidth)

    -- Text is rasterized at the theme's size and then scaled by the canvas
    -- transform, so it softens as you zoom in. Per-zoom font sizes are the fix when
    -- it starts to matter.
    local font = Theme:font("small")
    local previousFont = love.graphics.getFont()
    love.graphics.setFont(font)
    love.graphics.setColor(Theme:color("elementTitle"):unpacked())
    love.graphics.print(element.props.title or "",
        element.x + TITLE_PADDING,
        element.y + (HEADER_HEIGHT - font:getHeight()) / 2)
    love.graphics.setFont(previousFont)

    love.graphics.setColor(r, g, b, a)
end

return PanelElement
