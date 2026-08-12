local InputManager = require "application.InputManager"
local Theme = require "application.Style.Theme"
local Color = require "lib.util.math.Color"
local UI = require "application.UI.UI"
local Actions = require "application.Actions"
local Canvas = require "application.Canvas.Canvas"
local Tools = require "application.Canvas.Tools"
local Document = require "application.Canvas.Document"
local Selection = require "application.Canvas.Selection"
local Cursor = require "application.Canvas.Cursor"
local ElementRegistry = require "application.Canvas.ElementRegistry"
local TextEditSession = require "application.Text.TextEditSession"
local DialogManager = require "application.UI.DialogManager"
local AddElement = require "application.Canvas.commands.AddElement"
local RemoveElements = require "application.Canvas.commands.RemoveElements"
local SetProps = require "application.Canvas.commands.SetProps"
local MoveGesture = require "application.Canvas.gestures.MoveGesture"
local ResizeGesture = require "application.Canvas.gestures.ResizeGesture"
local MarqueeGesture = require "application.Canvas.gestures.MarqueeGesture"
local CreateGesture = require "application.Canvas.gestures.CreateGesture"

-- The view and controller over a Document: draws its elements through the canvas
-- transform, turns pointer input into edits, and owns the board's shortcuts.
--
-- Sits at ELEMENT priority, so UI chrome takes clicks first and canvas panning only
-- sees what no element wanted.
--
-- All pointer editing runs through `self.gesture`: at most one at a time, created in
-- mousepressed, advanced in mousemoved, resolved into an undo command in
-- mousereleased. Which one a press starts depends on the active tool (see Tools) and
-- what's under the pointer; what each does afterwards is the gesture's own business
-- (see gestures/Gesture.lua), so nothing here branches on gesture kind.
local Board = {}

ElementRegistry:register(require "application.Canvas.elements.PanelElement")
ElementRegistry:setFallback(require "application.Canvas.elements.UnknownElement")

local DRAG_BUTTON = 1

-- Element text is drawn under the canvas transform, so an inline editor over it has
-- to measure and hit-test in world coordinates and keep its hairlines one screen
-- pixel wide as the zoom changes. See TextEditSession.SCREEN for the other half.
local WORLD_SPACE = {
    name = "world",
    toLocal = function(x, y)
        return Canvas:screenToWorldX(x), Canvas:screenToWorldY(y)
    end,
    toScreen = function(x, y)
        return Canvas:worldToScreenX(x), Canvas:worldToScreenY(y)
    end,
    scale = function()
        return Canvas.zoom
    end,
}

local function isShiftDown()
    return love.keyboard.isDown("lshift", "rshift")
end

local function isCtrlDown()
    return love.keyboard.isDown("lctrl", "rctrl") or love.keyboard.isDown("lgui", "rgui")
end

-- Temporary: the startup board is prefilled so there's something to look at and
-- something to save. File > New already opens an empty board, and the Panel tool can
-- fill one, so this is only still here as the quickest way to have content to test
-- against.
local function seed(document)
    local titles = { "Design Notes", "Enemy Behaviour", "TODO" }
    for index, title in ipairs(titles) do
        local element = ElementRegistry:create("panel", -320 + (index - 1) * 280, -80)
        element.props.title = title
        document:execute(AddElement.new(element))
    end

    -- The starting content isn't an edit the user made, so it shouldn't be sitting
    -- on the undo stack waiting to be undone out from under them.
    document.history:clear()
end

function Board:load()
    self.selection = Selection.new()
    self.time = 0
    -- Reused rather than rebuilt per frame; refreshed at the top of draw().
    self.drawContext = { zoom = 1 }

    self:setDocument(Document.new())
    seed(self.document)

    InputManager:subscribeAll(InputManager.MOUSE_EVENTS, self, InputManager.PRIORITY.ELEMENT)
    InputManager:subscribe("keypressed", self, InputManager.PRIORITY.ELEMENT)
end

function Board:getDocument()
    return self.document
end

function Board:getSelection()
    return self.selection
end

-- Swaps in a whole new document -- opening a file, or File > New.
--
-- Selection and any gesture in progress refer to elements in the outgoing document,
-- so both are dropped: a gesture holding ids that no longer exist would keep running
-- against a document that's already gone.
function Board:setDocument(document)
    -- An open inline editor holds an element id from the outgoing document, and its
    -- commit would land on an element that's no longer on the board.
    TextEditSession:cancel()

    self.document = document
    self.selection:clear()
    self.gesture = nil
end

