local utf8 = require "utf8"
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

-- The type icon sits in the header's top-right corner, the same image the tool
-- palette uses for this element's creating tool -- so a panel reads as what it is
-- without opening it. Reserved on every type alike (see titleRect), which is what
-- keeps the title box and the icon from needing to know about each other's size.
local ICON_SIZE = 16
local ICON_PADDING = 6

-- Loaded lazily (not at require time, love.graphics may not exist yet) and shared
-- across every element of a given type, the same cache Toast keeps for its icons.
local iconCache = {}
local function iconFor(path)
    local icon = iconCache[path]
    if not icon then
        icon = love.graphics.newImage(path)
        iconCache[path] = icon
    end
    return icon
end

-- The colors one panel-shaped element type draws itself in. A style is built once per
-- type rather than per element, like the UI's chrome panels: it carries style, not
-- position, and is drawn into whatever rect it's handed.
--
-- This is the seam a derived type uses (see ContainerElement): everything below the
-- colors -- the header strip, the title clipping, the resize zones -- is identical
-- across rectangular types, so a type that only wants to look different reuses
-- drawFrame with a style of its own rather than copying it.
function PanelElement.newStyle(surface, header, border, icon)
    return {
        panel = Panel.new()
            :withColor(surface)
            :withLineColor(border)
            :withShadow(true),
        header = header,
        border = border,
        icon = icon,
    }
end

local DEFAULT_STYLE = PanelElement.newStyle("elementSurface", "elementHeader", "elementBorder",
    "res/img/tool/panel.png")

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
    local reserved = ICON_PADDING + ICON_SIZE + ICON_PADDING
    return element.x + TITLE_PADDING,
        element.y + TITLE_INSET,
        math.max(0, element.width - TITLE_PADDING - reserved),
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

-- Cuts text to fit width, appending an ellipsis when it had to. Character-by-character
-- rather than binary search: titles are short enough that this never runs more than a
-- handful of times, and the simple version can't overshoot a multi-byte character.
local ELLIPSIS = "..."
local function truncate(font, text, width)
    if font:getWidth(text) <= width then
        return text
    end

    local ellipsisWidth = font:getWidth(ELLIPSIS)
    local fitWidth = math.max(0, width - ellipsisWidth)
    local result = ""
    for _, codepoint in utf8.codes(text) do
        local candidate = result .. utf8.char(codepoint)
        if font:getWidth(candidate) > fitWidth then
            break
        end
        result = candidate
    end
    return result .. ELLIPSIS
end

-- The panel body, header strip and title, in a style's colors. Split out from draw so
-- a derived type can render the same shape in colors of its own.
function PanelElement.drawFrame(element, context, style)
    style = style or DEFAULT_STYLE
    style.panel:draw(element.x, element.y, element.width, element.height)

    local r, g, b, a = love.graphics.getColor()
    local radius = Theme:metric("cornerRadius")

    -- Rounded where it meets the panel's top corners, square where it meets the
    -- body: draw the rounded rect, then patch over its bottom corners.
    love.graphics.setColor(Theme:color(style.header):unpacked())
    love.graphics.rectangle("fill", element.x, element.y, element.width, HEADER_HEIGHT, radius, radius)
    love.graphics.rectangle("fill", element.x, element.y + HEADER_HEIGHT - radius, element.width, radius)

    local previousLineWidth = love.graphics.getLineWidth()
    love.graphics.setColor(Theme:color(style.border):unpacked())
    love.graphics.setLineWidth(1 / context.zoom)
    love.graphics.line(
        element.x, element.y + HEADER_HEIGHT,
        element.x + element.width, element.y + HEADER_HEIGHT)
    love.graphics.setLineWidth(previousLineWidth)

    -- The type icon, top-right of the header -- the same image its creating tool
    -- uses, so a panel reads as what it is without opening it. Drawn regardless of
    -- whether the title is mid-edit, since the editor only replaces the title text.
    if style.icon then
        local icon = iconFor(style.icon)
        love.graphics.setColor(Theme:color("elementTitle"):unpacked())
        love.graphics.draw(icon,
            element.x + element.width - ICON_PADDING - ICON_SIZE,
            element.y + (HEADER_HEIGHT - ICON_SIZE) / 2,
            0, ICON_SIZE / icon:getWidth(), ICON_SIZE / icon:getHeight())
    end

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
        -- stops at its edge instead of spilling across the board. The text itself is
        -- pre-truncated with an ellipsis rather than left to the clip to just cut off,
        -- so a long title reads as shortened rather than as abruptly chopped.
        Clip.push(titleX, titleY, titleWidth, titleHeight)
        love.graphics.print(truncate(font, element.props.title or "", titleWidth),
            titleX, titleY + (titleHeight - font:getHeight()) / 2)
        Clip.pop()

        love.graphics.setFont(previousFont)
    end

    love.graphics.setColor(r, g, b, a)
end

function PanelElement.draw(element, context)
    PanelElement.drawFrame(element, context, DEFAULT_STYLE)
end

return PanelElement
