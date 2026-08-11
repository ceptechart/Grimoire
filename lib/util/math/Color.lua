local Class = require "lib.util.Class"

local Color = Class.extend()

function Color.new(r, g, b, a)
    return setmetatable({ r = r or 0, g = g or 0, b = b or 0, a = a or 1 }, Color)
end

-- Takes 0xRRGGBB. Alpha is separate because it isn't part of how colors are
-- written in a theme file.
function Color.fromHex(hex, alpha)
    return Color.new(
        bit.band(bit.rshift(hex, 16), 0xFF) / 255,
        bit.band(bit.rshift(hex, 8), 0xFF) / 255,
        bit.band(hex, 0xFF) / 255,
        alpha
    )
end

function Color:lerp(other, t)
    local h1, s1, l1, a1 = self:unpackedHSL()
    local h2, s2, l2, a2 = other:unpackedHSL()

    local function lerp(a, b, t)
        return a + (b - a) * t
    end

    return Color.fromHSL(lerp(h1, h2, t), lerp(s1, s2, t), lerp(l1, l2, t), lerp(a1, a2, t))
end

function Color:withAlpha(alpha)
    return Color.new(self.r, self.g, self.b, alpha)
end

function Color:unpacked()
    return self.r, self.g, self.b, self.a
end

function Color:unpackedHSL()
    local r, g, b, a = self:unpacked()
    local max_val = math.max(r, g, b)
    local min_val = math.min(r, g, b)
    local l = (max_val + min_val) / 2

    if max_val == min_val then
        return 0, 0, l, a
    end

    local d = max_val - min_val
    local s
    if (l > 0.5) then
        s = d / (2.0 - max_val - min_val)
    else
        s = d / (max_val + min_val)
    end

    local h
    if max_val == r then
        if (g > b) then
            h = (g - b) / d + 6
        else
            h = (g - b) / d
        end
    elseif max_val == g then
        h = (b - r) / d + 2
    else
        h = (r - g) / d + 4
    end

    h = h / 6.0
    return h, s, l, a
end

function Color.fromHSL(h, s, l, a)
    if s == 0 then return Color.new(l, l, l, a) end

    local function huetorgb(p, q, t)
        if t < 0 then t = t + 1 end
        if t > 1 then t = t - 1 end
        if t < (1.0/6.0) then return p + (q - p) * 6 * t end
        if t < (1.0/2.0) then return q end
        if t < (2.0/3.0) then return p + (q - p) * ((2.0/3.0) - t) * 6 end
        return p
    end

    local p, q
    if (l < 0.5) then
        q = l * (1 + s)
    else
        q = l + s - l * s
    end
    p = 2 * l - q

    local r, g, b
    r = huetorgb(p, q, h + (1.0/3.0))
    g = huetorgb(p, q, h)
    b = huetorgb(p, q, h - (1.0/3.0))

    return Color.new(r, g, b, a)
end

-- Shared instances: treat as immutable.
Color.WHITE = Color.new(1, 1, 1, 1)
Color.BLACK = Color.new(0, 0, 0, 1)
Color.TRANSPARENT = Color.new(0, 0, 0, 0)

return Color
