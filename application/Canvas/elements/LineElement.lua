local Theme = require "application.Style.Theme"
local Element = require "application.Canvas.Element"

-- A connector between two other elements -- not a PanelElement derivative, since it
-- has no body, no header, and doesn't own its own geometry the way a rectangle does:
-- its endpoints are wherever its two elements currently are.
--
-- **What's stored is relative, not absolute**: which two elements it connects
-- (`fromId`/`toId`) and, for each, which side of that element's rect the line meets
-- and how far along that side (`fromSide`/`fromT`, `toSide`/`toT`, `t` in [0, 1]).
-- That's what survives a resize or a drag -- the same reasoning as a container's
-- children being weights rather than pixels (see CLAUDE.md's "Containers"): a fixed
-- world point would drift off the panel the moment it moved, where a side+fraction
-- doesn't.
--
-- **The endpoints themselves are derived, not stored-and-synced**, the same rule
-- Containment.layoutAll applies to a child's rect: ElementRegistry:updateGeometry
-- (dispatched from Board:update, after Containment's own pass so a panel inside a
-- container has already been moved this frame) reads the live rects of the two
-- connected elements and writes the resolved endpoints and bounding box directly onto
-- this element -- the same place ContainerElement writes a child's rect. `fromX/fromY`
-- and `toX/toY` are plain fields on the element, not props: they're never meant to be
-- saved, only ever recomputed, and Element:toData() only ever looks at id/type/x/y/
-- width/height/props, so they ride along for free without polluting a save.
-- ownSelectionColor: Board:drawSelectionOutlines skips the generic bounding-box
-- outline for this type, since LineElement.draw already shows selection by
-- recoloring the stroke itself.
local LineElement = { name = "line", ownSelectionColor = true }

local LINE_WIDTH = 3   -- screen pixels
local ANCHOR_RADIUS = 5 -- screen pixels

-- World units. ElementRegistry:hitTest has no zoom parameter (unlike hitTestHandle),
-- so this can't be held to a constant size on screen the way a resize handle's grab
-- zone is -- it's a flat tolerance, generous enough to click comfortably at the zoom
-- levels a board is actually read at.
local HIT_TOLERANCE = 6

local VALID_SIDES = { top = true, right = true, bottom = true, left = true }

local function clamp01(value)
    return math.max(0, math.min(1, value))
end

-- The world point on `rect`'s perimeter for a given side and fraction along it.
local function perimeterPoint(rect, side, t)
    if side == "top" then
        return rect.x + t * rect.width, rect.y
    elseif side == "bottom" then
        return rect.x + t * rect.width, rect.y + rect.height
    elseif side == "left" then
        return rect.x, rect.y + t * rect.height
    else -- "right"
        return rect.x + rect.width, rect.y + t * rect.height
    end
end

-- The side+fraction on `rect`'s perimeter that a line from its center toward
-- (towardX, towardY) would cross -- i.e. where the connector visibly leaves the
-- panel it's attached to, aimed at whatever it currently connects to (or, mid-drag,
-- at the pointer). Standard center-to-point/rect-boundary intersection: the smaller
-- of how far the ray can travel along each axis before it leaves the rect decides
-- which pair of sides it exits through.
local function nearestAnchor(rect, towardX, towardY)
    local cx, cy = rect.x + rect.width / 2, rect.y + rect.height / 2
    local dx, dy = towardX - cx, towardY - cy

    if dx == 0 and dy == 0 then
        return "bottom", 0.5
    end

    local halfWidth, halfHeight = rect.width / 2, rect.height / 2
    local tx = dx ~= 0 and halfWidth / math.abs(dx) or math.huge
    local ty = dy ~= 0 and halfHeight / math.abs(dy) or math.huge

    if tx <= ty then
        local iy = cy + dy * tx
        return dx >= 0 and "right" or "left", clamp01((iy - rect.y) / rect.height)
    end

    local ix = cx + dx * ty
    return dy >= 0 and "bottom" or "top", clamp01((ix - rect.x) / rect.width)
end

function LineElement.defaultSize()
    return 0, 0
end

