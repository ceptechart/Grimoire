-- End-to-end pass over the board: every pointer gesture, undo/redo of each, the
-- Actions verbs, and a save/load round trip. Run with `love . test` (or
-- `lovec . test` for console output on Windows).
--
-- Screen coordinates below assume the 1280x720 default window from conf.lua and the
-- three seeded panels, which at startup sit at world (-320,-80), (-40,-80), (240,-80)
-- with the canvas centred and unzoomed -- so panel 1 covers screen x 320..560,
-- y 280..440, and its header is the top 28 pixels of that.
local t = require "tests.runner"

local Board = require "application.Canvas.Board"
local Canvas = require "application.Canvas.Canvas"
local Tools = require "application.Canvas.Tools"
local Actions = require "application.Actions"
local Document = require "application.Canvas.Document"
local Selection = require "application.Canvas.Selection"
local Serialize = require "lib.util.Serialize"
local BoardFile = require "application.BoardFile"
local TextEditSession = require "application.Text.TextEditSession"
local ElementRegistry = require "application.Canvas.ElementRegistry"
local ContainerLayout = require "application.Canvas.ContainerLayout"
local Containment = require "application.Canvas.Containment"
local RemoveElements = require "application.Canvas.commands.RemoveElements"

local steps = {}

-- Captured in the first step and asserted against after every undo: the whole command
-- design rests on a gesture's undo restoring position *and* depth exactly.
local startOrder
local firstId

