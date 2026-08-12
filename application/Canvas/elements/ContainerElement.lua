local Theme = require "application.Style.Theme"
local PanelElement = require "application.Canvas.elements.PanelElement"
local ContainerLayout = require "application.Canvas.ContainerLayout"
local SetProps = require "application.Canvas.commands.SetProps"

-- A panel that holds other elements and decides how big they are.
--
-- Derived from PanelElement in the only sense this codebase has one: the frame, the
-- header-as-drag-handle, the editable title and the resize zones are PanelElement's,
-- reused through drawFrame/textFields/hitTestHandle, and what's added here is the
-- content tree. Anything panel-shaped can go in one, this type included --
-- containers nest.
--
-- **Children are ordinary elements in the document, referenced by id.** They aren't
-- nested inside this element's props, which is what keeps selection, deletion, undo,
-- inline text editing and the save format working on them unchanged -- a child is
-- just an element that something else happens to position. What lives in props is
-- the arrangement: `props.layout`, a recursive split tree (see ContainerLayout).
--
-- Their geometry is *derived*: Containment.layoutAll writes each child's rect from
-- this element's rect every frame, so moving or resizing a container moves and
-- resizes everything in it, and nothing has to be kept in sync by hand. That's also
-- why a cell naming an element that no longer exists is harmless -- it simply
-- doesn't get laid out, and undoing the delete brings it back in the same slot.
--
-- The tree math -- weights, minimums, insertion, removal -- is ContainerLayout.
local ContainerElement = { name = "container" }

-- Between the container's frame and its contents, and between neighbouring cells.
-- The padding is deliberately wider than RectResize's grab margin, so the
-- container's own resize zone stays reachable around the outside of its children.
local PADDING = 10
local GAP = 8
-- Published so CellResizeGesture's own minSize calls (on subtrees it's considering
-- trading space between, not the whole container) use the same spacing this file's
-- own layout math does.
ContainerElement.GAP = GAP

-- How close to the container's own outer edge a drop has to land to span the whole
-- content rect (see dropTarget) rather than nest beside whatever's under the
-- pointer. World units, not screen pixels: it's about how generous the layout's own
-- targets are, not a precise handle -- consistent with PADDING/GAP being plain world
-- constants rather than zoom-scaled ones.
local OUTER_ZONE = 32

local DEFAULT_WIDTH = 520
local DEFAULT_HEIGHT = 360
-- What an *empty* container can be shrunk to. Once it holds anything, minSizeFor
-- takes over and the answer is whatever the contents need.
local MIN_WIDTH = 220
local MIN_HEIGHT = PanelElement.getHeaderHeight() + PADDING * 2 + 80

-- A darker body than a plain panel's, so the children sitting on it read as raised
-- tiles on a tray rather than as one continuous surface.
local STYLE = PanelElement.newStyle("containerSurface", "containerHeader", "containerBorder")

local EMPTY_HINT = "Drag elements here"

function ContainerElement.defaultSize()
    return DEFAULT_WIDTH, DEFAULT_HEIGHT
end

function ContainerElement.defaultProps()
    return { title = "Container" }
end

function ContainerElement.minSize()
    return MIN_WIDTH, MIN_HEIGHT
end

-- Where the children go: everything below the header, inset by the padding.
function ContainerElement.contentRect(element)
    local header = PanelElement.getHeaderHeight()
    return element.x + PADDING,
        element.y + header + PADDING,
        math.max(0, element.width - PADDING * 2),
        math.max(0, element.height - header - PADDING * 2)
end

local function layoutOf(element, document)
    local x, y, width, height = ContainerElement.contentRect(element)
    return ContainerLayout.compute(element.props.layout, document, x, y, width, height, GAP)
end

-- Published for the cell resize gesture, which drags the edges between the nodes
-- this describes.
ContainerElement.contentLayout = layoutOf

-- The title bar and the resize edges behave exactly as a panel's, and the body is a
-- click target like any other element's -- the children on top of it take their own
-- clicks first, since they're in front of it in the document.
ContainerElement.hitTestHandle = PanelElement.hitTestHandle
ContainerElement.textFields = PanelElement.textFields

