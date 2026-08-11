-- Soft drop shadows for rounded rects.
--
-- Each distinct (size, corner radius, blur radius) is rendered once into a canvas
-- just big enough for the shape and then cached, so drawing a shadow at steady
-- state is a single textured quad. The blur runs on that small canvas in two
-- separable passes, which means cost scales with the shadow's own size rather than
-- with the window's -- the previous approach blurred the whole screen once per
-- shadowed panel, and reset the render target to the screen while doing it.
local Shadow = {}

-- Sizes churn when the window resizes, so the cache is flushed wholesale once it
-- grows past this. Tracking ages would cost more than re-rendering a few shapes.
local CACHE_LIMIT = 48

local blurShader
local cache = {}
local cacheCount = 0

local function getBlurShader()
    if not blurShader then
        blurShader = love.graphics.newShader("lib/shaders/blur.glsl")
    end
    return blurShader
end

local function render(width, height, cornerRadius, blurRadius)
    -- Room on every side for the blur to fade out without clipping.
    local padding = math.ceil(blurRadius) * 2
    local canvasWidth = width + padding * 2
    local canvasHeight = height + padding * 2

    local shape = love.graphics.newCanvas(canvasWidth, canvasHeight)
    local scratch = love.graphics.newCanvas(canvasWidth, canvasHeight)

    local previousCanvas = love.graphics.getCanvas()
    local previousShader = love.graphics.getShader()
    local previousBlend, previousAlphaMode = love.graphics.getBlendMode()
    local r, g, b, a = love.graphics.getColor()

    -- setCanvas does not reset the transform stack, and callers may be drawing under
    -- one (canvas elements render translated and scaled). The shape has to go into
    -- its canvas at 1:1 or it lands off-target and at the wrong size.
    love.graphics.push()
    love.graphics.origin()

    love.graphics.setCanvas(shape)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", padding, padding, width, height, cornerRadius, cornerRadius)

    local shader = getBlurShader()
    love.graphics.setShader(shader)
    love.graphics.setBlendMode("alpha", "premultiplied")
    shader:send("radius", blurRadius)

    love.graphics.setCanvas(scratch)
    love.graphics.clear(0, 0, 0, 0)
    shader:send("direction", { 1 / canvasWidth, 0 })
    love.graphics.draw(shape)

    love.graphics.setCanvas(shape)
    love.graphics.clear(0, 0, 0, 0)
    shader:send("direction", { 0, 1 / canvasHeight })
    love.graphics.draw(scratch)

    love.graphics.setCanvas(previousCanvas)
    love.graphics.setShader(previousShader)
    love.graphics.setBlendMode(previousBlend, previousAlphaMode)
    love.graphics.setColor(r, g, b, a)
    love.graphics.pop()

    return { texture = shape, padding = padding }
end

local function getShadow(width, height, cornerRadius, blurRadius)
    local key = ("%dx%d:%d:%d"):format(width, height, cornerRadius, blurRadius)

    local entry = cache[key]
    if not entry then
        if cacheCount >= CACHE_LIMIT then
            cache = {}
            cacheCount = 0
        end
        entry = render(width, height, cornerRadius, blurRadius)
        cache[key] = entry
        cacheCount = cacheCount + 1
    end

    return entry
end

function Shadow:draw(x, y, width, height, cornerRadius, color, offsetX, offsetY, blurRadius)
    width = math.ceil(width)
    height = math.ceil(height)
    blurRadius = math.max(1, math.ceil(blurRadius or 0))

    if width <= 0 or height <= 0 then
        return
    end

    local entry = getShadow(width, height, math.ceil(cornerRadius or 0), blurRadius)

    local r, g, b, a = love.graphics.getColor()
    local previousBlend, previousAlphaMode = love.graphics.getBlendMode()

    -- The cached texture holds premultiplied alpha (it was blurred that way), so
    -- the tint has to be premultiplied too or translucent shadows come out bright.
    love.graphics.setBlendMode("alpha", "premultiplied")
    love.graphics.setColor(color.r * color.a, color.g * color.a, color.b * color.a, color.a)
    love.graphics.draw(entry.texture, x + offsetX - entry.padding, y + offsetY - entry.padding)

    love.graphics.setBlendMode(previousBlend, previousAlphaMode)
    love.graphics.setColor(r, g, b, a)
end

-- Cached shapes don't depend on theme colors (the tint is applied at draw time),
-- but they do bake in corner radius, so a theme swap should drop them.
function Shadow:clearCache()
    cache = {}
    cacheCount = 0
end

return Shadow
