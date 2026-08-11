local InputManager = require "application.InputManager"
local Theme = require "application.Style.Theme"
local UI = require "application.UI.UI"
local Canvas = require "application.Canvas.Canvas"
local Document = require "application.Canvas.Document"
local Selection = require "application.Canvas.Selection"
local Cursor = require "application.Canvas.Cursor"
local RectResize = require "application.Canvas.RectResize"
local ElementRegistry = require "application.Canvas.ElementRegistry"
local TextEditSession = require "application.Text.TextEditSession"
local DialogManager = require "application.UI.DialogManager"
local AddElement = require "application.Canvas.commands.AddElement"
local MoveElements = require "application.Canvas.commands.MoveElements"
local ResizeElement = require "application.Canvas.commands.ResizeElement"
local ReorderElement = require "application.Canvas.commands.ReorderElement"
local Composite = require "application.Canvas.commands.Composite"
local SetProps = require "application.Canvas.commands.SetProps"

-- The view and controller over a Document: draws its elements through the canvas
-- transform, turns pointer input into selection/move/resize edits, and owns the
-- edit shortcuts.
--
-- Sits at ELEMENT priority, so UI chrome takes clicks first and canvas panning only
-- sees what no element wanted.
--
-- At most one of self.drag / self.resize / self.marquee is active at a time; each
-- is a small table describing the gesture in progress, created in mousepressed,
-- advanced in mousemoved, and resolved into an undo command in mousereleased.
local Board = {}

ElementRegistry:register(require "application.Canvas.elements.PanelElement")
ElementRegistry:setFallback(require "application.Canvas.elements.UnknownElement")

local DRAG_BUTTON = 1

-- Reused rather than rebuilt per frame.
local drawContext = { zoom = 1 }

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
-- something to save. Drop it once there's a way to create an element (TODO 2) --
-- File > New already opens an empty board, which is what a new board should be.
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
    self:setDocument(Document.new())

    seed(self.document)

    InputManager:subscribeAll(InputManager.MOUSE_EVENTS, self, InputManager.PRIORITY.ELEMENT)
    InputManager:subscribe("keypressed", self, InputManager.PRIORITY.ELEMENT)
end

function Board:getDocument()
    return self.document
end

-- Swaps in a whole new document -- opening a file, or File > New.
--
-- Selection and any gesture in progress refer to elements in the outgoing document,
-- so both are dropped: a drag holding ids that no longer exist would keep running
-- against a document that's already gone.
function Board:setDocument(document)
    -- An open inline editor holds an element id from the outgoing document, and its
    -- commit would land on an element that's no longer on the board.
    TextEditSession:cancel()

    self.document = document
    self.selection:clear()
    self.drag = nil
    self.resize = nil
    self.marquee = nil
    self.marqueeBase = nil
end

function Board:getSelection()
    return self.selection
end

-- ── Drawing ──────────────────────────────────────────────────────────────

function Board:draw()
    drawContext.zoom = Canvas.zoom

    -- Which label, if any, an element type should leave to the inline editor rather
    -- than drawing itself. Read from the session rather than tracked here, so a
    -- commit triggered by a click anywhere can't leave this stale.
    local editing = TextEditSession:getOwner()
    drawContext.editingId = editing and editing.id or nil
    drawContext.editingProp = editing and editing.prop or nil

    love.graphics.push()
    love.graphics.translate(Canvas.offset.x, Canvas.offset.y)
    love.graphics.scale(Canvas.zoom)

    -- Back to front: array order is z-order.
    for _, element in ipairs(self.document.elements) do
        ElementRegistry:draw(element, drawContext)
    end

    self:drawSelectionOutlines()
    -- Inside the transform: the field is anchored to an element, so it pans and zooms
    -- with it.
    TextEditSession:drawIn("world")
    self:drawMarquee()

    love.graphics.pop()
end

local SELECTION_OUTLINE_MARGIN = 3

-- Drawn generically from each element's rect rather than by the element type
-- itself, so a new element type is selectable without having to draw its own
-- outline.
function Board:drawSelectionOutlines()
    if self.selection:isEmpty() then
        return
    end

    local r, g, b, a = love.graphics.getColor()
    local previousLineWidth = love.graphics.getLineWidth()
    local margin = SELECTION_OUTLINE_MARGIN / Canvas.zoom

    local scolor1 = Theme:color("selection")
    local scolor2 = Theme:color("selectionAlt")
    local scolorlerp = scolor1:lerp(scolor2, (math.sin(os.clock() * 5) + 1)/2.0)


    love.graphics.setColor(scolorlerp:unpacked())
    love.graphics.setLineWidth(Theme:metric("selectionWidth") / Canvas.zoom)
    local radius = Theme:metric("cornerRadius") or 0

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