-- ── Containment ──────────────────────────────────────────────────────────

function ContainerElement.childIds(element)
    return element.props.layout and ContainerLayout.leafIds(element.props.layout) or {}
end

-- Guards against a container that (through a hand-edited file) ends up inside
-- itself: measuring it would otherwise recurse until the stack ran out.
local measuring = {}

function ContainerElement.minSizeFor(element, document)
    if measuring[element.id] or not element.props.layout then
        return MIN_WIDTH, MIN_HEIGHT
    end
    measuring[element.id] = true

    local contentWidth, contentHeight = ContainerLayout.minSize(element.props.layout, document, GAP)

    measuring[element.id] = nil

    return math.max(MIN_WIDTH, contentWidth + PADDING * 2),
        math.max(MIN_HEIGHT, contentHeight + PanelElement.getHeaderHeight() + PADDING * 2)
end

local function writeRects(resolved)
    if resolved.children then
        for _, child in ipairs(resolved.children) do
            writeRects(child)
        end
    else
        resolved.element.x, resolved.element.y = resolved.x, resolved.y
        resolved.element.width, resolved.element.height = resolved.width, resolved.height
    end
end

function ContainerElement.layoutChildren(element, document)
    local layout = layoutOf(element, document)
    if layout.root then
        writeRects(layout.root)
    end
end

-- Nothing below trusts what a file put in props until this has run over it; see
-- ContainerLayout.sanitize for what survives.
function ContainerElement.normalizeProps(element)
    element.props.layout = ContainerLayout.sanitize(element.props.layout)
end

function ContainerElement.withChild(element, drop, childId)
    return { layout = ContainerLayout.insert(element.props.layout, drop, childId) }
end

function ContainerElement.withoutChild(element, childId)
    if not element.props.layout then
        return nil
    end

    local present = false
    for _, id in ipairs(ContainerLayout.leafIds(element.props.layout)) do
        present = present or id == childId
    end
    if not present then
        return nil
    end

    -- NONE rather than nil: a Lua table can't hold nil, so that's how SetProps says
    -- "this key goes away" -- which is what an emptied container's `layout` does.
    return { layout = ContainerLayout.remove(element.props.layout, childId) or SetProps.NONE }
end

-- Paste mints new ids, so a pasted container's tree has to be pointed at the pasted
-- children rather than at the originals they were copied from. Leaves naming
-- something that didn't come along are dropped -- copying a container on its own
-- yields an empty one rather than one claiming somebody else's children.
function ContainerElement.remapIds(element, idMap)
    element.props.layout = element.props.layout and ContainerLayout.remapIds(element.props.layout, idMap) or nil
end

-- ── Drop targeting ───────────────────────────────────────────────────────
--
-- Two scopes, picked by how close the pointer is to which rect:
--
-- **Near the container's own outer edge** (within OUTER_ZONE of the whole content
-- rect) targets the *root* -- the drop spans the entire content area along the axis
-- it entered from, growing or replacing the whole tree. This is what makes "spans
-- the whole column" reachable at all: it's ContainerLayout.insert's atRoot path,
-- exactly the operation that already makes the first row-vs-column choice when a
-- second element joins an empty container, just aimed at an outer edge instead.
--
-- **Anywhere else** targets whichever leaf the pointer is nearest, recursively --
-- at each split, the child nearest along *that split's own axis* (row: x, column: y)
-- is the one to descend into, which is exactly how a container with only rows always
-- resolved to "the nearest row, then the nearest cell in it" before, just no longer
-- capped at two levels. The nearest of *that* leaf's four edges (as a fraction of its
-- own rect, so a wide short leaf doesn't answer "above" everywhere, and negative
-- outside it so the gaps and padding resolve to whichever side the pointer left
-- through) decides whether the new element joins its row/column or gets nested
-- beside it in the other direction.

local function outerEdge(layout, x, y)
    local left, right = x - layout.x, (layout.x + layout.width) - x
    local top, bottom = y - layout.y, (layout.y + layout.height) - y
    local nearest = math.min(left, right, top, bottom)
    if nearest > OUTER_ZONE then
        return nil
    end

    -- Ties (a corner, or a container too small to tell) favour column: an empty or
    -- near-empty container's first outer split is a row stacking downward, matching
    -- what dropping into an empty one has always produced.
    if nearest == top or nearest == bottom then
        return "column", nearest == top
    end
    return "row", nearest == left