steps[#steps + 1] = function()
    local document = Board:getDocument()
    t.eq("seed: 3 elements", document:count(), 3)
    t.eq("seed: nothing selected", Board:getSelection():count(), 0)
    t.eq("seed: undo stack empty", Actions.canUndo(), false)

    startOrder = t.orderOf(document)
    firstId = document.elements[1].id
end

-- RemoveElements has to reinsert in reverse removal order. Forwards, a multi-delete
-- undo lands elements at the wrong depth, and when a high index was removed first it
-- writes past the end of a now-shorter array and leaves a hole in it.
--
-- Run against a scratch document rather than the board's, because the id order that
-- triggers it is the arbitrary one a hash set used to hand over.
steps[#steps + 1] = function()
    local document = Document.new()
    for index = 1, 4 do
        local element = ElementRegistry:create("panel", index * 10, 0)
        element.props.title = "P" .. index
        document:insert(element)
    end

    local before = t.orderOf(document)
    local first, third, fourth =
        document.elements[1].id, document.elements[3].id, document.elements[4].id

    document:execute(RemoveElements.new({ fourth, first, third }))
    t.eq("RemoveElements: 3 of 4 removed", document:count(), 1)

    document:undo()
    t.eq("RemoveElements: count restored", document:count(), 4)
    t.eq("RemoveElements: z-order restored exactly", t.orderOf(document), before)

    local walked = 0
    for _ in ipairs(document.elements) do walked = walked + 1 end
    t.eq("RemoveElements: no hole left in the array", walked, 4)
end

steps[#steps + 1] = function()
    t.drag(200, 500, 1150, 250)
    t.eq("marquee: selected everything it touched", Board:getSelection():count(), 3)
end

steps[#steps + 1] = function()
    t.key("delete")
    t.eq("delete: board emptied", Board:getDocument():count(), 0)
    t.eq("delete: selection cleared", Board:getSelection():count(), 0)
end

steps[#steps + 1] = function()
    Actions.undo()
    local document = Board:getDocument()
    t.eq("undo delete: count restored", document:count(), 3)
    t.eq("undo delete: original z-order", t.orderOf(document), startOrder)
end

-- A header drag moves the element and raises it; one Ctrl+Z has to undo both.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local element = document:getById(firstId)
    local x0, y0 = element.x, element.y
    t.eq("move: element starts at the back", document:indexOf(firstId), 1)

    t.drag(400, 290, 450, 340)

    t.near("move: dx applied", element.x - x0, 50)
    t.near("move: dy applied", element.y - y0, 50)
    t.eq("move: raised to the front", document:indexOf(firstId), 3)

    Actions.undo()
    t.near("move undo: x restored", element.x, x0)
    t.near("move undo: y restored", element.y, y0)
    t.eq("move undo: z-order restored too", t.orderOf(document), startOrder)
end

steps[#steps + 1] = function()
    local document = Board:getDocument()
    local element = document:getById(firstId)
    local width = element.width

    -- Grab panel 1's east edge and pull it right.
    t.drag(560, 380, 640, 380)
    t.near("resize: width grew by the drag", element.width - width, 80)

    Actions.undo()
    t.near("resize undo: width restored", element.width, width)
    t.eq("resize undo: z-order restored", t.orderOf(document), startOrder)
end

steps[#steps + 1] = function()
    local document = Board:getDocument()
    Tools:setActive("panel")
    t.drag(700, 480, 900, 620)

    t.eq("create: element added", document:count(), 4)
    local made = document.elements[4]
    t.near("create: width follows the drag", made.width, 200)
    t.near("create: height follows the drag", made.height, 140)
    t.eq("create: new element is selected", Board:getSelection():contains(made.id), true)

    Actions.undo()
    t.eq("create undo: removed again", document:count(), 3)
end

-- A press and release with no travel is a click, and yields the type's default size
-- rather than a zero-sized element.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    t.press(700, 500)
    t.release(700, 500)

    t.eq("create click: element added", document:count(), 4)
    t.near("create click: default width", document.elements[4].width, 240)
    t.near("create click: default height", document.elements[4].height, 160)
    t.eq("create click: selection follows it", Board:getSelection():count(), 1)

    Actions.undo()
    -- Pruning runs in Board:update, so the stale id survives until the next frame.
    Board:update(0)
    t.eq("create undo: stale id pruned from the selection", Board:getSelection():count(), 0)
end

-- Escape backs out one step at a time, and only claims the key when it did something.
steps[#steps + 1] = function()
    t.eq("escape: leaves the create tool", t.key("escape"), true)
    t.eq("escape: back to select", Tools:isActive(Tools.SELECT), true)

    Actions.selectAll()
    t.eq("select all", Board:getSelection():count(), 3)

    t.eq("escape: consumed while there's a selection", t.key("escape"), true)
    t.eq("escape: selection cleared", Board:getSelection():count(), 0)
    t.eq("escape: not consumed with nothing left to back out of", t.key("escape"), false)
end

-- Copy leaves the document alone; paste mints a fresh id and lands the copied
-- group's top-left corner under the pointer -- the same real-cursor
-- `love.mouse.getPosition()` read `Canvas:wheelmoved` already relies on for
-- zoom-at-cursor, so the target has to be set on the real window rather than
-- dispatched like the other synthetic input in this file.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local selection = Board:getSelection()
    local original = document:getById(firstId)
    local title = original.props.title
    local x0, y0 = original.x, original.y

    selection:set(firstId)
    t.eq("copy: reports success", Actions.copy(), true)
    t.eq("copy: document unchanged", document:count(), 3)

    local targetX, targetY = x0 + 500, y0 + 40
    love.mouse.setPosition(Canvas:worldToScreenX(targetX), Canvas:worldToScreenY(targetY))

    t.eq("paste: reports success", Actions.paste(), true)
    t.eq("paste: one element added", document:count(), 4)

    local pasted = document.elements[4]
    t.check("paste: minted a new id", pasted.id ~= firstId, pasted.id)
    t.near("paste: x lands under the pointer", pasted.x, targetX)
    t.near("paste: y lands under the pointer", pasted.y, targetY)
    t.eq("paste: props copied", pasted.props.title, title)
    t.eq("paste: pasted element is the whole selection", selection:count(), 1)
    t.eq("paste: pasted element is selected", selection:contains(pasted.id), true)

    Actions.undo()
    t.eq("paste undo: removes just the paste", document:count(), 3)
    t.eq("paste undo: original z-order intact", t.orderOf(document), startOrder)
end

-- Cut is copy-then-delete, so it's two independent undo steps -- undoing once only
-- reverses the paste that followed it.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local selection = Board:getSelection()

    selection:clear()
    for _, id in ipairs(document:allIds()) do
        selection:add(id)
    end

    t.eq("cut: reports success", Actions.cut(), true)
    t.eq("cut: removed the whole selection", document:count(), 0)

    love.mouse.setPosition(Canvas:worldToScreenX(0), Canvas:worldToScreenY(0))
    t.eq("paste after cut: reports success", Actions.paste(), true)
    t.eq("paste after cut: all 3 came back", document:count(), 3)

    Actions.undo()
    t.eq("paste after cut, undo: back to nothing", document:count(), 0)
    Actions.undo()
    t.eq("cut undo: originals restored", document:count(), 3)
    t.eq("cut undo: original z-order", t.orderOf(document), startOrder)
end

-- ── Containers ───────────────────────────────────────────────────────────
--
-- The three seeded panels are the content: each one is dragged into the container by
-- its header, which is the same door a user goes through. Screen coordinates are
-- computed from world ones rather than written out, since a container's contents move
-- as its tree changes and a literal would only be right until the drop above it did.
--
-- Container: world (-250, 100) to (250, 300), clear of the seeded panels above it.
-- Its content rect is inset by the 28px header and 10px of padding, so children live
-- in world x -240..240, y 138 down. A drop within 32 world units of that content
-- rect's own edge targets the whole tree (see ContainerElement's OUTER_ZONE); a lone
-- child that fills the container is, by construction, that close to every edge, so
-- the first two drops below exercise the outer-edge path without needing to aim for
-- it deliberately -- only once there's more than one row does "near a child's edge"
-- and "near the container's edge" stop being the same point.

local containerId
local seededIds

local function screenX(x)
    return Canvas:worldToScreenX(x)
end

local function screenY(y)
    return Canvas:worldToScreenY(y)
end

local function container()
    return Board:getDocument():getById(containerId)
end

local function children()
    return ElementRegistry:childIds(container())
end

-- Presses on an element's title bar, which is its drag handle.
local function headerOf(element)
    return screenX(element.x + 20), screenY(element.y + 14)
end

steps[#steps + 1] = function()
    local document = Board:getDocument()
    seededIds = document:allIds()

    Tools:setActive("container")
    t.drag(screenX(-250), screenY(100), screenX(250), screenY(300))
    Tools:reset()

    t.eq("container: created", document:count(), 4)
    containerId = document.elements[4].id
    t.eq("container: is a container", document:getById(containerId).type, "container")
    t.eq("container: starts empty", #children(), 0)
end

-- Dropping onto an empty container: the tree is just the one leaf, and it fills the
-- whole content rect the container gives it.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local panel = document:getById(seededIds[1])
    local x0, y0, width0, height0 = panel.x, panel.y, panel.width, panel.height

    local pressX, pressY = headerOf(panel)
    t.drag(pressX, pressY, screenX(0), screenY(200))

    t.eq("drop: container took the panel", #children(), 1)
    t.eq("drop: it's the one that was dragged", children()[1], panel.id)
    t.near("drop: child x is the content rect's", panel.x, -240)
    t.near("drop: child y clears the header", panel.y, 138)
    t.near("drop: child fills the content width", panel.width, 480)
    t.near("drop: child fills the content height", panel.height, 152)

    Actions.undo()
    t.eq("drop undo: container is empty again", #children(), 0)
    t.near("drop undo: x restored", panel.x, x0)
    t.near("drop undo: y restored", panel.y, y0)
    t.near("drop undo: width restored", panel.width, width0)
    t.near("drop undo: height restored", panel.height, height0)

    Actions.redo()
    t.eq("drop redo: back in the container", #children(), 1)
    t.near("drop redo: laid out again", panel.width, 480)
end

-- Dropping near the lone child's right edge -- which, filling the whole container,
-- is also the container's own right edge -- puts the tree's root at direction "row":
-- two cells side by side, each half of what the one before it had. (This is the
-- outer-edge path; see the block comment above.)
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local first = document:getById(seededIds[1])
    local second = document:getById(seededIds[2])

    local pressX, pressY = headerOf(second)
    t.drag(pressX, pressY, screenX(first.x + first.width - 10), screenY(first.y + 70))

    t.eq("split: two cells in the row", #children(), 2)
    t.eq("split: dropped to the right of the first", children()[2], second.id)
    t.near("split: first cell is half the width", first.width, 236)
    t.near("split: second cell is half the width", second.width, 236)
    t.near("split: both are the row's height", second.height, first.height)
    t.near("split: they sit side by side", second.x, first.x + first.width + 8)
end

-- Dropping near the row's bottom edge -- again also the container's own, since the
-- one row still fills the full height -- wraps the tree's root into direction
-- "column": the row becomes the top half, the third panel the bottom half, and the
-- container grows to keep both above the minimum height a panel says it needs.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local first = document:getById(seededIds[1])
    local second = document:getById(seededIds[2])
    local third = document:getById(seededIds[3])
    local height0 = container().height

    local pressX, pressY = headerOf(third)
    t.drag(pressX, pressY, screenX(first.x + 60), screenY(first.y + first.height - 6))

    t.eq("new row: three children", #children(), 3)
    t.eq("new row: the third is last", children()[3], third.id)
    t.near("new row: it spans the content width", third.width, 480)
    t.near("new row: it sits below the first row", third.y, first.y + first.height + 8)
    t.near("new row: rows are at the panel minimum", first.height, 76)
    t.check("new row: the container grew to fit", container().height > height0, container().height)
    t.near("new row: it grew by exactly what was missing", container().height, 208)
    -- The cells kept their own width -- only the row's height changed -- since
    -- wrapping happens around the row as a whole, not inside it.
    t.near("new row: the top row's cells are untouched", first.width, 236)
    t.near("new row: the top row's cells are untouched", second.width, 236)
end

-- The feature this rework was for: an element spanning the *whole column*, the same
-- way the third panel above spans the whole row. Dropped near the container's own
-- outer right edge -- away from any single child's edge, now that there's more than
-- one row to be near instead -- it wraps the *entire* two-row tree into a row split:
-- the existing rows collectively become one side, the new panel the other, full
-- height, taller than either individual row.
--
-- The split isn't 50/50: the existing content's own minimum width (328 -- two
-- 160-minimum panels side by side, plus the gap between them) is more than half of
-- what's available, so distribute() pins it there and the new panel is left with
-- whatever remains (160, which happens to land exactly on its own minimum too) --
-- and the container grows just enough to fit both minimums side by side.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local first = document:getById(seededIds[1])
    local second = document:getById(seededIds[2])
    local third = document:getById(seededIds[3])
    local containerHeight0 = container().height

    -- Created off to the side, then dragged in by its header -- CreateGesture drops
    -- a new element on the canvas, not into whatever container happens to be under
    -- the click (see TODO.md); joining a container is always the drop half of a drag.
    Tools:setActive("panel")
    t.press(screenX(600), screenY(150))
    t.release(screenX(600), screenY(150))
    Tools:reset()

    local fourth = document.elements[document:count()]
    local pressX, pressY = headerOf(fourth)
    t.drag(pressX, pressY, screenX(container().x + container().width - 20), screenY(180))

    t.eq("column span: a fourth child", #children(), 4)
    t.eq("column span: it's the new panel", children()[4], fourth.id)
    t.near("column span: it spans the full content height", fourth.height, 160)
    t.check("column span: taller than either single row", fourth.height > first.height, fourth.height)
    t.near("column span: pinned at its own minimum width", fourth.width, 160)
    t.near("column span: the existing rows pinned at theirs", third.width, 328)
    t.near("column span: down to their own minimum too", first.width, 160)
    t.near("column span: both of them", second.width, 160)
    t.near("column span: the container grew to fit both minimums", container().width, 516)
    t.eq("column span: height untouched", container().height, containerHeight0)
end

-- A separate step: love.graphics.captureScreenshot queues the capture for this
-- frame's love.draw, which runs after the whole step returns -- undoing in the same
-- step the screenshot was taken in would revert the document before that draw ever
-- happens, and the image would show the *post*-undo board instead.
steps[#steps + 1] = function()
    Board:update(0)
    t.screenshot("column-span")
end

steps[#steps + 1] = function()
    local document = Board:getDocument()
    local first = document:getById(seededIds[1])
    local third = document:getById(seededIds[3])

    Actions.undo()
    Board:update(0)
    t.eq("column span undo: back to three children", #children(), 3)
    t.near("column span undo: container width restored", container().width, 500)
    t.near("column span undo: the cells got their width back", first.width, 236)
    t.near("column span undo: the bottom row spans full width again", third.width, 480)

    -- The drop and the panel's creation are two separate undo steps -- undoing just
    -- the drop leaves the panel itself still on the board, off where it was created.
    -- Undo that too, so later steps see the same document this one started with.
    local count0 = document:count()
    Actions.undo()
    t.eq("column span undo: the created panel is gone too", document:count(), count0 - 1)
end

-- A child's edge doesn't resize the child -- it moves the boundary between it and
-- its neighbour, so the pair keeps the space their row gave them.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local first = document:getById(seededIds[1])
    local second = document:getById(seededIds[2])
    local width0 = container().width

    t.drag(screenX(first.x + first.width), screenY(first.y + 30),
        screenX(first.x + first.width + 60), screenY(first.y + 30))

    t.near("cell resize: the grabbed cell grew", first.width, 296)
    t.near("cell resize: its neighbour gave up the same", second.width, 176)
    t.near("cell resize: the container is untouched", container().width, width0)

    Actions.undo()
    -- Child rects follow from the container's, so they settle on the next pass.
    Board:update(0)
    t.near("cell resize undo: back to half each", first.width, 236)
    t.near("cell resize undo: neighbour restored", second.width, 236)
end

-- Dragging the boundary between the two *rows* (rather than between two cells in one
-- row) finds it one level further up the tree -- the row-holding split, not the
-- individual cells -- and trades height between the rows as blocks. Each row's own
-- cells keep their share of that row's new height.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local first = document:getById(seededIds[1])
    local second = document:getById(seededIds[2])
    local third = document:getById(seededIds[3])
    local height0 = container().height

    -- The two rows already exactly fill the container's height (see "new row"
    -- above) -- there's no slack to move a boundary into until it grows.
    t.drag(screenX(container().x + container().width / 2), screenY(container().y + container().height),
        screenX(container().x + container().width / 2), screenY(container().y + container().height + 40))
    Board:update(0)
    local baseline = first.height
    t.near("row resize setup: both rows share the new room evenly", third.height, baseline)

    t.drag(screenX(first.x + 60), screenY(first.y + first.height),
        screenX(first.x + 60), screenY(first.y + first.height + 16))

    t.near("row resize: the top row grew", first.height, baseline + 16)
    t.near("row resize: its own cell followed", second.height, baseline + 16)
    t.near("row resize: the bottom row gave up the same", third.height, baseline - 16)
    t.eq("row resize: the container is untouched by the trade", container().height, height0 + 40)

    Actions.undo()
    Board:update(0)
    t.near("row resize undo: back to even", first.height, baseline)
    t.near("row resize undo: bottom row too", third.height, baseline)

    Actions.undo()
    Board:update(0)
    t.near("row resize undo: container height restored", container().height, height0)
end

-- The outermost edge of a row has no neighbour to trade with -- it's the container's
-- own edge, so dragging it pushes the wall out and every cell in the row grows.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local first = document:getById(seededIds[1])
    local second = document:getById(seededIds[2])
    local width0 = container().width

    t.drag(screenX(second.x + second.width), screenY(second.y + 30),
        screenX(second.x + second.width + 60), screenY(second.y + 30))

    t.near("outer edge: the container widened", container().width, width0 + 60)
    t.near("outer edge: the grabbed cell took its share", second.width, 266)
    t.near("outer edge: so did its neighbour", first.width, 266)

    Actions.undo()
    Board:update(0)
    t.near("outer edge undo: container restored", container().width, width0)
    t.near("outer edge undo: cells restored", first.width, 236)
end

-- Grabbing the container's own edge -- not a child's -- resizes the container itself,
-- and its children must not end up drawn in front of it. Raising just the container
-- on grab (append-to-front is a move to the *end* of the array) would do exactly
-- that; ResizeGesture has to raise the whole subtree together.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local element = container()
    local width0, height0 = element.width, element.height
    local childIds = children()

    -- The SE corner, clear of any child: content is inset by the container's own
    -- padding, so this point is outside every cell's rect.
    t.drag(screenX(element.x + element.width), screenY(element.y + element.height),
        screenX(element.x + element.width + 40), screenY(element.y + element.height + 30))

    t.check("container resize: grew", element.width > width0, element.width)
    for _, id in ipairs(childIds) do
        t.check("container resize: stays behind its children",
            document:indexOf(element.id) < document:indexOf(id), id)
    end

    Actions.undo()
    Board:update(0)
    t.near("container resize undo: width restored", element.width, width0)
    t.near("container resize undo: height restored", element.height, height0)
    for _, id in ipairs(childIds) do
        t.check("container resize undo: order restored",
            document:indexOf(element.id) < document:indexOf(id), id)
    end
end

-- Dragging a child by its header takes it back out, and undo puts it back in the
-- slot it came from at the size that slot gave it. Detaching the sole occupant of a
-- row collapses that row away, so its row-mate takes over the row's own *width*
-- (its height stays pinned at the panel minimum either way -- the two rows already
-- exactly fill the container's height, same as "row resize" needed extra room for).
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local first = document:getById(seededIds[1])
    local second = document:getById(seededIds[2])
    local cellX, cellY, cellWidth = first.x, first.y, first.width
    local secondWidth0 = second.width

    local pressX, pressY = headerOf(first)
    t.drag(pressX, pressY, screenX(-700), screenY(-260))

    t.eq("detach: container kept the other two", #children(), 2)
    t.check("detach: it followed the pointer", first.x < cellX, first.x)

    Board:update(0)
    t.check("detach: its row-mate collapsed to the row's full width", second.width > secondWidth0, second.width)
    t.near("detach: specifically the whole content width", second.width, 480)

    Actions.undo()
    Board:update(0)
    t.eq("detach undo: back in the container", #children(), 3)
    t.near("detach undo: back in its cell", first.x, cellX)
    t.near("detach undo: at the row's top", first.y, cellY)
    t.near("detach undo: at the cell's width", first.width, cellWidth)
    t.near("detach undo: its row-mate gave the width back", second.width, secondWidth0)
end

-- A container carries its contents: moving it moves them, and deleting a child
-- leaves a slot that the delete's own undo refills.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local element = container()
    local child = document:getById(children()[1])
    local offsetX = child.x - element.x
    local offsetY = child.y - element.y

    local pressX, pressY = headerOf(element)
    t.drag(pressX, pressY, pressX + 40, pressY + 30)
    Board:update(0)

    t.near("container move: child kept its offset in x", child.x - element.x, offsetX)
    t.near("container move: child kept its offset in y", child.y - element.y, offsetY)

    Actions.undo()
    Board:update(0)

    Board:getSelection():set(child.id)
    t.eq("child delete: removed", Actions.delete(), true)
    t.eq("child delete: the board lost it", document:getById(child.id), nil)
    t.eq("child delete: the slot it left is still recorded", #children(), 3)

    local sibling = document:getById(children()[2])
    Board:update(0)
    t.near("child delete: its row-mate took the space", sibling.width, 480)

    Actions.undo()
    Board:update(0)
    t.near("child delete undo: it's back in its own cell", sibling.width, 236)
end

-- Deleting the *container* takes its contents with it too, at any depth -- unlike a
-- detach or a plain copy, nothing is left for an orphaned child to still belong to.
-- One undo step restores the container, its children, and the arrangement between
-- them exactly, since RemoveElements never touched the container's own props.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local count0 = document:count()
    local childIds = children()
    local firstWidth0 = document:getById(childIds[1]).width

    Board:getSelection():set(containerId)
    t.eq("container delete: removed", Actions.delete(), true)
    t.eq("container delete: the container is gone", document:getById(containerId), nil)
    for _, id in ipairs(childIds) do
        t.eq("container delete: took a child with it", document:getById(id), nil)
    end
    t.eq("container delete: nothing else was touched", document:count(), count0 - 1 - #childIds)

    Actions.undo()
    Board:update(0)
    t.eq("container delete undo: container back", document:getById(containerId) ~= nil, true)
    t.eq("container delete undo: same children", #children(), #childIds)
    t.near("container delete undo: arrangement intact",
        document:getById(children()[1]).width, firstWidth0)
end

-- A container is panel-shaped, so it goes in a container like anything else. The one
-- arrangement that can't be made is a loop: a container dropped into something it
-- already holds would lay out its own ancestor.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local outer = container()
    local height0 = outer.height

    Tools:setActive("container")
    t.drag(screenX(-560), screenY(-300), screenX(-280), screenY(-140))
    Tools:reset()

    local inner = document.elements[document:count()]
    t.eq("nesting: second container created", inner.type, "container")

    -- Near the container's own bottom edge, which starts a new row under everything.
    local pressX, pressY = headerOf(inner)
    t.drag(pressX, pressY, screenX(outer.x + 60), screenY(outer.y + outer.height - 6))

    t.eq("nesting: the outer container took it", #children(), 4)
    t.eq("nesting: it's the last one", children()[4], inner.id)
    t.near("nesting: laid out inside", inner.x, outer.x + 10)
    t.check("nesting: the outer grew for it", outer.height > height0, outer.height)

    t.eq("nesting: a container can't be dropped into what it holds",
        Containment.dropTargetAt(document, inner.x + 20, inner.y + 40, outer), nil)

    Actions.undo()
    Actions.undo()
    Board:update(0)
    t.eq("nesting undo: the second container is gone", document:count(), 4)
    t.eq("nesting undo: the outer holds three again", #children(), 3)
    t.near("nesting undo: and is back to its own height", outer.height, height0)
end

-- Copying a container takes its contents with it, and the copy has to hold the copies
-- rather than still naming the originals -- which would give two containers one set
-- of children to fight over.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local count = document:count()

    Board:getSelection():set(containerId)
    t.eq("container copy: reports success", Actions.copy(), true)

    love.mouse.setPosition(screenX(-250), screenY(-330))
    t.eq("container paste: reports success", Actions.paste(), true)
    t.eq("container paste: the container and its three children", document:count(), count + 4)

    local copy = document.elements[count + 1]
    local copiedChildren = ElementRegistry:childIds(copy)
    t.eq("container paste: the copy is a container", copy.type, "container")
    t.eq("container paste: it holds three children", #copiedChildren, 3)
    t.eq("container paste: they're the pasted ones", copiedChildren[1], document.elements[count + 2].id)
    t.eq("container paste: the original still holds its own", #children(), 3)
    t.check("container paste: and they're different elements",
        children()[1] ~= copiedChildren[1], copiedChildren[1])

    Board:update(0)
    local firstCopied = document:getById(copiedChildren[1])
    t.near("container paste: the copy lays its children out", firstCopied.x, copy.x + 10)

    Actions.undo()
    t.eq("container paste undo: all four removed", document:count(), count)
end

-- ── Text and image elements ──────────────────────────────────────────────
--
-- Both are panel-derived (see ElementRegistry's header comment): the title field,
-- the frame and the resize handles are PanelElement's, reused as-is. What's new is
-- a second interaction on double-click -- an editable wrapping body for text, a
-- file picker for image -- so these tests exercise that door rather than
-- retreading the geometry ContainerElement's tests already cover. Created well off
-- to the side so they don't interact with whatever the container tests above left
-- selected or laid out.
--
-- Run before the save/round-trip test below, while the board is still unsaved --
-- exactly the state ImageElement's own "save first" guard needs a test for.

local noteId
local imageId

steps[#steps + 1] = function()
    local document = Board:getDocument()
    local count0 = document:count()

    Tools:setActive("text")
    local px, py = screenX(900), screenY(-300)
    t.press(px, py)
    t.release(px, py)
    Tools:reset()

    t.eq("text create: element added", document:count(), count0 + 1)
    local note = document.elements[document:count()]
    noteId = note.id
    t.eq("text create: default type", note.type, "text")
    t.eq("text create: default title", note.props.title, "Note")
    t.eq("text create: default body", note.props.body, "")
end

-- Double-clicking the header still renames the title -- PanelElement's field is
-- checked first -- rather than opening the body editor underneath it.
steps[#steps + 1] = function()
    local note = Board:getDocument():getById(noteId)
    local px, py = screenX(note.x + 20), screenY(note.y + 14)

    t.press(px, py, 2)
    t.release(px, py)

    local owner = TextEditSession:getOwner()
    t.eq("text header dblclick: renames the title, not the body", owner and owner.prop, "title")
    TextEditSession:cancel()
end

-- Double-clicking the body opens *that* field instead.
steps[#steps + 1] = function()
    local note = Board:getDocument():getById(noteId)
    local px, py = screenX(note.x + 40), screenY(note.y + 60)

    t.press(px, py, 2)
    t.release(px, py)

    t.eq("text edit: session opened", TextEditSession:isActive(), true)
    local owner = TextEditSession:getOwner()
    t.eq("text edit: editing the body prop", owner and owner.prop, "body")
    t.eq("text edit: editing this element", owner and owner.id, noteId)
end

-- Enter inserts a literal newline instead of committing -- a note's body is exactly
-- the content that wants line breaks, unlike a title rename -- and a line too long
-- for the field wraps onto more than one visual row on its own.
steps[#steps + 1] = function()
    t.typeText("first line of the note, long enough that it has to wrap onto more than one row")
    t.key("return")
    t.typeText("second line")

    t.eq("text edit: still open after Enter", TextEditSession:isActive(), true)
    local text = TextEditSession:getEditor():getText()
    t.check("text edit: Enter inserted a literal newline", text:find("\n", 1, true) ~= nil, text)

    local lines = TextEditSession:getLines()
    t.check("text edit: the long first line wrapped onto more than one row", #lines > 2, #lines)
end

-- Clicking away commits, same as every other field -- and the wrapped body reads
-- back out as one plain string with the typed newline still in it.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    TextEditSession:commit()

    local note = document:getById(noteId)
    t.check("text edit: commit wrote the body prop",
        note.props.body:find("second line", 1, true) ~= nil, note.props.body)

    Actions.undo()
    t.eq("text edit undo: body reverted", document:getById(noteId).props.body, "")
end

-- Escape discards the edit instead.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local note = document:getById(noteId)
    local px, py = screenX(note.x + 40), screenY(note.y + 60)

    t.press(px, py, 2)
    t.release(px, py)
    t.typeText("discarded")
    t.key("escape")

    t.eq("text edit escape: session closed", TextEditSession:isActive(), false)
    t.eq("text edit escape: body unchanged", document:getById(noteId).props.body, "")
end

steps[#steps + 1] = function()
    local document = Board:getDocument()
    local count0 = document:count()

    Tools:setActive("image")
    local px, py = screenX(900), screenY(0)
    t.press(px, py)
    t.release(px, py)
    Tools:reset()

    t.eq("image create: element added", document:count(), count0 + 1)
    local image = document.elements[document:count()]
    imageId = image.id
    t.eq("image create: default type", image.type, "image")
    t.eq("image create: default title", image.props.title, "Image")
    t.eq("image create: no path yet", image.props.path, nil)
end

-- The board hasn't been saved yet at this point in the run (that happens in the
-- round trip test below), so there's nowhere to resolve a relative image path
-- against -- double-clicking the body has to say so rather than opening a picker
-- that could only ever fail to place what gets chosen.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local image = document:getById(imageId)
    local px, py = screenX(image.x + 20), screenY(image.y + 40)

    t.press(px, py, 2)
    t.release(px, py)

    t.eq("image dblclick unsaved: no path was set", document:getById(imageId).props.path, nil)
    t.eq("image dblclick unsaved: no edit session opened", TextEditSession:isActive(), false)
end

-- Draws cleanly with no path chosen yet (the empty-state hint) -- exercised through
-- the real draw pass, since that's the path a missing or unreadable image is
-- actually caught on.
steps[#steps + 1] = function()
    Board:update(0)
    t.screenshot("text-and-image")
end

-- ── Lines ────────────────────────────────────────────────────────────────
--
-- A connector between two elements: dragging the line tool from one to another makes
-- it, clicking near its stroke selects it -- there's no bounding-box outline for a
-- line (see Board:drawSelectionOutlines), so this is the only way to prove the hit
-- test actually works -- and deleting either endpoint takes the line with it.

local lineFromId, lineToId, lineId

steps[#steps + 1] = function()
    local document = Board:getDocument()
    local count0 = document:count()

    Tools:setActive("panel")
    t.press(screenX(900), screenY(300))
    t.release(screenX(900), screenY(300))
    lineFromId = document.elements[document:count()].id

    t.press(screenX(900), screenY(550))
    t.release(screenX(900), screenY(550))
    lineToId = document.elements[document:count()].id
    Tools:reset()

    t.eq("line setup: two panels added", document:count(), count0 + 2)
end

-- Pressing on one panel and releasing on the other connects them.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local from = document:getById(lineFromId)
    local to = document:getById(lineToId)
    local count0 = document:count()

    Tools:setActive("line")
    t.drag(screenX(from.x + from.width / 2), screenY(from.y + from.height / 2),
        screenX(to.x + to.width / 2), screenY(to.y + to.height / 2))
    Tools:reset()

    t.eq("line create: element added", document:count(), count0 + 1)
    local line = document.elements[document:count()]
    lineId = line.id
    t.eq("line create: type", line.type, "line")
    t.eq("line create: connects the pressed panel", line.props.fromId, lineFromId)
    t.eq("line create: connects the released panel", line.props.toId, lineToId)
    t.eq("line create: it's selected", Board:getSelection():contains(lineId), true)
end

-- Releasing over empty canvas abandons the drag instead of connecting to nothing.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local count0 = document:count()

    Tools:setActive("line")
    t.drag(screenX(950), screenY(350), screenX(700), screenY(300))
    Tools:reset()

    t.eq("line abandoned: nothing added", document:count(), count0)
end

-- The endpoints are derived from the two panels' current rects, not stored literally
-- -- updateGeometry runs from Board:update, so a fresh frame has to pass before
-- they're readable.
steps[#steps + 1] = function()
    Board:update(0)
    local line = Board:getDocument():getById(lineId)
    t.check("line geometry: has a from point", line.fromX ~= nil, line.fromX)
    t.check("line geometry: has a to point", line.toX ~= nil, line.toX)
end

-- Clicking near the middle of the stroke selects it -- there's nothing else at that
-- point, since the two panels it connects are off to either side.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local line = document:getById(lineId)
    Actions.deselectAll()

    local midX, midY = (line.fromX + line.toX) / 2, (line.fromY + line.toY) / 2
    t.press(screenX(midX), screenY(midY))
    t.release(screenX(midX), screenY(midY))

    t.eq("line select: clicking the stroke selects it", Board:getSelection():contains(lineId), true)
end

-- Deleting one of the two connected panels takes the line with it, in the same undo
-- step -- the same way a container's delete takes its children, just in the opposite
-- dependency direction (see ElementRegistry:dependsOn).
steps[#steps + 1] = function()
    local document = Board:getDocument()
    Board:getSelection():set(lineFromId)

    t.eq("line cascade: delete reports success", Actions.delete(), true)
    t.eq("line cascade: the panel is gone", document:getById(lineFromId), nil)
    t.eq("line cascade: the line went with it", document:getById(lineId), nil)

    Actions.undo()
    t.eq("line cascade undo: the panel is back", document:getById(lineFromId) ~= nil, true)
    t.eq("line cascade undo: the line is back", document:getById(lineId) ~= nil, true)

    Board:update(0)
    t.eq("line cascade undo: still connects the same two panels",
        document:getById(lineId).props.toId, lineToId)
end

-- A .grimoire file is JSON anything could have written, and hand-editing one is meant
-- to be possible -- so a container whose tree is nonsense opens with whatever can be
-- salvaged rather than crashing the first time something lays it out.
steps[#steps + 1] = function()
    -- Exercised directly against the sanitizer first: it's the part with the actual
    -- decision tree, and a direct check names exactly which malformed shape produced
    -- which surviving one.
    t.eq("sanitize: not a table at all", ContainerLayout.sanitize("not a tree"), nil)
    t.eq("sanitize: a split with no direction", ContainerLayout.sanitize({ children = {} }), nil)
    t.eq("sanitize: a split with an unrecognised direction",
        ContainerLayout.sanitize({ direction = "diagonal", children = { { id = "a" } } }), nil)
    t.eq("sanitize: a leaf with no id", ContainerLayout.sanitize({ weight = 1 }), nil)

    local single = ContainerLayout.sanitize({
        direction = "row",
        children = { "junk", { id = "a", weight = "nonsense" } },
    })
    t.check("sanitize: a split left with one live child collapses to it",
        single and not single.children, single)
    t.eq("sanitize: the survivor's id", single.id, "a")
    t.eq("sanitize: a weight that isn't a number falls back to 1", single.weight, 1)

    local pair = ContainerLayout.sanitize({
        direction = "column",
        children = {
            { id = "a" },
            { direction = "row", children = { 42, { id = "b" } } },
        },
    })
    t.eq("sanitize: a nested split survives alongside a leaf", #pair.children, 2)
    t.eq("sanitize: the nested split kept its one salvageable leaf", pair.children[2].id, "b")

    -- And through the actual load path, so the wiring that calls the sanitizer is
    -- covered too, not just the sanitizer itself.
    local document, warnings = Document.fromData({
        version = 1,
        elements = {
            { id = "x", type = "container", x = 0, y = 0, width = 400, height = 300,
                props = { layout = "not a tree" } },
            { id = "y", type = "container", x = 0, y = 0, width = 400, height = 300,
                props = { layout = { direction = "row", children = { { id = "z" } } } } },
        },
    })

    t.check("malformed layout: the file still opens", document ~= nil, warnings)
    t.eq("malformed layout: an unusable tree is dropped entirely", document:getById("x").props.layout, nil)
    -- "z" was never one of the file's own elements -- the same situation as an
    -- element that's since been deleted, and it lays out as empty rather than erroring.
    Containment.layoutAll(document)
    t.eq("malformed layout: naming a missing element is not an error", document:count(), 2)
end

steps[#steps + 1] = function()
    local zoom = Canvas.zoom
    Actions.zoomIn()
    t.check("zoom in", Canvas.zoom > zoom, Canvas.zoom)
    Actions.zoomOut()
    t.near("zoom out returns to where it was", Canvas.zoom, zoom)

    Actions.zoomIn()
    Actions.zoomIn()
    Actions.resetZoom()
    t.near("reset zoom", Canvas.zoom, 1)
end

-- The tracked count has to survive every mutation path, since nothing recounts it.
steps[#steps + 1] = function()
    local selection = Selection.new()
    selection:add("a")
    selection:add("a")
    selection:add("b")
    t.eq("selection count: add is idempotent", selection:count(), 2)

    selection:toggle("b")
    t.eq("selection count: toggle off", selection:count(), 1)
    selection:toggle("c")
    t.eq("selection count: toggle on", selection:count(), 2)

    selection:remove("not-a-member")
    t.eq("selection count: removing a non-member", selection:count(), 2)

    selection:retain(function(id) return id == "a" end)
    t.eq("selection count: retain", selection:count(), 1)

    selection:set("d")
    t.eq("selection count: set replaces", selection:count(), 1)
    selection:clear()
    t.eq("selection count: clear", selection:count(), 0)
    t.eq("selection isEmpty", selection:isEmpty(), true)
end

steps[#steps + 1] = function()
    local path = love.filesystem.getSaveDirectory() .. "/test-roundtrip.grimoire"
    local before = Serialize.encode(Board:getDocument():toData())
    local count = Board:getDocument():count()

    t.eq("save: reported success", BoardFile:saveTo(path), true)
    t.eq("save: no .tmp left behind", io.open(path .. ".tmp", "rb"), nil)
    t.eq("save: no .bak left behind", io.open(path .. ".bak", "rb"), nil)

    -- Saving over an existing file is the case os.rename can't do directly on Windows,
    -- so it's the one the atomic writer's three-rename swap exists for.
    t.eq("save: overwrote in place", BoardFile:saveTo(path), true)

    t.eq("open: loaded it back", BoardFile:openPath(path), true)
    local reopened = Board:getDocument()
    t.eq("round trip: element count", reopened:count(), count)
    t.eq("round trip: the container still holds its children",
        #ElementRegistry:childIds(reopened:getById(containerId)), 3)
    t.eq("round trip: re-encodes byte-identically", Serialize.encode(reopened:toData()), before)
    t.eq("round trip: board is clean after opening", BoardFile:isDirty(), false)
end

-- ImageElement reads a picture's bytes itself (io.*) rather than handing
-- love.graphics.newImage a bare path: love.filesystem -- what newImage would use
-- directly -- only sees the game source and save directories, not an arbitrary
-- absolute path elsewhere on disk, which is exactly where a board's neighbouring
-- image lives. A path into the LOVE save directory is a real absolute OS path that
-- love.filesystem itself cannot be handed as one, so it's a faithful stand-in for
-- "somewhere outside the sandbox" without needing a file outside it.
steps[#steps + 1] = function()
    local ImageElement = require "application.Canvas.elements.ImageElement"

    local imageData = love.image.newImageData(4, 4)
    imageData:mapPixel(function() return 1, 0, 0, 1 end)
    local bytes = imageData:encode("png"):getString()

    local imagePath = love.filesystem.getSaveDirectory() .. "/test-image.png"
    local file = io.open(imagePath, "wb")
    file:write(bytes)
    file:close()

    local entry = ImageElement.load(imagePath)
    t.check("image load: reads a PNG from an absolute path outside the sandbox",
        entry.image ~= nil, entry.error)
    t.eq("image load: decoded at the size it was written", entry.image:getWidth(), 4)

    local missing = ImageElement.load(imagePath .. ".does-not-exist")
    t.check("image load: a missing file reports an error instead of crashing",
        missing.error ~= nil, missing.image)
end

-- ── Visual passes ────────────────────────────────────────────────────────
--
-- Gestures held open across frames so a screenshot catches them mid-flight. Nothing
-- is asserted here -- these are for looking at.

steps[#steps + 1] = function()
    Tools:reset()
    t.press(150, 480)
    t.moveTo(1150, 250)
    t.screenshot("marquee")
end

steps[#steps + 1] = function()
    t.release(1150, 250)
    Tools:setActive("panel")
    t.press(660, 470)
    t.moveTo(1010, 650)
    t.screenshot("create-preview")
end

steps[#steps + 1] = function()
    t.release(1010, 650)
    Actions.undo()
    Tools:reset()
    Actions.deselectAll()
    t.screenshot("board")
end

-- A child held over the right edge of its neighbour: the panel following the pointer,
-- and the blue slot it would land in.
local heldX, heldY

steps[#steps + 1] = function()
    local document = Board:getDocument()
    local dragged = document:getById(seededIds[1])
    local target = document:getById(seededIds[2])

    local pressX, pressY = headerOf(dragged)
    heldX = screenX(target.x + target.width - 12)
    heldY = screenY(target.y + 60)

    t.press(pressX, pressY)
    t.moveTo(heldX, heldY)
    -- Steps run after the frame's update, so the layout pass that reacts to a
    -- detached child has already been and gone; a real drag is dispatched before it.
    Board:update(0)
    t.screenshot("container-drop")
end

steps[#steps + 1] = function()
    t.release(heldX, heldY)
    Actions.undo()
    Actions.deselectAll()
    Board:update(0)
    t.screenshot("container")
end

-- An empty container, for the hint that says what to do with it.
steps[#steps + 1] = function()
    Tools:setActive("container")
    t.drag(screenX(-560), screenY(-300), screenX(-280), screenY(-140))
    Tools:reset()
    Actions.deselectAll()
    Board:update(0)
    t.screenshot("container-empty")
end

return steps