function Board:drawMarquee()
    if not self.marquee then
        return
    end

    local minX, maxX = math.min(self.marquee.startX, self.marquee.currentX), math.max(self.marquee.startX, self.marquee.currentX)
    local minY, maxY = math.min(self.marquee.startY, self.marquee.currentY), math.max(self.marquee.startY, self.marquee.currentY)

    local r, g, b, a = love.graphics.getColor()
    local previousLineWidth = love.graphics.getLineWidth()

    love.graphics.setColor(Theme:color("marqueeFill"):unpacked())
    love.graphics.rectangle("fill", minX, minY, maxX - minX, maxY - minY)

    love.graphics.setColor(Theme:color("marqueeBorder"):unpacked())
    love.graphics.setLineWidth(1 / Canvas.zoom)
    love.graphics.rectangle("line", minX, minY, maxX - minX, maxY - minY)

    love.graphics.setLineWidth(previousLineWidth)
    love.graphics.setColor(r, g, b, a)
end

-- ── Gesture setup ────────────────────────────────────────────────────────

function Board:beginMove(worldX, worldY)
    local ids = self.selection:list()
    local raised = self.document:raiseAllToFront(ids)

    local origins = {}
    for _, id in ipairs(ids) do
        local element = self.document:getById(id)
        origins[id] = { x = element.x, y = element.y }
    end

    self.drag = {
        ids = ids,
        origins = origins,
        pointerX = worldX,
        pointerY = worldY,
        raised = raised,
    }
end

function Board:beginResize(element, handle, worldX, worldY)
    local minWidth, minHeight = ElementRegistry:minSize(element.type)

    self.resize = {
        id = element.id,
        handle = handle,
        origin = { x = element.x, y = element.y, width = element.width, height = element.height },
        pointerX = worldX,
        pointerY = worldY,
        minWidth = minWidth,
        minHeight = minHeight,
        -- Single element, so the simpler count()-based toIndex from the old
        -- single-drag code is valid here: resizing never adds or removes elements,
        -- so the element's index right after this raise stays put until release.
        raisedFrom = self.document:raiseToFront(element.id),
    }
end

function Board:beginMarquee(worldX, worldY, additive)
    self.marqueeBase = additive and self.selection:list() or {}
    self.marquee = {
        startX = worldX, startY = worldY,
        currentX = worldX, currentY = worldY,
    }

    if not additive then
        self.selection:clear()
    end
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

        -- Re-read every frame: the panel behind the field can still be scrolled and
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
    local ids = self.selection:list()
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

    local element, handle = self.document:handleAt(worldX, worldY, Canvas.zoom)

    if not element then
        self:beginMarquee(worldX, worldY, shiftHeld)
        return true
    end

    -- Resize handles always focus down to the single element being resized;
    -- group-resizing several elements at once isn't supported.
    if handle and handle ~= "move" then
        self.selection:set(element.id)
        self:beginResize(element, handle, worldX, worldY)
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
        self:beginMove(worldX, worldY)
    end

    return true
end

