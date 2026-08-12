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
local ElementRegistry = require "application.Canvas.ElementRegistry"
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
    t.eq("round trip: re-encodes byte-identically", Serialize.encode(reopened:toData()), before)
    t.eq("round trip: board is clean after opening", BoardFile:isDirty(), false)
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

return steps
