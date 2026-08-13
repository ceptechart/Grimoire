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
local Markdown = require "application.Text.Markdown"
local MarkdownLayout = require "application.Text.MarkdownLayout"
local MarkdownElement = require "application.Canvas.elements.MarkdownElement"
local ContentScroll = require "application.Canvas.ContentScroll"
local Cursor = require "application.Canvas.Cursor"
local ElementRegistry = require "application.Canvas.ElementRegistry"
local ContainerLayout = require "application.Canvas.ContainerLayout"
local Containment = require "application.Canvas.Containment"
local RemoveElements = require "application.Canvas.commands.RemoveElements"
local AddElement = require "application.Canvas.commands.AddElement"

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

-- The create gesture, driven through the Text tool -- any tool carrying a
-- `createType` exercises the same one, and what's asserted here (the drag decides
-- the size, a click yields the type's default) is true of all of them.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    Tools:setActive("text")
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
-- rather than a zero-sized element. Still on the Text tool the step above selected.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    t.press(700, 500)
    t.release(700, 500)

    t.eq("create click: element added", document:count(), 4)
    t.near("create click: default width", document.elements[4].width, 260)
    t.near("create click: default height", document.elements[4].height, 180)
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

    -- Added off to the side, then dragged in by its header. Joining a container is
    -- always the drop half of a drag -- CreateGesture drops a new element on the
    -- canvas, not into whatever container happens to be under the click (see
    -- TODO.md) -- so how this one got onto the board isn't what's under test, and
    -- it's put there directly rather than through a tool. It stays a *panel*
    -- specifically: every width asserted below is a panel's 160 minimum being
    -- traded against its neighbours', and creating some other type here would be
    -- changing the arithmetic rather than the setup.
    local fourth = ElementRegistry:create("panel", 600, 150)
    document:execute(AddElement.new(fourth))

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

-- ── Markdown ─────────────────────────────────────────────────────────────
--
-- Three layers, tested where each one actually lives: the parser is pure and is
-- asserted against directly (it needs no window, and a direct check names the
-- syntax that broke rather than the pixel that moved), the layout is asserted
-- through the real fonts because measuring is the whole of what it does, and the
-- element is driven through the same synthetic double-clicks a user would produce.
--
-- The parser tests are the ones worth keeping honest: every one of them is a piece
-- of syntax from markdownguide.org, and the failure mode this element has is
-- silently rendering markup as literal text.

local markdownId

-- The document used for the layout, link and screenshot steps below. Deliberately
-- one of everything the element claims to support -- if a feature is in the list in
-- Markdown.lua's header, it's in here.
local MARKDOWN_SAMPLE = table.concat({
    "# Grimoire",
    "",
    "A **bold** claim, an *italic* aside, ***both at once***, some `inline code`,",
    "and a ~~retracted~~ one. See [the guide](https://www.markdownguide.org/).",
    "",
    "Marked ==like this==, water is H~2~O, and x^2^ is a square.",
    "Pasted bare: https://example.com/docs",
    "",
    -- No space after the hashes, which is a heading here even though it isn't in
    -- standard markdown.
    "##Lists",
    "",
    "- first",
    "- second",
    "  - nested",
    "- [x] done",
    "- [ ] not done",
    "",
    "1. one",
    "2. two",
    "",
    "> Quoted text, which can hold **its own** formatting.",
    ">",
    "> > and another quote inside it",
    "",
    "```lua",
    "local answer = 42",
    "```",
    "",
    "| Feature | State |",
    "| --- | :---: |",
    "| Tables | yes |",
    "| Footnotes | no |",
    "",
    "---",
}, "\n")

