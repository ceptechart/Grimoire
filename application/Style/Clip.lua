-- Scissor clipping in whatever coordinate space is currently being drawn in.
--
-- love.graphics.setScissor takes window pixels and ignores the transform stack, so
-- code drawing under the canvas transform can't hand it a world rect. This converts
-- through the live transform first, and intersects rather than replaces, so a clip
-- inside another clip narrows it instead of escaping it.
--
-- push/pop are paired; the stack holds the previous scissor so nesting restores
-- correctly, and an empty saved scissor turns clipping back off.
local Clip = {}

local stack = {}
local unpack = table.unpack or unpack

function Clip.push(x, y, width, height)
    stack[#stack + 1] = { love.graphics.getScissor() }

    local x1, y1 = love.graphics.transformPoint(x, y)
    local x2, y2 = love.graphics.transformPoint(x + width, y + height)

    -- abs/min rather than assuming x1 < x2: a mirrored or rotated transform would
    -- otherwise produce a negative size, which setScissor rejects.
    love.graphics.intersectScissor(
        math.min(x1, x2), math.min(y1, y2),
        math.max(0, math.abs(x2 - x1)), math.max(0, math.abs(y2 - y1)))
end

function Clip.pop()
    local previous = table.remove(stack)
    if not previous then
        return
    end
    love.graphics.setScissor(unpack(previous))
end

return Clip
