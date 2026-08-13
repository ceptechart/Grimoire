local Theme = require "application.Style.Theme"

-- The geometry and the drawing of one vertical scrollbar, and nothing else.
--
-- Holds no state and no position of its own -- it's handed a window rect, how tall
-- the content behind it is, and how far that content is scrolled, and answers where
-- the track and thumb are. That's the same shape as Panel.lua and Shadow.lua: a
-- piece of drawing shared by things that otherwise have nothing to do with each
-- other.
--
-- Which matters here, because two unrelated things scroll. An element's content
-- scrolls, with its offset kept per element in application/Canvas/ContentScroll.lua;
-- an open multiline text field scrolls, with its offset kept in the session and
-- driven by the caret. Neither can share the other's state, and both want exactly
-- the same bar -- so the bar is what's shared.
--
-- Sizes are in whatever space the caller draws in: world units for a canvas element
-- and for the inline editor over one (both are inside the canvas transform), screen
-- pixels for a screen-space field.
local ScrollBar = {}

ScrollBar.WIDTH = 6

-- Below this the thumb is too small to aim at, however long the document is.
local MIN_THUMB = 24

-- Everything about the bar for one window onto some content, or nil when there's
-- nothing to scroll -- a caller can hand this straight through to draw() and hit
-- testing without checking first.
--
-- The offset is clamped here rather than trusted, so a caller that stored one while
-- the content was longer gets a valid answer back instead of having to notice.
function ScrollBar.metrics(x, y, width, height, contentHeight, offset)
    if height <= 0 or width <= 0 then
        return nil
    end

    local maxOffset = contentHeight - height
    if maxOffset <= 0 then
        return nil
    end

    offset = math.max(0, math.min(offset or 0, maxOffset))

    -- The thumb is as much of the track as the window is of the content, which is
    -- what makes its size read as "how much of this am I looking at".
    local thumbHeight = math.min(height, math.max(MIN_THUMB, height * (height / contentHeight)))
    local travel = height - thumbHeight

    return {
        -- The window and content it was measured from, carried along so a caller
        -- that has the metrics doesn't have to keep the inputs around beside them.
        x = x, y = y, width = width, height = height,
        contentHeight = contentHeight,

        offset = offset,
        maxOffset = maxOffset,
        trackX = x + width - ScrollBar.WIDTH,
        trackY = y,
        trackWidth = ScrollBar.WIDTH,
        trackHeight = height,
        thumbY = y + (travel > 0 and travel * (offset / maxOffset) or 0),
        thumbHeight = thumbHeight,
        travel = travel,
    }
end

function ScrollBar.containsPoint(metrics, x, y)
    return metrics ~= nil
        and x >= metrics.trackX and x <= metrics.trackX + metrics.trackWidth
        and y >= metrics.trackY and y <= metrics.trackY + metrics.trackHeight
end

function ScrollBar.onThumb(metrics, y)
    return metrics ~= nil
        and y >= metrics.thumbY and y <= metrics.thumbY + metrics.thumbHeight
end

-- The offset that puts the thumb where a drag has dragged it. `grab` is how far
-- down the thumb the press landed, kept for the whole drag so the thumb tracks the
-- pointer instead of jumping to centre itself on it.
function ScrollBar.offsetFor(metrics, y, grab)
    if metrics.travel <= 0 then
        return 0
    end
    local fraction = (y - grab - metrics.trackY) / metrics.travel
    return math.max(0, math.min(fraction, 1)) * metrics.maxOffset
end

-- How far into the thumb a press should be treated as having landed. On the thumb
-- that's where it actually did; on the bare track the thumb jumps to centre on the
-- point, which is what lets one press carry straight on into a drag rather than
-- needing a separate "click the track" behaviour.
function ScrollBar.grabFor(metrics, y)
    if ScrollBar.onThumb(metrics, y) then
        return y - metrics.thumbY
    end
    return metrics.thumbHeight / 2
end

function ScrollBar.draw(metrics, active)
    if not metrics then
        return
    end

    local r, g, b, a = love.graphics.getColor()
    local radius = metrics.trackWidth / 2

    love.graphics.setColor(Theme:color("scrollTrack"):unpacked())
    love.graphics.rectangle("fill", metrics.trackX, metrics.trackY,
        metrics.trackWidth, metrics.trackHeight, radius, radius)

    love.graphics.setColor(Theme:color(active and "scrollThumbActive" or "scrollThumb"):unpacked())
    love.graphics.rectangle("fill", metrics.trackX, metrics.thumbY,
        metrics.trackWidth, metrics.thumbHeight, radius, radius)

    love.graphics.setColor(r, g, b, a)
end

return ScrollBar
