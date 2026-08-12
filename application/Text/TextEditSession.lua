local InputManager = require "application.InputManager"
local Theme = require "application.Style.Theme"
local Clip = require "application.Style.Clip"
local TextEditor = require "application.Text.TextEditor"

-- The one text field being edited anywhere in the app, and everything a TextEditor
-- deliberately doesn't do: input routing, drawing, and turning a click into a caret
-- position.
--
-- There is at most one session at a time -- starting a second commits the first --
-- which is what makes this a singleton rather than something each field owns. Nothing
-- else can be typed into while one is open: it sits at MODAL priority and consumes
-- every key, so Ctrl+S and Ctrl+Z don't fire while you're typing an S or a Z.
--
-- It subscribes once, in load(), and no-ops while inactive rather than subscribing
-- when an edit starts: a session normally opens from inside a mousepressed callback,
-- and InputManager walks its handler list in place, so subscribing there would mutate
-- a list mid-dispatch.
--
-- Commit/cancel is the caller's contract, but the rules are fixed and match every
-- rename field: Enter or clicking away keeps the edit, Escape discards it.
local TextEditSession = {}

-- Where the field lives. The session draws and hit-tests through this, which is what
-- lets one editor serve a canvas element (world space, under the canvas transform)
-- and a UI widget (screen space) without knowing about either:
--
--   name     which draw pass renders it -- see drawIn
--   toLocal  a screen point -> the space getRect() reports in
--   toScreen the inverse, for the one thing that has to be told screen pixels: the
--            rect handed to love.keyboard.setTextInput
--   scale    pixels per unit of that space, so hairlines stay one pixel wide
TextEditSession.SCREEN = {
    name = "screen",
    toLocal = function(x, y) return x, y end,
    toScreen = function(x, y) return x, y end,
    scale = function() return 1 end,
}

-- How far the field's box extends past the text rect it's given.
local FIELD_PADDING_X = 0
local FIELD_PADDING_Y = 0

local CARET_BLINK = 0.53
local SELECT_BUTTON = 1

function TextEditSession:load()
    self.request = nil
    self.editor = nil
    self.blink = 0
    self.scroll = 0
    self.dragging = false
    self.composition = ""

    InputManager:subscribe("keypressed", self, InputManager.PRIORITY.MODAL)
    InputManager:subscribe("textinput", self, InputManager.PRIORITY.MODAL)
    InputManager:subscribe("textedited", self, InputManager.PRIORITY.MODAL)
    -- Not wheelmoved: zooming or scrolling the thing underneath while a field is open
    -- is harmless, and the field follows it.
    InputManager:subscribe("mousepressed", self, InputManager.PRIORITY.MODAL)
    InputManager:subscribe("mousemoved", self, InputManager.PRIORITY.MODAL)
    InputManager:subscribe("mousereleased", self, InputManager.PRIORITY.MODAL)
end

-- ── Sessions ─────────────────────────────────────────────────────────────