-- ── Selection edits ──────────────────────────────────────────────────────

-- Deletes every selected element as one undo step. No-ops on an empty selection so
-- Delete/Backspace and Edit > Delete can call it unconditionally.
function Board:deleteSelection()
    local ids = self.document:selectedIds(self.selection)
    if #ids == 0 then
        return false
    end

    self.document:execute(RemoveElements.new(ids))
    self.selection:clear()
    return true
end

function Board:selectAll()
    -- Replaces rather than unions: "select all" is a statement about the final
    -- selection, and starting from whatever was already selected can only differ from
    -- that by leaving stale ids in.
    self.selection:clear()
    for _, id in ipairs(self.document:allIds()) do
        self.selection:add(id)
    end
    return not self.selection:isEmpty()
end

function Board:deselectAll()
    if self.selection:isEmpty() then
        return false
    end
    self.selection:clear()
    return true
end

-- ── Drawing ──────────────────────────────────────────────────────────────

function Board:update(dt)
    -- Accumulated rather than read off a wall clock: os.clock() is CPU time on
    -- Windows, so the pulse below would speed up and slow down with load.
    self.time = self.time + dt
    self:pruneSelection()
end

-- Hoisted rather than closed over the document per call: this runs every frame, and
-- reading the document off Board keeps it correct across a document swap for free.
local function isLiveElement(id)
    return Board.document:getById(id) ~= nil
end

-- Drops selected ids whose element is no longer on the board.
--
-- Undo and redo move elements in and out from under the selection -- undoing a create
-- leaves behind the id of something that doesn't exist any more -- and a stale id is
-- visible rather than harmless: it inflates the status bar's count, and it would make
-- a group action quietly touch fewer elements than the count claims.
--
-- Unconditional, because there's no cheap signal that says "the document changed in a
-- way that could have invalidated an id". History's state token is the obvious
-- candidate and the wrong one: undoing deliberately returns a token the document has
-- already had, so a check against the last-seen value skips exactly the case this
-- exists for. A pass over the selected ids is bounded by the selection, not the board.
function Board:pruneSelection()
    if self.selection:isEmpty() then
        return
    end
    self.selection:retain(isLiveElement)
end

-- The context handed to every element type's draw(). Refreshed once per frame at the
-- top of draw(); a gesture drawing a pending element reads the same one.
function Board:getDrawContext()
    return self.drawContext
end

function Board:draw()
    local context = self.drawContext
    context.zoom = Canvas.zoom

    -- Which label, if any, an element type should leave to the inline editor rather
    -- than drawing itself. Read from the session rather than tracked here, so a
    -- commit triggered by a click anywhere can't leave this stale.
    local editing = TextEditSession:getOwner()
    context.editingId = editing and editing.id or nil
    context.editingProp = editing and editing.prop or nil

    love.graphics.push()
    love.graphics.translate(Canvas.offset.x, Canvas.offset.y)
    love.graphics.scale(Canvas.zoom)

    -- Back to front: array order is z-order.
    for _, element in ipairs(self.document.elements) do
        ElementRegistry:draw(element, context)
    end

    -- Over the elements but under the selection outlines, which suits both gestures
    -- that draw: the pending element belongs in front of the board it's about to join,
    -- and a marquee's tint shouldn't wash out the outlines of what it has picked up.
    if self.gesture and self.gesture.draw then
        self.gesture:draw()
    end

    self:drawSelectionOutlines()

    -- Inside the transform: the field is anchored to an element, so it pans and zooms
    -- with it.
    TextEditSession:drawIn("world")

    love.graphics.pop()
end

local SELECTION_OUTLINE_MARGIN = 3
-- Radians per second of the outline's colour cycle.
local SELECTION_PULSE_RATE = 5

-- Written into every frame rather than allocated: this is the one colour on screen
-- that changes continuously, and Theme's cache can't hold a value that never settles.
local pulseColor = Color.new()

-- Drawn generically from each element's rect rather than by the element type
-- itself, so a new element type is selectable without having to draw its own
-- outline.
function Board:drawSelectionOutlines()
    if self.selection:isEmpty() then
        return
    end

    local r, g, b, a = love.graphics.getColor()
    local previousLineWidth = love.graphics.getLineWidth()

    local blend = (math.sin(self.time * SELECTION_PULSE_RATE) + 1) / 2
    local color = Theme:color("selection"):mix(Theme:color("selectionAlt"), blend, pulseColor)

    love.graphics.setColor(color:unpacked())
    love.graphics.setLineWidth(Theme:metric("selectionWidth") / Canvas.zoom)

    local margin = SELECTION_OUTLINE_MARGIN / Canvas.zoom
    local radius = Theme:metric("cornerRadius")

    for _, element in ipairs(self.document.elements) do
        if self.selection:contains(element.id) then
            love.graphics.rectangle("line",
                element.x - margin, element.y - margin,
                element.width + margin * 2, element.height + margin * 2, radius, radius)
        end
    end

    love.graphics.setLineWidth(previousLineWidth)
    love.graphics.setColor(r, g, b, a)
