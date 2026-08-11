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

-- Returns a shared Color; treat the result as immutable.
function Theme:color(token)
    local color = colorCache[token]
    if not color then
        color = buildColor(current.colors[token], token)
        colorCache[token] = color
    end
    return color
end

-- Style properties accept either a token or a literal value, so a one-off shade or
-- radius stays possible without inventing a theme entry for it.
function Theme:resolveColor(value)
    if type(value) == "string" then
        return self:color(value)
    end
    return value or Color.TRANSPARENT
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