-- request:
--   text      the starting value
--   getRect   function() -> x, y, width, height  -- the *text* rect, in space's
--             coordinates, re-read every frame so the field tracks whatever moved
--   space     one of the space tables above; defaults to SCREEN
--   font      theme token or Font
--   color     theme token or Color, for the text
--   maxLength optional character limit
--   owner     opaque, handed back by getOwner() so a caller can recognise its own
--             session (the board uses it to stop drawing the label it's editing)
--   onCommit  function(text), called with the final value when the edit is kept
--   onCancel  optional function(), called when the edit is discarded
--
-- Opens with everything selected, so typing replaces -- the usual rename behaviour.
function TextEditSession:begin(request)
    self:commit()

    request.space = request.space or self.SCREEN

    self.request = request
    self.editor = TextEditor.new(request.text, { maxLength = request.maxLength })
    self.editor:selectAll()
    self.blink = 0
    self.scroll = 0
    self.dragging = false
    self.composition = ""
    self:updateTextInput()

    return self.editor
end

-- LOVE 12 is on SDL3, which starts with text input *off*: love.textinput never fires
-- until something asks for it, and keys still arrive through keypressed, so the
-- symptom is a field you can backspace in but not type into.
--
-- Scoped to the open session rather than switched on globally, because the rect that
-- goes with it is what tells an IME (and a mobile on-screen keyboard) where the text
-- being composed actually is. Re-pushed only when that rect moves, since panning or
-- zooming under an open field changes it every frame.
function TextEditSession:updateTextInput()
    if not self.editor then
        self.inputRect = nil
        love.keyboard.setTextInput(false)
        return
    end

    local x, y, width, height = self:getRect()
    if not x then
        return
    end

    local space = self.request.space
    local screenX, screenY = space.toScreen(x, y)
    local endX, endY = space.toScreen(x + width, y + height)

    local rect = self.inputRect
    if rect and rect[1] == screenX and rect[2] == screenY
        and rect[3] == endX and rect[4] == endY then
        return
    end

    self.inputRect = { screenX, screenY, endX, endY }
    love.keyboard.setTextInput(true, screenX, screenY, endX - screenX, endY - screenY)
end

function TextEditSession:isActive()
    return self.editor ~= nil
end

function TextEditSession:getEditor()
    return self.editor
end

function TextEditSession:getOwner()
    return self.request and self.request.owner
end

-- Clears the session *before* the callback runs: committing can start another edit
-- (or delete the element), and neither should be fighting a session that's still
-- half-open.
function TextEditSession:finish()
    local request, editor = self.request, self.editor
    self.request = nil
    self.editor = nil
    self.dragging = false
    self.composition = ""
    self:updateTextInput()
    return request, editor
end

function TextEditSession:commit()
    if not self.editor then
        return false
    end

    local request, editor = self:finish()
    request.onCommit(editor:getText())
    return true
end

function TextEditSession:cancel()
    if not self.editor then
        return false
    end

    local request = self:finish()
    if request.onCancel then
        request.onCancel()
    end
    return true
end

-- ── Layout ───────────────────────────────────────────────────────────────

function TextEditSession:getFont()
    local font = self.request.font
    if type(font) == "string" then
        return Theme:font(font)
    end
    return font or love.graphics.getFont()
end

function TextEditSession:getRect()
    return self.request.getRect()
end

-- Distance from the start of the text to a caret offset. Measured on the substring
-- rather than summed per character so kerning is accounted for.
function TextEditSession:offsetOf(index)
    return self:getFont():getWidth(self.editor:sub(0, index))
end

-- The caret offset nearest a point in the field's space: the boundary the click is
-- closest to, so clicking the right half of a character puts the caret after it.
--
-- Linear in the length of the text and quadratic in substring work; fields hold
-- titles, and this runs on a click, not per frame.
function TextEditSession:indexAt(localX)
    local x = self:getRect()
    local target = localX - x + self.scroll

    local best, bestDistance = 0, math.abs(target)
    for index = 1, self.editor:getLength() do
        local distance = math.abs(target - self:offsetOf(index))
        if distance < bestDistance then
            best, bestDistance = index, distance
        end
    end

    return best
end

-- Hit testing uses the drawn box, not the bare text rect, so the few pixels of
-- padding around the text still count as inside the field.
function TextEditSession:containsPoint(screenX, screenY)
    if not self.editor then
        return false
    end

    local x, y, width, height = self:getRect()
    if not x then
        return false
    end

    local localX, localY = self.request.space.toLocal(screenX, screenY)
    return localX >= x - FIELD_PADDING_X and localX <= x + width + FIELD_PADDING_X
       and localY >= y - FIELD_PADDING_Y and localY <= y + height + FIELD_PADDING_Y
end

-- Keeps the caret inside the field once the text outgrows it, without leaving blank
-- space on the right while there's text scrolled off the left.
function TextEditSession:updateScroll(width)
    local font = self:getFont()
    local textWidth = font:getWidth(self.editor:getText())
    local caretX = self:offsetOf(self.editor:getCaret())

    local scroll = math.min(self.scroll, math.max(0, textWidth - width))
    scroll = math.min(scroll, caretX)
    -- The +1 keeps the caret line itself inside the clip when it sits at the very end.
    scroll = math.max(scroll, caretX - width + 1)

    self.scroll = math.max(0, scroll)
end

function TextEditSession:update(dt)
    if not self.editor then
        return
    end

    local _, _, width = self:getRect()
    if not width then
        -- Whatever was being edited is gone -- a document swap, say. Discard rather
        -- than commit: there's nothing left to commit onto.
        self:cancel()
        return
    end

    self.blink = self.blink + dt
    self:updateScroll(width)
    self:updateTextInput()
end

-- ── Drawing ──────────────────────────────────────────────────────────────

-- Called from both draw passes; renders only when the space matches, so the board
-- draws world-space fields inside its transform and the app draws screen-space ones
-- over the chrome.
function TextEditSession:drawIn(space)
    if not self.editor or self.request.space.name ~= space then
        return
    end

    local x, y, width, height = self:getRect()
    if not x then
        return
    end

    local editor = self.editor
    local font = self:getFont()
    local pixel = 1 / self.request.space.scale()

    local r, g, b, a = love.graphics.getColor()
    local previousFont = love.graphics.getFont()
    local previousLineWidth = love.graphics.getLineWidth()

    -- A filled box with an accent border: the label has visibly become something you
    -- can type into.
    local boxX, boxY = x - FIELD_PADDING_X, y - FIELD_PADDING_Y
    local boxWidth, boxHeight = width + FIELD_PADDING_X * 2, height + FIELD_PADDING_Y * 2
    local radius = 0

    love.graphics.setColor(Theme:color("editFieldSurface"):unpacked())
    love.graphics.rectangle("fill", boxX, boxY, boxWidth, boxHeight, radius, radius)

    --love.graphics.setColor(Theme:color("editFieldBorder"):unpacked())
    --love.graphics.setLineWidth(pixel/2)
    --love.graphics.rectangle("line", boxX, boxY, boxWidth, boxHeight, radius, radius)

    -- Everything from here is scrolled, so it has to stop at the field's edges.
    Clip.push(x, y, width, height)

    local textX = x - self.scroll
    local textY = y + (height - font:getHeight()) / 2
    love.graphics.setFont(font)

    local from, to = editor:getSelection()
    if from then
        love.graphics.setColor(Theme:color("textSelection"):unpacked())
        love.graphics.rectangle("fill",
            textX + self:offsetOf(from), textY,
            self:offsetOf(to) - self:offsetOf(from), font:getHeight())
    end

    love.graphics.setColor(Theme:resolveColor(self.request.color or "foreground"):unpacked())
    love.graphics.print(editor:getText(), textX, textY)

    local caretX = textX + self:offsetOf(editor:getCaret())

    -- In-progress IME composition: drawn underlined at the caret and not in the
    -- buffer, because it isn't text yet -- it arrives as ordinary textinput once the
    -- input method commits it.
    if self.composition ~= "" then
        love.graphics.print(self.composition, caretX, textY)
        local compositionWidth = font:getWidth(self.composition)
        love.graphics.rectangle("fill", caretX, textY + font:getHeight() - pixel, compositionWidth, pixel)
        caretX = caretX + compositionWidth
    end

    if self.blink % (CARET_BLINK * 2) < CARET_BLINK then
        love.graphics.setColor(Theme:color("textCaret"):unpacked())
        love.graphics.rectangle("fill", caretX, textY, pixel, font:getHeight())
    end

    Clip.pop()

    love.graphics.setLineWidth(previousLineWidth)
    love.graphics.setFont(previousFont)
    love.graphics.setColor(r, g, b, a)
end

-- ── Input ────────────────────────────────────────────────────────────────

local function isDown(...)
    return love.keyboard.isDown(...)
end

-- Any edit restarts the blink cycle, so the caret is solid while you're typing.
function TextEditSession:touch()
    self.blink = 0
end

function TextEditSession:textinput(text)
    if not self.editor then
        return false
    end

    self.editor:textinput(text)
    self.composition = ""
    self:touch()
    return true
end

function TextEditSession:textedited(text, start, length)
    if not self.editor then
        return false
    end

    self.composition = text or ""
    self:touch()
    return true
end

function TextEditSession:keypressed(key, scancode, isrepeat)
    if not self.editor then
        return false
    end

    if key == "escape" then
        self:cancel()
        return true
    end

    if key == "return" or key == "kpenter" then
        self:commit()
        return true
    end

    self.editor:keypressed(key,
        isDown("lctrl", "rctrl") or isDown("lgui", "rgui"),
        isDown("lshift", "rshift"))
    self:touch()

    -- Consumed whether or not the editor wanted it: while a field is open, every key
    -- belongs to it, and a shortcut firing underneath it would be a surprise.
    return true
end

function TextEditSession:mousepressed(x, y, button, istouch, presses)
    if not self.editor then
        return false
    end

    if button == SELECT_BUTTON and self:containsPoint(x, y) then
        local localX = self.request.space.toLocal(x, y)
        if presses and presses >= 2 then
            self.editor:selectAll()
        else
            self.editor:setCaret(self:indexAt(localX), isDown("lshift", "rshift"))
            self.dragging = true
        end
        self:touch()
        return true
    end

    -- Clicking away keeps the edit, same as Enter. Deliberately not consumed: the
    -- click should still do whatever it would have done -- select another element,
    -- open a menu -- rather than being spent closing the field.
    self:commit()
    return false
end

function TextEditSession:mousemoved(x, y, dx, dy, istouch)
    if not self.dragging or not self.editor then
        return false
    end

    local localX = self.request.space.toLocal(x, y)
    self.editor:setCaret(self:indexAt(localX), true)
    self:touch()
    return true
end

function TextEditSession:mousereleased(x, y, button, istouch, presses)
    if not self.dragging or button ~= SELECT_BUTTON then
        return false
    end

    self.dragging = false
    return true
end

return TextEditSession
