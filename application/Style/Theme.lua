local Color = require "lib.util.math.Color"

-- Resolves the tokens that widgets store ("surface", "small", "cornerRadius")
-- against whichever theme table is currently loaded.
--
-- Widgets deliberately hold token names rather than resolved Colors and Fonts, and
-- look them up at draw time. That keeps a theme swap to a table swap plus a cache
-- clear, instead of requiring every widget to be rebuilt.
local Theme = {}

local current
local colorCache
local fontCache

-- Multiplied into every color this resolves, so a whole subtree can be drawn faded
-- without anything in it knowing (see pushOpacity).
local opacity = 1
local opacityStack = {}

function Theme:load(theme)
    current = theme
    colorCache = {}
    fontCache = {}
    return self
end

function Theme:getName()
    return current and current.name or "none"
end

local function missing(kind, token)
    error(("theme '%s' has no %s '%s'"):format(Theme:getName(), kind, tostring(token)), 3)
end

-- Theme files write colors as 0xRRGGBB, or { 0xRRGGBB, alpha } when translucent.
local function buildColor(spec, token)
    if type(spec) == "number" then
        return Color.fromHex(spec)
    elseif type(spec) == "table" then
        return Color.fromHex(spec[1], spec[2])
    end
    missing("color", token)
end

-- Fades a color by the current opacity. Allocates, so it only runs while something
-- has actually asked for one -- at rest this hands back the cached instance.
local function faded(color)
    if opacity >= 1 then
        return color
    end
    return color:withAlpha(color.a * opacity)
end

-- Draws everything resolved until the matching popOpacity at `value` times its normal
-- alpha. This is a global mode rather than a parameter threaded through drawing code
-- on purpose: colors are already resolved here at draw time rather than stored, which
-- makes this the one place a whole subtree can be faded without every widget and
-- element type having to implement fading itself. Nests multiplicatively.
--
-- It follows that the pair has to be balanced, and that nothing may cache a resolved
-- color across frames -- both already true everywhere.
function Theme:pushOpacity(value)
    table.insert(opacityStack, opacity)
    opacity = opacity * value
    return self
end

function Theme:popOpacity()
    opacity = table.remove(opacityStack) or 1
    return self
end

-- Returns a shared Color; treat the result as immutable.
function Theme:color(token)
    local color = colorCache[token]
    if not color then
        color = buildColor(current.colors[token], token)
        colorCache[token] = color
    end
    return faded(color)
end

-- Style properties accept either a token or a literal value, so a one-off shade or
-- radius stays possible without inventing a theme entry for it.
function Theme:resolveColor(value)
    if type(value) == "string" then
        -- Already faded by :color -- fading here too would square the opacity.
        return self:color(value)
    end
    return faded(value or Color.TRANSPARENT)
end

function Theme:font(token)
    local font = fontCache[token]
    if not font then
        local spec = current.fonts[token]
        if not spec then
            missing("font", token)
        end
        font = spec.family and love.graphics.newFont(spec.family, spec.size)
            or love.graphics.newFont(spec.size)
        fontCache[token] = font
    end
    return font
end

function Theme:metric(token)
    local value = current.metrics[token]
    if value == nil then
        missing("metric", token)
    end
    return value
end

function Theme:resolveMetric(value)
    if type(value) == "string" then
        return self:metric(value)
    end
    return value or 0
end

return Theme
