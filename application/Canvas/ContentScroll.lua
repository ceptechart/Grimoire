local ScrollBar = require "application.Style.ScrollBar"
local ElementRegistry = require "application.Canvas.ElementRegistry"

-- How far an element's content is scrolled inside it, and the scrollbar that shows
-- and drags that.
--
-- Generic, like Containment: an element type says how tall its content is and where
-- the window onto it sits (`scrollView`, dispatched through ElementRegistry), and
-- everything else -- clamping, the wheel step, which element is being dragged -- is
-- solved once here. A type that scrolls implements one function and offsets its own
-- drawing by `offsetOf`; it never computes a thumb.
--
-- The bar's own geometry and drawing is application/Style/ScrollBar.lua, shared with
-- the inline text editor, which scrolls the same way off state this module knows
-- nothing about. What lives *here* is everything that's about elements: where the
-- offsets are kept, how the registry is asked, and what the wheel means.
--
-- **The offset is view state, not content.** It lives in a table keyed by element id
-- rather than in `element.props`, for exactly the reason Selection isn't part of
-- Document: scrolling isn't an edit. It must not land on the undo stack, must not
-- mark the board dirty, and must not be in the save file -- a `.grimoire` diff should
-- show what someone changed, not where they happened to have scrolled to.
--
-- **The bar overlays the content rather than narrowing it.** Reserving a gutter
-- would make the content's width depend on whether a bar is showing, which depends
-- on the content's height, which depends on its width -- circular, and it would make
-- a document flicker between one and two states at the exact height where the bar
-- appears. Drawing over the content costs a few pixels of the right margin and has
-- no such loop in it.
local ContentScroll = {}

-- One wheel notch, in world units. Roughly three lines of body text, which is what a
-- notch means everywhere else.
local WHEEL_STEP = 48

-- Offsets are cheap to lose (it's a scroll position, not content) and would
-- otherwise accumulate one entry per element id ever seen -- ids that a delete, an
-- undo or a paste mints and discards freely. Dropped wholesale past a bound, the
-- same treatment MarkdownElement gives its layout cache.
local LIMIT = 256

local offsets = {}
local stored = 0

-- The id of the element whose thumb is currently being dragged, if any. Reported by
-- ScrollGesture rather than inferred, since Board doesn't branch on gesture kind.
local dragging

-- ── Geometry ─────────────────────────────────────────────────────────────

-- The bar for one element, or nil if it can't scroll -- either its type doesn't
-- implement scrollView, or its content fits.
--
-- Recomputed on demand rather than cached: the callers that ask per frame are asking
-- about an element whose content layout is itself already cached, and a stored copy
-- of this would go stale on every resize, edit and undo.
--
-- ScrollBar clamps the offset it's given, and the clamped value is written back --
-- content gets shorter without anything scrolling (an edit, a resize, an undo), and
-- an offset that was valid a frame ago has to come back into range on its own.
function ContentScroll.metricsOf(element)
    local x, y, width, height, contentHeight = ElementRegistry:scrollView(element)
    if not x then
        return nil
    end

    local metrics = ScrollBar.metrics(x, y, width, height, contentHeight, offsets[element.id])
    if not metrics then
        return nil
    end

    offsets[element.id] = metrics.offset
    return metrics
end

-- The offset an element's content should be drawn at. Zero for anything that isn't
-- scrolled or can't be, so a type can subtract it unconditionally.
function ContentScroll.offsetOf(element)
    local metrics = ContentScroll.metricsOf(element)
    return metrics and metrics.offset or 0
end

function ContentScroll.setOffset(element, value)
    if offsets[element.id] == nil then
        if stored >= LIMIT then
            offsets, stored = {}, 0
        end
        stored = stored + 1
    end
    offsets[element.id] = value
end

-- ── Interaction ──────────────────────────────────────────────────────────

-- Returns whether the element claims the wheel, which is what decides whether it
-- goes on to zoom the canvas.
--
-- **An element showing a scrollbar keeps the wheel even when it's already at the
-- end the wheel is pushing toward.** Falling through there would mean that running
-- out of note under the pointer turned the same gesture into a canvas zoom -- a
-- lurch, and one you'd hit constantly, since reaching the end of a scroll is an
-- ordinary thing to do rather than an error. Only an element with no bar at all --
-- a type that doesn't scroll, or content that fits -- lets the wheel past.
function ContentScroll.wheel(element, direction)
    local metrics = ContentScroll.metricsOf(element)
    if not metrics then
        return false
    end

    ContentScroll.setOffset(element,
        math.max(0, math.min(metrics.offset - direction * WHEEL_STEP, metrics.maxOffset)))
    return true
end

-- Where a press on the scrollbar landed, or nil for a point that isn't on it. The
-- second return is the grab offset a drag has to preserve; a press on the bare track
-- centres the thumb there first, so both are one gesture (see ScrollBar.grabFor).
function ContentScroll.pressAt(element, x, y)
    local metrics = ContentScroll.metricsOf(element)
    if not ScrollBar.containsPoint(metrics, x, y) then
        return nil
    end

    local grab = ScrollBar.grabFor(metrics, y)
    ContentScroll.setOffset(element, ScrollBar.offsetFor(metrics, y, grab))
    return metrics, grab
end

-- Puts the thumb where a drag has dragged it: `y` is the pointer, `grab` the offset
-- into the thumb the press started at.
function ContentScroll.dragTo(element, y, grab)
    local metrics = ContentScroll.metricsOf(element)
    if metrics then
        ContentScroll.setOffset(element, ScrollBar.offsetFor(metrics, y, grab))
    end
end

-- Set by ScrollGesture for the life of a thumb drag, purely so the thumb can draw
-- itself lit while it's being held.
function ContentScroll.setDragging(id)
    dragging = id
end

-- ── Drawing ──────────────────────────────────────────────────────────────

-- Drawn over the content, after it and outside its clip. No-op for an element with
-- nothing to scroll, so a type calls this unconditionally.
--
-- Whether the thumb is lit is read from here rather than passed in: Board
-- deliberately doesn't branch on which gesture is in flight (see Gesture.lua), so
-- the gesture reports itself to this module instead and element types stay unaware
-- that a drag is a thing that can be happening.
function ContentScroll.draw(element, context)
    ScrollBar.draw(ContentScroll.metricsOf(element), dragging == element.id)
end

return ContentScroll