steps[#steps + 1] = function()
    local document = Board:getDocument()
    local count0 = document:count()

    Tools:setActive("markdown")
    local px, py = screenX(900), screenY(300)
    t.press(px, py)
    t.release(px, py)
    Tools:reset()

    t.eq("markdown create: element added", document:count(), count0 + 1)
    local element = document.elements[document:count()]
    markdownId = element.id
    t.eq("markdown create: default type", element.type, "markdown")
    t.eq("markdown create: default title", element.props.title, "Markdown")
    t.eq("markdown create: empty body", element.props.body, "")
end

-- Blocks. Each assertion is one piece of syntax, so a failure names it.
steps[#steps + 1] = function()
    local blocks = Markdown.parse(MARKDOWN_SAMPLE)

    local kinds = {}
    for _, block in ipairs(blocks) do
        kinds[#kinds + 1] = block.kind
    end
    t.eq("markdown parse: block sequence", table.concat(kinds, ","),
        "heading,paragraph,paragraph,heading,list,list,quote,code,table,rule")

    t.eq("markdown parse: h1 level", blocks[1].level, 1)
    t.eq("markdown parse: a heading needs no space after its hashes", blocks[4].level, 2)
    t.eq("markdown parse: and keeps its text", blocks[4].inlines[1].text, "Lists")

    local unordered = blocks[5]
    t.eq("markdown parse: unordered list", unordered.ordered, false)
    t.eq("markdown parse: four top-level items", #unordered.items, 4)
    t.eq("markdown parse: an indented item nests rather than flattening",
        unordered.items[2].blocks[2] and unordered.items[2].blocks[2].kind, "list")
    t.eq("markdown parse: task item, checked", unordered.items[3].checked, true)
    t.eq("markdown parse: task item, unchecked", unordered.items[4].checked, false)
    t.eq("markdown parse: the task marker came off the text",
        unordered.items[3].blocks[1].inlines[1].text, "done")

    local ordered = blocks[6]
    t.eq("markdown parse: ordered list", ordered.ordered, true)
    t.eq("markdown parse: ordered start", ordered.start, 1)

    local quote = blocks[7]
    t.eq("markdown parse: quote holds blocks", quote.blocks[1].kind, "paragraph")
    t.eq("markdown parse: a quote nests inside a quote", quote.blocks[2].kind, "quote")

    local code = blocks[8]
    t.eq("markdown parse: fenced code language", code.lang, "lua")
    t.eq("markdown parse: code contents are literal", code.lines[1], "local answer = 42")

    local table_ = blocks[9]
    t.eq("markdown parse: table columns", #table_.header, 2)
    t.eq("markdown parse: table rows", #table_.rows, 2)
    t.eq("markdown parse: per-column alignment", table_.align[2], "center")
    t.eq("markdown parse: header cell text", table_.header[1][1].text, "Feature")
end

-- Inline. The paragraph in the sample carries every span type at once, which is
-- also the case that would break if the emphasis scanner's exact-run rule slipped.
steps[#steps + 1] = function()
    local paragraph = Markdown.parse(MARKDOWN_SAMPLE)[2]

    local found = {}
    for _, span in ipairs(paragraph.inlines) do
        if span.bold and span.italic then found.both = span.text
        elseif span.bold then found.bold = span.text
        elseif span.italic then found.italic = span.text
        elseif span.strike then found.strike = span.text
        elseif span.code then found.code = span.text
        elseif span.link then found.link, found.linkText = span.link, span.text end
    end

    t.eq("markdown inline: bold", found.bold, "bold")
    t.eq("markdown inline: italic", found.italic, "italic")
    t.eq("markdown inline: bold italic", found.both, "both at once")
    t.eq("markdown inline: strikethrough", found.strike, "retracted")
    t.eq("markdown inline: inline code", found.code, "inline code")
    t.eq("markdown inline: link text", found.linkText, "the guide")
    t.eq("markdown inline: link destination", found.link, "https://www.markdownguide.org/")

    -- Nesting: the outer emphasis has to close at the *outer* delimiter, not at
    -- the first one it meets inside the inner bold.
    local nested = Markdown.parseInline("*a **b** c*")
    t.eq("markdown inline: nesting, three spans", #nested, 3)
    t.eq("markdown inline: nesting, outer italic survives", nested[1].italic, true)
    t.eq("markdown inline: nesting, inner is bold too", nested[2].bold, true)
    t.eq("markdown inline: nesting, inner is still italic", nested[2].italic, true)

    -- The things that look like markup and aren't.
    local literal = Markdown.parseInline("snake_case_name and 2 \\* 3")
    t.eq("markdown inline: an underscore inside a word is not emphasis",
        literal[1].italic, nil)
    t.eq("markdown inline: escapes and intraword underscores stay literal",
        literal[1].text, "snake_case_name and 2 * 3")
end

-- The marks that aren't in basic markdown: highlight, and the sub/superscript pair
-- that has to share the tilde with strikethrough without either reading the other's
-- delimiters.
steps[#steps + 1] = function()
    local marks = Markdown.parse(MARKDOWN_SAMPLE)[3].inlines

    local found = {}
    for _, span in ipairs(marks) do
        if span.highlight then found.highlight = span.text end
        if span.sub then found.sub = span.text end
        if span.sup then found.sup = span.text end
        if span.link then found.link, found.linkText = span.link, span.text end
    end

    t.eq("markdown inline: ==highlight==", found.highlight, "like this")
    t.eq("markdown inline: ~subscript~", found.sub, "2")
    t.eq("markdown inline: ^superscript^", found.sup, "2")

    -- One tilde is a subscript and two are a strikethrough, in the same string.
    local tildes = Markdown.parseInline("H~2~O is ~~not~~ fine")
    local sub, strike
    for _, span in ipairs(tildes) do
        if span.sub then sub = span.text end
        if span.strike then strike = span.text end
    end
    t.eq("markdown inline: a single tilde subscripts", sub, "2")
    t.eq("markdown inline: a double tilde still strikes out", strike, "not")

    -- A bare URL is a link without any [](...) around it, and the sentence's own
    -- punctuation isn't part of the address.
    t.eq("markdown inline: a bare URL becomes a link", found.link, "https://example.com/docs")
    t.eq("markdown inline: shown exactly as typed", found.linkText, "https://example.com/docs")

    local wrapped = Markdown.parseInline("see (https://example.com/a), or www.example.com.")
    local urls = {}
    for _, span in ipairs(wrapped) do
        if span.link then urls[#urls + 1] = span.link end
    end
    t.eq("markdown inline: two bare URLs on one line", #urls, 2)
    t.eq("markdown inline: a closing bracket is not part of the URL",
        urls[1], "https://example.com/a")
    t.eq("markdown inline: a scheme-less www URL gets one to open with",
        urls[2], "https://www.example.com")

    -- An empty label shows the address rather than nothing at all.
    local unlabelled = Markdown.parseInline("[](https://example.com)")
    t.eq("markdown inline: an empty link label falls back to the address",
        unlabelled[1] and unlabelled[1].text, "https://example.com")
end

-- A newline in the source is a newline on the board -- no trailing-whitespace
-- syntax required. This is the rule that differs most from standard markdown, so
-- it gets its own assertion rather than riding on the sample above.
steps[#steps + 1] = function()
    local blocks = Markdown.parse("one\ntwo\n\nthree")
    t.eq("markdown breaks: consecutive lines are still one paragraph", #blocks, 2)

    local breaks = 0
    for _, span in ipairs(blocks[1].inlines) do
        if span.br then breaks = breaks + 1 end
    end
    t.eq("markdown breaks: with a break between them, unasked for", breaks, 1)
    t.eq("markdown breaks: a blank line still starts a new paragraph",
        blocks[2].inlines[1].text, "three")

    -- The old spellings still parse; they just no longer make any difference.
    local explicit = Markdown.parse("one  \ntwo\\\nthree")
    t.eq("markdown breaks: trailing spaces and backslashes are still one paragraph",
        #explicit, 1)
    local text = {}
    for _, span in ipairs(explicit[1].inlines) do
        text[#text + 1] = span.br and "|" or span.text
    end
    t.eq("markdown breaks: and leave no stray backslash behind",
        table.concat(text), "one|two|three")
end

-- Editing is source, not rendering: double-clicking the body opens the raw text,
-- and what commits is the string the file will hold.
steps[#steps + 1] = function()
    local element = Board:getDocument():getById(markdownId)
    local px, py = screenX(element.x + 40), screenY(element.y + 60)

    t.press(px, py, 2)
    t.release(px, py)

    local owner = TextEditSession:getOwner()
    t.eq("markdown edit: session opened", TextEditSession:isActive(), true)
    t.eq("markdown edit: editing the body prop", owner and owner.prop, "body")
    t.eq("markdown edit: editing this element", owner and owner.id, markdownId)
end

steps[#steps + 1] = function()
    local document = Board:getDocument()
    t.typeText("## Heading")
    TextEditSession:commit()

    t.eq("markdown edit: the source is stored verbatim, not rendered",
        document:getById(markdownId).props.body, "## Heading")

    Actions.undo()
    t.eq("markdown edit undo: body reverted", document:getById(markdownId).props.body, "")

    -- Set directly for the layout steps below: typing the whole sample through
    -- synthetic textinput would take a frame per keystroke and prove nothing the
    -- step above hasn't.
    document:getById(markdownId).props.body = MARKDOWN_SAMPLE
end

-- Layout runs against the real fonts, which is the point of it -- a heading is
-- taller than body text because the font is, not because a constant says so.
steps[#steps + 1] = function()
    local element = Board:getDocument():getById(markdownId)
    local _, _, width = MarkdownElement.bodyRect(element)
    local layout = MarkdownLayout.build(Markdown.parse(MARKDOWN_SAMPLE), width)

    t.check("markdown layout: produced draw items", #layout.items > 0, #layout.items)
    t.check("markdown layout: the document has height", layout.height > 0, layout.height)
    t.eq("markdown layout: a link for each one in the source", #layout.links, 2)
    t.eq("markdown layout: the link kept its destination",
        layout.links[1].url, "https://www.markdownguide.org/")
    t.eq("markdown layout: the bare one too", layout.links[2].url, "https://example.com/docs")

    local link = layout.links[1]
    t.check("markdown layout: linkAt hits inside the link's rect",
        MarkdownLayout.linkAt(layout, link.x + 1, link.y + 1) == link)
    t.eq("markdown layout: linkAt misses outside it",
        MarkdownLayout.linkAt(layout, link.x - 20, link.y - 40), nil)

    -- Narrower means taller: the same document wrapped into less width. This is
    -- the assertion that would fail if wrapping quietly stopped happening.
    local narrow = MarkdownLayout.build(Markdown.parse(MARKDOWN_SAMPLE), width / 2)
    t.check("markdown layout: halving the width makes the document taller",
        narrow.height > layout.height, ("%d vs %d"):format(narrow.height, layout.height))
end

-- Double-clicking a link follows it instead of opening the editor -- which is why
-- Board asks the element type before it looks for a text field. openURL is stubbed
-- rather than called: a test run shouldn't open a browser.
steps[#steps + 1] = function()
    local element = Board:getDocument():getById(markdownId)
    local bodyX, bodyY, width = MarkdownElement.bodyRect(element)
    local layout = MarkdownLayout.build(Markdown.parse(MARKDOWN_SAMPLE), width)
    local link = layout.links[1]

    local opened
    local realOpenURL = love.system.openURL
    love.system.openURL = function(url) opened = url; return true end

    local px = screenX(bodyX + link.x + link.width / 2)
    local py = screenY(bodyY + link.y + link.height / 2)
    t.press(px, py, 2)
    t.release(px, py)

    love.system.openURL = realOpenURL

    t.eq("markdown link: double-clicking it opened the destination",
        opened, "https://www.markdownguide.org/")
    t.eq("markdown link: and did not open the source editor",
        TextEditSession:isActive(), false)
end

-- Anywhere in the body that isn't a link still edits, so following a link hasn't
-- cost the element its editor.
steps[#steps + 1] = function()
    local element = Board:getDocument():getById(markdownId)
    local px, py = screenX(element.x + 20), screenY(element.y + element.height - 20)

    t.press(px, py, 2)
    t.release(px, py)

    local owner = TextEditSession:getOwner()
    t.eq("markdown link: a double-click off the link still opens the source",
        owner and owner.prop, "body")
    TextEditSession:cancel()
end

-- Hovering a link lights it and puts the hand cursor over it. The lit link is view
-- state on Board rather than anything in the document, and it's an id rather than a
-- rect so a link that wrapped across two lines lights in both places at once.
steps[#steps + 1] = function()
    local element = Board:getDocument():getById(markdownId)
    local bodyX, bodyY, width = MarkdownElement.bodyRect(element)
    local layout = MarkdownLayout.build(Markdown.parse(MARKDOWN_SAMPLE), width)
    local link = layout.links[1]

    t.moveTo(screenX(bodyX + link.x + link.width / 2),
        screenY(bodyY + link.y + link.height / 2))

    t.eq("markdown hover: the element under the pointer is the hovered one",
        Board.hoverId, markdownId)
    t.eq("markdown hover: and the link under it is the target", Board.hoverTarget, link.id)
    t.eq("markdown hover: cursor over a link", Cursor:getCurrent(), "hand")

    -- Off the link but still on the element: the body is ordinary text, and the
    -- highlight has to come back off rather than stick to the last thing hovered.
    t.moveTo(screenX(element.x + 20), screenY(element.y + element.height - 20))
    t.eq("markdown hover: moving off the link clears the target", Board.hoverTarget, nil)
    t.eq("markdown hover: and the cursor with it", Cursor:getCurrent(), "arrow")
end

-- A .grimoire file is JSON anything could have written, so a body that isn't a
-- string is repaired on load rather than left for the renderer to trip over.
steps[#steps + 1] = function()
    local element = { props = { body = { "not", "a", "string" } } }
    MarkdownElement.normalizeProps(element)
    t.eq("markdown normalize: a table body becomes empty text", element.props.body, "")

    element = { props = { body = 42 } }
    MarkdownElement.normalizeProps(element)
    t.eq("markdown normalize: a number body is kept as its text", element.props.body, "42")

    element = { props = {} }
    MarkdownElement.normalizeProps(element)
    t.eq("markdown normalize: an absent body stays absent", element.props.body, nil)
end

-- ── Scrolling ────────────────────────────────────────────────────────────
--
-- Content taller than its element scrolls, by wheel or by dragging the bar. The
-- offset is view state -- it isn't an edit, so none of these steps should touch the
-- undo stack or the dirty flag, which the two assertions at the end check.
--
-- The markdown element still holds MARKDOWN_SAMPLE from the steps above, which is a
-- great deal taller than the 300 it was created at.

local function markdownMetrics()
    return ContentScroll.metricsOf(Board:getDocument():getById(markdownId))
end

-- Brings an element on screen and puts the real cursor over it, which is what the
-- wheel handler reads -- wheelmoved carries an amount, not a position. Both halves
-- matter: these elements were created well off to the side, and a setPosition
-- outside the window is clamped back into it, which would leave the pointer over
-- the status bar and the wheel consumed by chrome before it ever reached the board.
local function pointAt(element, dx, dy)
    Canvas:resetZoom()
    Canvas.offset.x = -element.x + 60
    Canvas.offset.y = -element.y + 60
    love.mouse.setPosition(screenX(element.x + dx), screenY(element.y + dy))
end

steps[#steps + 1] = function()
    local element = Board:getDocument():getById(markdownId)
    local metrics = markdownMetrics()

    t.check("scroll: the sample overflows its element", metrics ~= nil)
    t.check("scroll: content is taller than the window",
        metrics.contentHeight > metrics.height,
        ("%d vs %d"):format(metrics.contentHeight, metrics.height))
    t.eq("scroll: starts at the top", metrics.offset, 0)
    t.check("scroll: the thumb is shorter than its track",
        metrics.thumbHeight < metrics.trackHeight, metrics.thumbHeight)

    -- Wheeling down over it scrolls it *and* consumes the event, so the canvas
    -- doesn't also zoom underneath.
    local zoom0 = Canvas.zoom
    pointAt(element, 40, 80)
    t.eq("scroll wheel: consumed by the element", t.wheel(-1), true)
    t.check("scroll wheel: content moved down", markdownMetrics().offset > 0,
        markdownMetrics().offset)
    t.eq("scroll wheel: the canvas did not zoom", Canvas.zoom, zoom0)
end

-- At the top, wheeling up has nothing left to do -- but the element still keeps the
-- event, so hitting the end of a document doesn't quietly turn the same wheel into
-- a canvas zoom.
steps[#steps + 1] = function()
    local element = Board:getDocument():getById(markdownId)
    pointAt(element, 40, 80)

    for _ = 1, 20 do t.wheel(1) end
    t.eq("scroll wheel: stops at the top", markdownMetrics().offset, 0)

    local zoom0 = Canvas.zoom
    t.eq("scroll wheel: still consumed at the end of the content", t.wheel(1), true)
    t.eq("scroll wheel: so the canvas did not zoom instead", Canvas.zoom, zoom0)
end

-- The bar itself: pressing the thumb and dragging it down scrolls proportionally,
-- and releasing ends the gesture without leaving anything on the undo stack.
steps[#steps + 1] = function()
    local metrics = markdownMetrics()
    local undoDepth = Actions.canUndo()

    -- Grab the middle of the thumb, drag it to the bottom of the track.
    local grabX = screenX(metrics.trackX + metrics.trackWidth / 2)
    local grabY = screenY(metrics.thumbY + metrics.thumbHeight / 2)
    t.press(grabX, grabY)
    t.moveTo(grabX, screenY(metrics.trackY + metrics.trackHeight))
    t.release(grabX, screenY(metrics.trackY + metrics.trackHeight))

    t.near("scroll drag: dragged to the bottom of the track", markdownMetrics().offset,
        metrics.maxOffset, 1)
    t.eq("scroll drag: recorded nothing on the undo stack", Actions.canUndo(), undoDepth)
end

-- A press on the track, rather than on the thumb, centres the thumb there instead
-- of paging -- so the same press can carry straight on into a drag.
steps[#steps + 1] = function()
    local metrics = markdownMetrics()

    local trackX = screenX(metrics.trackX + metrics.trackWidth / 2)
    local quarterY = metrics.trackY + metrics.trackHeight * 0.25
    t.press(trackX, screenY(quarterY))
    t.release(trackX, screenY(quarterY))

    local after = markdownMetrics()
    t.check("scroll track: jumped back up toward the click", after.offset < metrics.offset,
        ("%d vs %d"):format(after.offset, metrics.offset))
    t.near("scroll track: the thumb centred on it", after.thumbY + after.thumbHeight / 2,
        quarterY, 2)
end

-- A link's hit test is in the document's coordinates, not the element's, so a
-- scrolled element has to take its offset back out of the point -- otherwise a
-- double-click follows whichever link *used* to be there.
steps[#steps + 1] = function()
    local element = Board:getDocument():getById(markdownId)
    local bodyX, bodyY, width = MarkdownElement.bodyRect(element)
    local layout = MarkdownLayout.build(Markdown.parse(MARKDOWN_SAMPLE), width)
    local link = layout.links[1]

    -- Scrolled so the link sits at the very top of the window. Without the offset
    -- correction the hit test would be asked about the same distance down the
    -- *document*, which is the h1 heading, and find no link at all.
    ContentScroll.setOffset(element, link.y)
    local offset = ContentScroll.offsetOf(element)
    t.near("scroll link: scrolled the link to the top of the window", offset, link.y, 1)

    local opened
    local realOpenURL = love.system.openURL
    love.system.openURL = function(url) opened = url; return true end

    -- Where the link is now, which is well above where it was on screen.
    local px = screenX(bodyX + link.x + link.width / 2)
    local py = screenY(bodyY + link.y + link.height / 2 - offset)
    t.press(px, py, 2)
    t.release(px, py)

    love.system.openURL = realOpenURL
    t.eq("scroll link: followed at its scrolled position", opened,
        "https://www.markdownguide.org/")
    TextEditSession:cancel()
end

-- Growing the element until its content fits retires the scrollbar, and the offset
-- that was valid a moment ago comes back into range on its own rather than leaving
-- the content stranded above the top of the window.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local element = document:getById(markdownId)
    local width, height = element.width, element.height

    element.height = 2000
    Board:update(0)
    t.eq("scroll: no bar once the content fits", markdownMetrics(), nil)
    t.eq("scroll: and nothing to scroll with the wheel", ContentScroll.offsetOf(element), 0)

    -- No bar means the wheel isn't the element's to keep, so it goes on to zoom.
    local zoom0 = Canvas.zoom
    pointAt(element, 40, 80)
    t.wheel(1)
    t.check("scroll wheel: an element with no bar still zooms the canvas",
        Canvas.zoom > zoom0, ("%s vs %s"):format(Canvas.zoom, zoom0))
    Canvas:resetZoom()

    element.width, element.height = width, height
end

-- A note scrolls by exactly the same machinery -- the type answers scrollView and
-- offsets its own drawing, and everything else is ContentScroll's.
steps[#steps + 1] = function()
    local document = Board:getDocument()
    local note = document:getById(noteId)
    note.props.body = ("a line of note text\n"):rep(60)

    local metrics = ContentScroll.metricsOf(note)
    t.check("scroll text: a long note overflows too", metrics ~= nil)
    t.eq("scroll text: starts at the top", metrics.offset, 0)

    pointAt(note, 40, 60)
    t.eq("scroll text: the wheel scrolls it", t.wheel(-1), true)
    t.check("scroll text: content moved", ContentScroll.offsetOf(note) > 0,
        ContentScroll.offsetOf(note))

    note.props.body = ""
    t.eq("scroll text: an empty note has no bar", ContentScroll.metricsOf(note), nil)
end

-- An open multiline field scrolls the same way, off its own offset -- the session's,
-- driven by the caret -- rather than the element's. Only the bar is shared
-- (Style/ScrollBar), which is why these assertions go through TextEditSession and
-- not ContentScroll.

steps[#steps + 1] = function()
    local document = Board:getDocument()
    local note = document:getById(noteId)
    note.props.body = ("line %d of a note that is much too long to fit\n"):rep(40)

    -- Open the body editor by double-clicking it, the way a user would.
    pointAt(note, 40, 60)
    local px, py = screenX(note.x + 40), screenY(note.y + 60)
    t.press(px, py, 2)
    t.release(px, py)

    t.eq("edit scroll: session open on the body",
        TextEditSession:isActive() and TextEditSession:getOwner().prop, "body")

    -- The session's scroll is settled in its update(), which already ran this frame
    -- -- before the press above opened anything. Same one-frame harness artifact
    -- Board:update(0) exists for after an undo (see CLAUDE.md), and the same fix.
    TextEditSession:update(0)

    local bar = TextEditSession:getScrollBar()
    t.check("edit scroll: the field has a bar", bar ~= nil)
    t.check("edit scroll: the thumb is shorter than its track",
        bar.thumbHeight < bar.trackHeight, bar.thumbHeight)
    -- begin() selects all, which leaves the caret at the end -- so the field opens
    -- showing the bottom of the text rather than the top.
    t.check("edit scroll: opened scrolled to the caret", bar.offset > 0, bar.offset)
end

-- Dragging the field's thumb scrolls it, and -- the part that needs the caret
-- anchor -- the view stays where it was dragged instead of snapping back to the
-- caret on the next frame.
steps[#steps + 1] = function()
    local bar = TextEditSession:getScrollBar()
    local grabX = screenX(bar.trackX + bar.trackWidth / 2)

    t.press(grabX, screenY(bar.thumbY + bar.thumbHeight / 2))
    t.moveTo(grabX, screenY(bar.trackY))
    t.release(grabX, screenY(bar.trackY))

    t.near("edit scroll drag: dragged to the top", TextEditSession:getScrollBar().offset, 0, 1)
    t.eq("edit scroll drag: the field is still open", TextEditSession:isActive(), true)
    t.eq("edit scroll drag: and did not move the caret",
        TextEditSession:getEditor():getCaret(), TextEditSession:getEditor():getLength())
end

steps[#steps + 1] = function()
    -- A frame has passed, which is the one that would have yanked the view back to
    -- the caret if updateScrollY chased it unconditionally.
    t.near("edit scroll drag: still where it was dragged, a frame later",
        TextEditSession:getScrollBar().offset, 0, 1)

    -- The wheel over the field scrolls the field, not the element under it.
    local elementOffset = ContentScroll.offsetOf(Board:getDocument():getById(noteId))
    t.eq("edit scroll wheel: consumed by the field", t.wheel(-1), true)
    t.check("edit scroll wheel: the field scrolled",
        TextEditSession:getScrollBar().offset > 0, TextEditSession:getScrollBar().offset)
    t.eq("edit scroll wheel: the element underneath did not",
        ContentScroll.offsetOf(Board:getDocument():getById(noteId)), elementOffset)
end

-- Typing snaps back to the caret, which is what the caret moving is the signal for.
steps[#steps + 1] = function()
    local editor = TextEditSession:getEditor()
    editor:setCaret(0, false)
    t.typeText("x")
    TextEditSession:update(0)

    t.near("edit scroll: typing scrolled back to the caret",
        TextEditSession:getScrollBar().offset, 0, 1)

    t.screenshot("edit-scroll")
end

steps[#steps + 1] = function()
    TextEditSession:cancel()
    Board:getDocument():getById(noteId).props.body = ""
    t.eq("edit scroll: field closed", TextEditSession:isActive(), false)
end

-- The bar itself, scrolled to the middle of a document that overflows: track,
-- proportional thumb, and content clipped at both ends of the window.
steps[#steps + 1] = function()
    local element = Board:getDocument():getById(markdownId)
    local metrics = markdownMetrics()
    ContentScroll.setOffset(element, metrics.maxOffset / 2)

    Board:getSelection():clear()
    Canvas:resetZoom()
    Canvas.offset.x = -element.x + 80
    Canvas.offset.y = -element.y + 80
    Board:update(0)
    t.screenshot("markdown-scrolled")
end

-- The rendering itself, which only a human can check. Drawn through the real draw
-- pass, so this also catches a layout that produces an item the draw loop can't
-- render at all.
steps[#steps + 1] = function()
    local element = Board:getDocument():getById(markdownId)
    Board:getSelection():clear()
    -- Big enough to show the whole sample, and centred so the screenshot has it.
    element.width, element.height = 560, 900
    Canvas:resetZoom()
    Canvas.offset.x = -element.x + 40
    Canvas.offset.y = -element.y + 40
    Board:update(0)
    t.screenshot("markdown")
end

steps[#steps + 1] = function()
    Canvas:resetZoom()
    Canvas.offset.x, Canvas.offset.y = 640, 360
    Board:update(0)
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
    Tools:setActive("text")
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