end

-- ── Inline text editing ──────────────────────────────────────────────────

-- Opens the shared editor over one of an element's text fields (see
-- ElementRegistry:textFields). Enter or a click elsewhere keeps the edit, Escape
-- throws it away; the session handles all of that and calls back here.
--
-- Only ids cross into the callbacks. The session outlives the click that opened it,
-- and both the element table and the field rect can be gone or stale by the time it
-- ends, so each callback looks the element up again.
function Board:beginTextEdit(element, field)
    local id = element.id
    local prop = field.prop

    TextEditSession:begin({
        text = element.props[prop],
        space = WORLD_SPACE,
        font = field.font,
        color = field.color,
        owner = { id = id, prop = prop },

        -- Re-read every frame: the panel behind the field can still be panned and
        -- zoomed under it.
        getRect = function()
            local live = self.document:getById(id)
            local current = live and ElementRegistry:textField(live, prop)
            if not current then
                return nil
            end
            return current.x, current.y, current.width, current.height
        end,

        onCommit = function(text)
            local live = self.document:getById(id)
            -- A rename that changed nothing shouldn't land on the undo stack, or mark
            -- the board dirty.
            if live and live.props[prop] ~= text then
                self.document:execute(SetProps.capture(live, { [prop] = text }))
            end
        end,
    })
end

-- F2 on a single selected element, the keyboard route to the same thing a
-- double-click does. Ambiguous for a multi-selection, so it does nothing there.
function Board:beginTextEditOnSelection()
    local ids = self.document:selectedIds(self.selection)
    if #ids ~= 1 then
        return false
    end

    local element = self.document:getById(ids[1])
    local field = element and ElementRegistry:textFields(element)[1]
    if not field then
        return false
    end

    self:beginTextEdit(element, field)
    return true
end

-- ── Pointer input ────────────────────────────────────────────────────────

function Board:mousepressed(x, y, button, istouch, presses)
    if button ~= DRAG_BUTTON then
        return false
    end

    local worldX = Canvas:screenToWorldX(x)
    local worldY = Canvas:screenToWorldY(y)
    local shiftHeld = isShiftDown()

    -- A creation tool owns the whole canvas: it doesn't matter what's under the
    -- pointer, so this comes before any hit testing. Elements can still be selected
    -- and moved by switching back to the select tool.
    local createType = Tools:getActive().createType
    if createType then
        self.gesture = CreateGesture.new(self, createType, worldX, worldY)
        return true
    end

    local element, handle = self.document:handleAt(worldX, worldY, Canvas.zoom)

    if not element then
        self.gesture = MarqueeGesture.new(self, worldX, worldY, shiftHeld)
        return true
    end

    -- Resize handles always focus down to the single element being resized;
    -- group-resizing several elements at once isn't supported.
    if handle and handle ~= "move" then
        self.selection:set(element.id)
        self.gesture = ResizeGesture.new(self, element, handle, worldX, worldY)
        return true
    end

    -- Double-click on a label edits it. Checked after the resize handles so a quick
    -- double-click on an edge still resizes, and before the move/select logic so the
    -- second click doesn't start a drag.
    if presses and presses >= 2 then
        local field = ElementRegistry:textFieldAt(element, worldX, worldY)
        if field then
            self.selection:set(element.id)
            self:beginTextEdit(element, field)
            return true
        end
    end

    if shiftHeld then
        self.selection:toggle(element.id)
    elseif not self.selection:contains(element.id) then
        self.selection:set(element.id)
    end
    -- else: element is already part of a multi-selection and shift isn't held --
    -- leave the group as-is so a header drag can move all of it.

    if handle == "move" and self.selection:contains(element.id) then
        self.gesture = MoveGesture.new(self, worldX, worldY)
    end

    return true
end

function Board:mousemoved(x, y, dx, dy, istouch)
    if self.gesture then
        self.gesture:move(Canvas:screenToWorldX(x), Canvas:screenToWorldY(y))
        return true
    end

    self:updateHoverCursor(x, y)
    return false
