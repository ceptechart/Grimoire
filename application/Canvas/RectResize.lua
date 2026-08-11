-- Shared edge/corner detection and resize math for rectangular elements.
--
-- Every element type is a rect (x, y, width, height) even before it decides what
-- counts as its move handle (a header strip, a whole body, whatever). Grabbing near
-- an edge to resize is the same problem for all of them, so it's solved once here
-- instead of once per element type.
local RectResize = {}

-- Screen pixels, independent of zoom -- the grab zone should feel the same size at
-- any zoom level, so it's converted to world units per call.
local MARGIN_PX = 6

-- Returns a resize-* handle name for a point near one of the rect's edges or
-- corners, or nil if the point isn't in any resize zone. Callers layer their own
-- move-handle logic on top: this only ever returns resize-*.
function RectResize.hitTest(x, y, rectX, rectY, rectWidth, rectHeight, zoom)
    local margin = MARGIN_PX / (zoom or 1)
    local left, right = rectX, rectX + rectWidth
    local top, bottom = rectY, rectY + rectHeight

    if x < left - margin or x > right + margin or y < top - margin or y > bottom + margin then
        return nil
    end

    local nearLeft = math.abs(x - left) <= margin
    local nearRight = math.abs(x - right) <= margin
    local nearTop = math.abs(y - top) <= margin
    local nearBottom = math.abs(y - bottom) <= margin

    if nearLeft and nearTop then return "resize-nw" end
    if nearRight and nearTop then return "resize-ne" end
    if nearLeft and nearBottom then return "resize-sw" end
    if nearRight and nearBottom then return "resize-se" end
    if nearLeft then return "resize-w" end
    if nearRight then return "resize-e" end
    if nearTop then return "resize-n" end
    if nearBottom then return "resize-s" end

    return nil
end

-- Resizing from the min-edge (west/north) moves both position and size along that
-- axis; from the max-edge (east/south) only the size changes. Either way, clamping
-- to minSize keeps the opposite edge anchored instead of letting the rect invert.
local function resizeAxis(originPos, originSize, delta, minSize, fromMinEdge)
    if fromMinEdge then
        local newSize = originSize - delta
        if newSize < minSize then
            delta = originSize - minSize
            newSize = minSize
        end
        return originPos + delta, newSize
    end

    local newSize = originSize + delta
    if newSize < minSize then
        newSize = minSize
    end
    return originPos, newSize
end

-- Turns a resize-* handle and a pointer delta (from where the drag began) into a new
-- rect, anchored at `origin` (the rect captured when the drag began).
function RectResize.apply(handle, origin, dx, dy, minWidth, minHeight)
    local suffix = handle:match("^resize%-(%a+)$")
    local x, width = origin.x, origin.width
    local y, height = origin.y, origin.height

    if suffix:find("w") then
        x, width = resizeAxis(origin.x, origin.width, dx, minWidth, true)
    elseif suffix:find("e") then
        x, width = resizeAxis(origin.x, origin.width, dx, minWidth, false)
    end

    if suffix:find("n") then
        y, height = resizeAxis(origin.y, origin.height, dy, minHeight, true)
    elseif suffix:find("s") then
        y, height = resizeAxis(origin.y, origin.height, dy, minHeight, false)
    end

    return x, y, width, height
end

return RectResize
