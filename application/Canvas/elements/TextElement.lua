local Theme = require "application.Style.Theme"
local Clip = require "application.Style.Clip"
local PanelElement = require "application.Canvas.elements.PanelElement"

-- A panel whose body is an editable, automatically-wrapping note. Derived from
-- PanelElement the same way ContainerElement and ImageElement are: the frame, the
-- header-as-drag-handle and the editable title are reused as-is, and what's added
-- here is a second text field for the body -- multiline, unlike the title -- and
-- drawing that body wrapped to the element's own width.
local TextElement = { name = "text" }

local BODY_PADDING = 8
local DEFAULT_WIDTH = 260
local DEFAULT_HEIGHT = 180
local MIN_WIDTH = 140
local MIN_HEIGHT = PanelElement.getHeaderHeight() + 60

local STYLE = PanelElement.newStyle("elementSurface", "elementHeader", "elementBorder")

function TextElement.defaultSize()
    return DEFAULT_WIDTH, DEFAULT_HEIGHT
end

function TextElement.defaultProps()
    return { title = "Note", body = "" }
end

function TextElement.minSize()
    return MIN_WIDTH, MIN_HEIGHT
end

function TextElement.bodyRect(element)
    local header = PanelElement.getHeaderHeight()
    return element.x + BODY_PADDING,
        element.y + header + BODY_PADDING,
        math.max(0, element.width - BODY_PADDING * 2),
        math.max(0, element.height - header - BODY_PADDING * 2)
end

-- The title field is PanelElement's, scoped to the header; the body field is this
-- type's own, scoped to everything below it. Order matters for
-- ElementRegistry:textFieldAt, which returns the first match -- a double-click on
-- the header renames, anywhere else opens the body.
function TextElement.textFields(element)
    local fields = PanelElement.textFields(element)
    local x, y, width, height = TextElement.bodyRect(element)

    table.insert(fields, {
        prop = "body",
        x = x, y = y, width = width, height = height,
        font = "small",
        color = "foreground",
        multiline = true,
        hit = {
            x = element.x,
            y = element.y + PanelElement.getHeaderHeight(),
            width = element.width,
            height = element.height - PanelElement.getHeaderHeight(),
        },
    })

    return fields
end

-- The title bar behaves exactly as a panel's.
TextElement.hitTestHandle = PanelElement.hitTestHandle

-- Greedy word wrap, same algorithm TextEditSession uses for the live editor -- kept
-- separate rather than shared, since this one only ever needs to turn a finished
-- string into drawn lines and has no caret/selection/offset bookkeeping to agree
-- with.
local function wrapText(font, text, width)
    local lines = {}
    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        if paragraph == "" then
            table.insert(lines, "")
        else
            local current = nil
            for word in paragraph:gmatch("%S+") do
                local candidate = current and (current .. " " .. word) or word
                if current and font:getWidth(candidate) > width then
                    table.insert(lines, current)
                    current = word
                else
                    current = candidate
                end
            end
            table.insert(lines, current or "")
        end
    end
    return lines
end

function TextElement.draw(element, context)
    PanelElement.drawFrame(element, context, STYLE)

    -- While the body is being edited the editor draws it instead, caret and all --
    -- drawing both would show the old value underneath the new one (see
    -- PanelElement's own title, which the same rule applies to).
    if context.editingId == element.id and context.editingProp == "body" then
        return
    end

    local x, y, width, height = TextElement.bodyRect(element)
    local font = Theme:font("small")
    local previousFont = love.graphics.getFont()
    local r, g, b, a = love.graphics.getColor()

    Clip.push(x, y, width, height)
    love.graphics.setFont(font)
    love.graphics.setColor(Theme:color("foreground"):unpacked())

    local lineHeight = font:getHeight()
    for index, line in ipairs(wrapText(font, element.props.body or "", width)) do
        love.graphics.print(line, x, y + (index - 1) * lineHeight)
    end

    love.graphics.setFont(previousFont)
    love.graphics.setColor(r, g, b, a)
    Clip.pop()
end

return TextElement