end

-- Idle hover affordances. Returns nothing useful -- mousemoved is broadcast, so
-- consuming it wouldn't stop anything anyway; this is only about which cursor the
-- pointer should be showing.
function Board:updateHoverCursor(x, y)
    -- A modal dialog owns the pointer everywhere while it's open, not just over its
    -- own rect, so this is a state check rather than a position query like
    -- isPointOverUI below -- same reason TextEditSession gets its own check rather
    -- than going through isPointOverUI too.
    if DialogManager:isOpen() then
        Cursor:reset()
        return
    end

    -- Only show affordances when the pointer isn't sitting over the chrome.
    -- mousemoved reaches every handler regardless of who consumed it (see
    -- InputManager's broadcast note), so consumption alone can't tell us that --
    -- this is a direct position query against the UI instead.
    if UI:isPointOverUI(x, y) then
        Cursor:reset()
        return
    end

    -- An open field owns the pointer over itself: an I-beam there, and no resize or
    -- move affordances from the element underneath, which can't be grabbed anyway
    -- while the session is swallowing input.
    if TextEditSession:isActive() then
        Cursor:setForHandle(TextEditSession:containsPoint(x, y) and "text" or nil)
        return
    end

    -- A creation tool ignores what's under the pointer, so there are no move or
    -- resize affordances to show -- just the crosshair, everywhere on the canvas.
    if Tools:getActive().createType then
        Cursor:setForHandle("create")
        return
    end

    local worldX = Canvas:screenToWorldX(x)
    local worldY = Canvas:screenToWorldY(y)
    local _, handle = self.document:handleAt(worldX, worldY, Canvas.zoom)
    Cursor:setForHandle(handle)
end

-- Resolving a gesture is the same three steps whatever it was: clear the slot first
-- (so anything the command triggers can't find a gesture still half-running), ask it
-- for its command, and record that command the way it asks to be recorded.
function Board:mousereleased(x, y, button, istouch, presses)
    if button ~= DRAG_BUTTON or not self.gesture then
        return false
    end

    local gesture = self.gesture
    self.gesture = nil

    local command, alreadyApplied = gesture:finish()
    if command then
        if alreadyApplied then
            self.document:pushApplied(command)
        else
            self.document:execute(command)
        end
    end

    return true
end

-- ── Keyboard shortcuts ───────────────────────────────────────────────────

function Board:keypressed(key, scancode, isrepeat)
    -- Rename the selected element. Not a Ctrl shortcut, so it's checked first.
    if key == "f2" then
        return self:beginTextEditOnSelection()
    end

    -- Delete the selection. Also not a Ctrl shortcut. Doesn't consume on an empty
    -- selection, so Backspace still falls through to whatever else it might have done.
    if key == "delete" or key == "backspace" then
        return Actions.delete()
    end

    -- lgui/rgui so Cmd works if this ever runs on macOS.
    if not isCtrlDown() then
        return self:unmodifiedKeypressed(key)
    end

    return self:shortcutKeypressed(key)
end

-- Plain unmodified keys. Safe to claim here because a text field consumes every key
-- while it's open (see TextEditSession), so these can't fire mid-typing.
function Board:unmodifiedKeypressed(key)
    -- Escape backs out one step at a time: first whatever tool is active, then the
    -- selection. Only consumed when it actually did something.
    if key == "escape" then
        if not Tools:isActive(Tools.SELECT) then
            Tools:reset()
            return true
        end
        return Actions.deselectAll()
    end

    local tool = Tools:forShortcut(key)
    if tool then
        Tools:setActive(tool.name)
        return true
    end

    return false
end

-- Ctrl-modified keys. Routed through Actions so the menu items and these shortcuts
-- can't drift apart; each returns whether it did anything, but the shortcut is
-- consumed either way -- Ctrl+Z on an empty undo stack is still a claimed key.
function Board:shortcutKeypressed(key)
    if key == "z" then
        if isShiftDown() then Actions.redo() else Actions.undo() end
    elseif key == "y" then
        Actions.redo()
    elseif key == "a" then
        Actions.selectAll()
    elseif key == "0" then
        Actions.resetZoom()
    -- Both the unshifted and shifted spellings of the +/- keys, and the keypad's:
    -- Ctrl+= is what "zoom in" actually is on a US layout without reaching for Shift.
    elseif key == "=" or key == "+" or key == "kp+" then
        Actions.zoomIn()
    elseif key == "-" or key == "kp-" then
        Actions.zoomOut()
    else
        return false
    end

    return true
end

return Board
