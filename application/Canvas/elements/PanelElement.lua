local Theme = require "application.Style.Theme"
local Panel = require "application.Style.Panel"
local Clip = require "application.Style.Clip"
local RectResize = require "application.Canvas.RectResize"

-- A plain rectangle with a title bar. The first element type, and the one meant as
-- the base every other rectangular type follows: draw, hit test, a header that acts
-- as a drag handle, and resize zones along its edges via the shared RectResize.
local PanelElement = { name = "panel" }

local HEADER_HEIGHT = 28
local TITLE_PADDING = 8
-- Vertical inset of the title's text rect within the header, which is what leaves the
-- inline editor's box room to sit inside the header rather than over it.
local TITLE_INSET = 3
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

-- Where the title's text sits, in world coordinates. Used both to draw it and to
-- describe it to the inline editor, so the text doesn't shift when editing starts.
-- Returns values rather than a table: this runs in draw, once per panel per frame.
local function titleRect(element)
    return element.x + TITLE_PADDING,
        element.y + TITLE_INSET,
        math.max(0, element.width - TITLE_PADDING * 2),
        HEADER_HEIGHT - TITLE_INSET * 2
end

-- Double-clicking anywhere on the header renames, not just the few pixels the title
-- text happens to cover -- hence the wider `hit` region.
function PanelElement.textFields(element)
    local x, y, width, height = titleRect(element)

    return { {
        prop = "title",
        x = x, y = y, width = width, height = height,
        font = "small",
        color = "elementTitle",
        hit = {
            x = element.x,
            y = element.y,
            width = element.width,
            height = HEADER_HEIGHT,
        },
    } }
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

    -- While the title is being edited the editor draws it instead, caret and all --
    -- drawing both would show the old value underneath the new one.
    if not (context.editingId == element.id and context.editingProp == "title") then
        -- Text is rasterized at the theme's size and then scaled by the canvas
        -- transform, so it softens as you zoom in. Per-zoom font sizes are the fix when
        -- it starts to matter.
        local font = Theme:font("small")
        local previousFont = love.graphics.getFont()
        local titleX, titleY, titleWidth, titleHeight = titleRect(element)

        love.graphics.setFont(font)
        love.graphics.setColor(Theme:color("elementTitle"):unpacked())

        -- Clipped to the same rect the editor uses, so a title too long for the panel
        -- stops at its edge instead of spilling across the board.
        Clip.push(titleX, titleY, titleWidth, titleHeight)
        love.graphics.print(element.props.title or "",
            titleX, titleY + (titleHeight - font:getHeight()) / 2)
        Clip.pop()

        love.graphics.setFont(previousFont)
    end

    love.graphics.setColor(r, g, b, a)
end

return PanelElement