function Board:mousemoved(x, y, dx, dy, istouch)
    if self.drag or self.resize or self.marquee then
        local worldX = Canvas:screenToWorldX(x)
        local worldY = Canvas:screenToWorldY(y)

        if self.drag then
            self:updateMove(worldX, worldY)
        elseif self.resize then
            self:updateResize(worldX, worldY)
        else
            self:updateMarquee(worldX, worldY)
        end
        return true
    end

    -- A modal dialog owns the pointer everywhere while it's open, not just over its
    -- own rect, so this is a state check rather than a position query like
    -- isPointOverUI below -- same reason TextEditSession gets its own check rather
    -- than going through isPointOverUI too.
    if DialogManager:isOpen() then
        Cursor:reset()
        return false
    end

    -- Idle hover: only show resize/move affordances when the pointer isn't sitting
    -- over the chrome. mousemoved reaches every handler regardless of who consumed
    -- it (see InputManager's broadcast note), so consumption alone can't tell us
    -- that -- this is a direct position query against the UI instead.
    if UI:isPointOverUI(x, y) then
        Cursor:reset()
        return false
    end

    -- An open field owns the pointer over itself: an I-beam there, and no resize or
    -- move affordances from the element underneath, which can't be grabbed anyway
    -- while the session is swallowing input.
    if TextEditSession:isActive() then
        Cursor:setForHandle(TextEditSession:containsPoint(x, y) and "text" or nil)
        return false
    end

    local worldX = Canvas:screenToWorldX(x)
    local worldY = Canvas:screenToWorldY(y)
    local _, handle = self.document:handleAt(worldX, worldY, Canvas.zoom)
    Cursor:setForHandle(handle)

    return handle ~= nil
end

function Board:updateMove(worldX, worldY)
    local dx = worldX - self.drag.pointerX
    local dy = worldY - self.drag.pointerY

    for _, id in ipairs(self.drag.ids) do
        local element = self.document:getById(id)
        local origin = self.drag.origins[id]
        if element and origin then
            element:setPosition(origin.x + dx, origin.y + dy)
        end
    end
end

function Board:updateResize(worldX, worldY)
    local resize = self.resize
    local element = self.document:getById(resize.id)
    if not element then
        return
    end

    local dx = worldX - resize.pointerX
    local dy = worldY - resize.pointerY

    element.x, element.y, element.width, element.height =
        RectResize.apply(resize.handle, resize.origin, dx, dy, resize.minWidth, resize.minHeight)
end

function Board:updateMarquee(worldX, worldY)
    self.marquee.currentX = worldX
    self.marquee.currentY = worldY

    local minX = math.min(self.marquee.startX, worldX)
    local maxX = math.max(self.marquee.startX, worldX)
    local minY = math.min(self.marquee.startY, worldY)
    local maxY = math.max(self.marquee.startY, worldY)

    self.selection:clear()
    for _, id in ipairs(self.marqueeBase) do
        self.selection:add(id)
    end

    for _, element in ipairs(self.document.elements) do
        local overlaps = element.x <= maxX and element.x + element.width >= minX
            and element.y <= maxY and element.y + element.height >= minY
        if overlaps then
            self.selection:add(element.id)
        end
    end
end

function Board:mousereleased(x, y, button, istouch, presses)
    if button ~= DRAG_BUTTON then
        return false
    end

    if self.marquee then
        self.marquee = nil
        self.marqueeBase = nil
        return true
    end

    if self.resize then
        self:endResize()
        return true
    end

    if self.drag then
        self:endMove()
        return true
    end

    return false
end

function Board:endMove()
    local drag = self.drag
    self.drag = nil

    -- One undo step for the whole gesture, so Ctrl+Z returns every moved element to
    -- where it was -- and to the depth it was at -- when the drag started, rather
    -- than stepping back through every frame of it or leaving the group raised.
    --
    -- Both effects are already in the document: the elements followed the pointer
    -- live and were raised on grab. So these record without re-applying.
    local commands = {}

    for _, r in ipairs(drag.raised) do
        table.insert(commands, ReorderElement.new(r.id, r.fromIndex, r.toIndex))
    end

    -- The group moves rigidly, so any moved element's own delta represents the
    -- whole gesture.
    local sampleId = drag.ids[1]
    if sampleId then
        local element = self.document:getById(sampleId)
        local origin = drag.origins[sampleId]
        if element and origin then
            local dx = element.x - origin.x
            local dy = element.y - origin.y
            if dx ~= 0 or dy ~= 0 then
                table.insert(commands, MoveElements.new(drag.ids, dx, dy))
            end
        end
    end

    self:pushGesture(commands)
end

function Board:endResize()
    local resize = self.resize
    self.resize = nil

    local commands = {}

    if resize.raisedFrom then
        table.insert(commands, ReorderElement.new(resize.id, resize.raisedFrom, self.document:count()))
    end

    local element = self.document:getById(resize.id)
    if element then
        local dx = element.x - resize.origin.x
        local dy = element.y - resize.origin.y
        local dWidth = element.width - resize.origin.width
        local dHeight = element.height - resize.origin.height
        if dx ~= 0 or dy ~= 0 or dWidth ~= 0 or dHeight ~= 0 then
            table.insert(commands, ResizeElement.new(resize.id, dx, dy, dWidth, dHeight))
        end
    end

    self:pushGesture(commands)
end

function Board:pushGesture(commands)
    if #commands == 1 then
        self.document:pushApplied(commands[1])
    elseif #commands > 1 then
        self.document:pushApplied(Composite.new(commands))
    end
end

-- ── Keyboard shortcuts ───────────────────────────────────────────────────

function Board:keypressed(key, scancode, isrepeat)
    -- Rename the selected element. Not a Ctrl shortcut, so it's checked first.
    if key == "f2" then
        return self:beginTextEditOnSelection()
    end

    -- lgui/rgui so Cmd works if this ever runs on macOS.
    if not isCtrlDown() then
        return false
    end

    if key == "z" then
        if isShiftDown() then
            self.document:redo()
        else
            self.document:undo()
        end
    elseif key == "y" then
        self.document:redo()
    else
        return false
    end

    -- Consume the shortcut whether or not the stack had anything left in it.
    return true
end

return Board