end

local function nearestChild(node, x, y)
    local best, bestDistance
    for _, child in ipairs(node.children) do
        local distance = node.direction == "row"
            and math.max(child.x - x, x - (child.x + child.width))
            or math.max(child.y - y, y - (child.y + child.height))
        if not best or distance < bestDistance then
            best, bestDistance = child, distance
        end
    end
    return best
end

local function nearestLeaf(node, x, y)
    if not node.children then
        return node
    end
    return nearestLeaf(nearestChild(node, x, y), x, y)
end

local function nearestLeafEdge(leaf, x, y)
    local width = math.max(leaf.width, 1)
    local height = math.max(leaf.height, 1)
    local left = (x - leaf.x) / width
    local right = ((leaf.x + leaf.width) - x) / width
    local top = (y - leaf.y) / height
    local bottom = ((leaf.y + leaf.height) - y) / height
    local nearest = math.min(left, right, top, bottom)

    if nearest == top then return "column", true end
    if nearest == bottom then return "column", false end
    if nearest == left then return "row", true end
    return "row", false
end

-- The preview rect for an outer-edge (root-scope) drop: a band along the edge it was
-- triggered from, sized to read clearly without claiming to know the exact share the
-- weight math will end up giving it.
local function outerPreview(layout, direction, before)
    if direction == "row" then
        local width = math.min(layout.width * 0.35, 200)
        return { x = before and layout.x or layout.x + layout.width - width,
            y = layout.y, width = width, height = layout.height }
    end
    local height = math.min(layout.height * 0.35, 200)
    return { x = layout.x, y = before and layout.y or layout.y + layout.height - height,
        width = layout.width, height = height }
end

local function leafPreview(leaf, direction, before)
    if direction == "row" then
        local width = leaf.width / 2
        return { x = before and leaf.x or leaf.x + leaf.width - width,
            y = leaf.y, width = width, height = leaf.height }
    end
    local height = leaf.height / 2
    return { x = leaf.x, y = before and leaf.y or leaf.y + leaf.height - height,
        width = leaf.width, height = height }
end

function ContainerElement.dropTarget(element, x, y, document)
    local layout = layoutOf(element, document)

    if not layout.root then
        return { atRoot = true, direction = "column", before = true,
            x = layout.x, y = layout.y, width = layout.width, height = layout.height }
    end

    local direction, before = outerEdge(layout, x, y)
    if direction then
        local preview = outerPreview(layout, direction, before)
        preview.atRoot, preview.direction, preview.before = true, direction, before
        return preview
    end

    local leaf = nearestLeaf(layout.root, x, y)
    direction, before = nearestLeafEdge(leaf, x, y)
    local preview = leafPreview(leaf, direction, before)
    preview.targetId, preview.direction, preview.before = leaf.id, direction, before
    return preview
end

-- ── Drawing ──────────────────────────────────────────────────────────────

function ContainerElement.draw(element, context)
    PanelElement.drawFrame(element, context, STYLE)

    -- The children draw themselves -- they're elements in the document, drawn in
    -- front of this one. All that's left is telling an empty container apart from a
    -- panel somebody hasn't written in yet. Measured off the live layout rather than
    -- off the tree, so a container whose contents have all been deleted says so too.
    local document = context.document
    if not document then
        return
    end

    local layout = layoutOf(element, document)
    if layout.root then
        return
    end

    local x, y, width, height = layout.x, layout.y, layout.width, layout.height
    local r, g, b, a = love.graphics.getColor()
    local font = Theme:font("small")
    local previousFont = love.graphics.getFont()

    love.graphics.setFont(font)
    love.graphics.setColor(Theme:color("muted"):unpacked())
    love.graphics.printf(EMPTY_HINT, x, y + (height - font:getHeight()) / 2, width, "center")

    love.graphics.setFont(previousFont)
    love.graphics.setColor(r, g, b, a)
end

return ContainerElement
