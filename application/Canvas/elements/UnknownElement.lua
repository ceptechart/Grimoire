local Theme = require "application.Style.Theme"
local Panel = require "application.Style.Panel"

-- Stand-in for an element whose type this build doesn't have registered.
--
-- Board files outlive the build that wrote them: opening one saved by a newer
-- Grimoire, or by a build with an element module this one doesn't ship, must not
-- crash and must not quietly drop content. Those elements keep their real `type` and
-- their `props` untouched, so saving writes them back exactly as they came in -- and
-- they start drawing properly the moment their type is registered.
--
-- Attached with ElementRegistry:setFallback rather than :register: it stands in for
-- any number of types and has no type name of its own.
local UnknownElement = { name = "unknown" }

local DEFAULT_WIDTH = 200
local DEFAULT_HEIGHT = 120
local MIN_SIZE = 40
local LABEL_PADDING = 8

-- Warning-coloured border, muted fill: visibly not a real element, but solid enough
-- to find and drag out of the way.
local body = Panel.new()
    :withColor("elementSurface")
    :withLineColor("toastWarn")

function UnknownElement.defaultSize()
    return DEFAULT_WIDTH, DEFAULT_HEIGHT
end

function UnknownElement.defaultProps()
    return {}
end

function UnknownElement.minSize()
    return MIN_SIZE, MIN_SIZE
end

-- Movable but not resizable: dragging it out of the way is useful, changing the
-- geometry of something we can't draw isn't.
function UnknownElement.hitTestHandle(element, x, y, zoom)
    if element:containsPoint(x, y) then
        return "move"
    end
    return nil
end

function UnknownElement.draw(element, context)
    body:draw(element.x, element.y, element.width, element.height)

    local r, g, b, a = love.graphics.getColor()
    local font = Theme:font("small")
    local previousFont = love.graphics.getFont()

    love.graphics.setFont(font)
    love.graphics.setColor(Theme:color("muted"):unpacked())

    -- printf rather than print so a long type name wraps inside the rect instead of
    -- spilling across the board.
    love.graphics.printf(("Unknown element\n%s"):format(element.type),
        element.x + LABEL_PADDING,
        element.y + LABEL_PADDING,
        math.max(0, element.width - LABEL_PADDING * 2),
        "left")

    love.graphics.setFont(previousFont)
    love.graphics.setColor(r, g, b, a)
end

return UnknownElement