function LineElement.defaultProps()
    return { fromId = nil, toId = nil }
end

-- Not resizable or movable by hand -- its geometry is entirely a function of the two
-- elements it connects, recomputed every frame by updateGeometry. hitTestHandle is
-- deliberately left unimplemented (ElementRegistry's default is nil, "no handle
-- here"), which is what makes a click on a line select it instead of starting a move.

function LineElement.hitTest(element, x, y)
    if not element.fromX then
        return false
    end

    local dx, dy = element.toX - element.fromX, element.toY - element.fromY
    local lengthSquared = dx * dx + dy * dy
    local nearX, nearY
    if lengthSquared == 0 then
        nearX, nearY = element.fromX, element.fromY
    else
        local t = clamp01(((x - element.fromX) * dx + (y - element.fromY) * dy) / lengthSquared)
        nearX, nearY = element.fromX + t * dx, element.fromY + t * dy
    end

    local distX, distY = x - nearX, y - nearY
    return distX * distX + distY * distY <= HIT_TOLERANCE * HIT_TOLERANCE
end

-- Repairs whatever a file put in props, the same "drop what can't be trusted rather
-- than refuse the whole board" rule ContainerElement.normalizeProps follows for its
-- own structured prop. fromId/toId are left alone even if they don't currently
-- resolve to a live element -- updateGeometry already treats that as "nothing to draw
-- this frame" rather than an error, and undo can bring the missing element back.
function LineElement.normalizeProps(element)
    local props = element.props
    if type(props.fromId) ~= "string" then props.fromId = nil end
    if type(props.toId) ~= "string" then props.toId = nil end
    if not VALID_SIDES[props.fromSide] then props.fromSide = "top" end
    if not VALID_SIDES[props.toSide] then props.toSide = "top" end
    props.fromT = clamp01(tonumber(props.fromT) or 0.5)
    props.toT = clamp01(tonumber(props.toT) or 0.5)
end

-- A pasted line whose connected elements were copied in the same paste should point
-- at the copies, not the originals -- the same reasoning ContainerElement.remapIds
-- follows for a container's children. An id outside the map refers to something that
-- wasn't copied along, and is left pointing at the original.
function LineElement.remapIds(element, idMap)
    local props = element.props
    if props.fromId and idMap[props.fromId] then
        props.fromId = idMap[props.fromId]
    end
    if props.toId and idMap[props.toId] then
        props.toId = idMap[props.toId]
    end
end

-- The other elements this one's identity depends on: without both, a connector means
-- nothing. Dispatched generically from Board:deleteSelection, the same way a
-- container's children are dispatched into a delete via childIds -- so deleting
-- either panel this line joins takes the line with it instead of leaving it dangling.
function LineElement.dependsOn(element)
    local ids = {}
    if element.props.fromId then ids[#ids + 1] = element.props.fromId end
    if element.props.toId then ids[#ids + 1] = element.props.toId end
    return ids
end

-- Recomputes the endpoints and bounding box from the two connected elements' current
-- rects. Run once a frame from Board:update (see ElementRegistry:updateGeometry),
-- after Containment.layoutAll so a connected element that's itself laid out by a
-- container has already moved this frame. Left untouched -- at whatever rect it last
-- had -- when either connected element is missing, which is only ever true for the
-- single frame between an undo removing one and Board:pruneSelection/the cascading
-- delete in deleteSelection catching up.
function LineElement.updateGeometry(element, document)
    local props = element.props
    local from = props.fromId and document:getById(props.fromId)
    local to = props.toId and document:getById(props.toId)
    if not (from and to) then
        return
    end

    local fromX, fromY = perimeterPoint(from, props.fromSide, props.fromT)
    local toX, toY = perimeterPoint(to, props.toSide, props.toT)

    element.fromX, element.fromY = fromX, fromY
    element.toX, element.toY = toX, toY
    element.x, element.y = math.min(fromX, toX), math.min(fromY, toY)
    element.width, element.height = math.abs(toX - fromX), math.abs(toY - fromY)
end

-- Builds the real element once a drag has landed on a valid second element: picks
-- each side's anchor by aiming at the other element's center, then fills in the
-- derived fields immediately rather than waiting for the next updateGeometry pass --
-- the gesture that calls this needs a fully-formed element to hand to AddElement
-- before that pass has run.
function LineElement.connect(fromElement, toElement)
    local fromCenterX = fromElement.x + fromElement.width / 2
    local fromCenterY = fromElement.y + fromElement.height / 2
    local toCenterX = toElement.x + toElement.width / 2
    local toCenterY = toElement.y + toElement.height / 2

    local fromSide, fromT = nearestAnchor(fromElement, toCenterX, toCenterY)
    local toSide, toT = nearestAnchor(toElement, fromCenterX, fromCenterY)

    local element = Element.new("line", 0, 0, 0, 0, {
        fromId = fromElement.id,
        toId = toElement.id,
        fromSide = fromSide,
        fromT = fromT,
        toSide = toSide,
        toT = toT,
    })

    local fromX, fromY = perimeterPoint(fromElement, fromSide, fromT)
    local toX, toY = perimeterPoint(toElement, toSide, toT)
    element.fromX, element.fromY = fromX, fromY
    element.toX, element.toY = toX, toY
    element.x, element.y = math.min(fromX, toX), math.min(fromY, toY)
    element.width, element.height = math.abs(toX - fromX), math.abs(toY - fromY)

    return element
end

-- The endpoints a line *would* have if it connected these two elements right now --
-- used by LineGesture to preview a drag that's currently hovering a valid target,
-- without building a real element for it.
function LineElement.previewPoints(fromElement, toElement)
    local fromCenterX = fromElement.x + fromElement.width / 2
    local fromCenterY = fromElement.y + fromElement.height / 2
    local toCenterX = toElement.x + toElement.width / 2
    local toCenterY = toElement.y + toElement.height / 2

    local fromSide, fromT = nearestAnchor(fromElement, toCenterX, toCenterY)
    local toSide, toT = nearestAnchor(toElement, fromCenterX, fromCenterY)

    local fromX, fromY = perimeterPoint(fromElement, fromSide, fromT)
    local toX, toY = perimeterPoint(toElement, toSide, toT)
    return fromX, fromY, toX, toY
end

-- Where a line dragging out of `element` and not yet over a second element should
-- currently end: the perimeter point aimed at the free end, so the preview leaves the
-- panel from the side it's actually being dragged toward rather than a fixed corner.
function LineElement.anchorPoint(element, towardX, towardY)
    local side, t = nearestAnchor(element, towardX, towardY)
    return perimeterPoint(element, side, t)
end

-- The stroke and its two endpoint circles, in world coordinates. Shared between the
-- real element's draw and LineGesture's preview so the two can't drift apart --
-- `color` and `zoom` are passed in rather than resolved here, since the preview draws
-- under Theme:pushOpacity and a fixed "unselected" color, neither of which apply to
-- the real element the same way.
function LineElement.drawSegment(fromX, fromY, toX, toY, color, zoom)
    local r, g, b, a = love.graphics.getColor()
    local previousLineWidth = love.graphics.getLineWidth()

    love.graphics.setColor(color:unpacked())
    love.graphics.setLineWidth(LINE_WIDTH / zoom)
    love.graphics.line(fromX, fromY, toX, toY)

    local radius = ANCHOR_RADIUS / zoom
    love.graphics.circle("fill", fromX, fromY, radius)
    love.graphics.circle("fill", toX, toY, radius)

    love.graphics.setLineWidth(previousLineWidth)
    love.graphics.setColor(r, g, b, a)
end

-- Nothing to draw until updateGeometry has run at least once (the single frame
-- between AddElement and the next Board:update, or a connected element that's since
-- gone missing -- see updateGeometry).
function LineElement.draw(element, context)
    if not element.fromX then
        return
    end

    local selected = context.selection ~= nil and context.selection:contains(element.id)
    local color = Theme:color(selected and "lineSelected" or "line")
    LineElement.drawSegment(element.fromX, element.fromY, element.toX, element.toY, color, context.zoom)
end

return LineElement
