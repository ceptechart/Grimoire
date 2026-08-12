local InputManager = require "application.InputManager"
local Theme = require "application.Style.Theme"
local Clip = require "application.Style.Clip"
local TextEditor = require "application.Text.TextEditor"
local utf8 = require "utf8"

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

-- ── Word wrap (multiline fields only) ───────────────────────────────────────
--
-- Splits `text` into runs of consecutive characters that are either all spaces or
-- all non-spaces. Byte-indexed rather than character-indexed, but that's safe: a
-- transition between a space run and a non-space run can only land on a lead byte,
-- since a UTF-8 continuation byte is never 0x20, so this never splits a multi-byte
-- character across two tokens.
local function tokenize(text)
    local tokens = {}
    local length = #text
    local i = 1
    while i <= length do
        local spaceRun = text:sub(i, i) == " "
        local j = i
        while j <= length and (text:sub(j, j) == " ") == spaceRun do
            j = j + 1
        end
        table.insert(tokens, text:sub(i, j - 1))
        i = j
    end
    return tokens
end

-- Greedy word wrap of one paragraph (no "\n" in `text`), appending { start, stop,
-- text } line descriptors to `lines`. `start`/`stop` are character offsets in the
-- same space as TextEditor's caret, `stop` exclusive -- every character of `text`
-- ends up inside exactly one line, so wrapping only decides where a break falls,
-- never drops or duplicates a character.
local function wrapParagraph(font, text, offset, width, lines)
    if text == "" then
        table.insert(lines, { start = offset, stop = offset, text = "" })
        return
    end

    local lineText, lineWidth, lineStart = "", 0, offset
    local cursor = offset

    local function flush()
        table.insert(lines, { start = lineStart, stop = cursor, text = lineText })
        lineText, lineWidth, lineStart = "", 0, cursor
    end

    for _, token in ipairs(tokenize(text)) do
        local tokenWidth = font:getWidth(token)
        local isSpace = token:sub(1, 1) == " "

        if not isSpace and lineWidth > 0 and lineWidth + tokenWidth > width then
            flush()
        end

        if not isSpace and tokenWidth > width then
            -- A single word wider than the field: break inside it instead of
            -- letting the line run on past the field's edge forever.
            for _, codepoint in utf8.codes(token) do
                local char = utf8.char(codepoint)
                local charWidth = font:getWidth(char)
                if lineWidth > 0 and lineWidth + charWidth > width then
                    flush()
                end
                lineText = lineText .. char
                lineWidth = lineWidth + charWidth
                cursor = cursor + 1
            end
        else
            lineText = lineText .. token
            lineWidth = lineWidth + tokenWidth
            cursor = cursor + (utf8.len(token) or #token)
        end
    end

    flush()
end

-- The visual lines a multiline field's text wraps to at the given width. Split on
-- explicit "\n" first -- each one is consumed rather than appearing in any line's
-- text, the same way a wrapped space is -- then word-wrapped paragraph by paragraph.
-- This is the one place that has to agree with TextEditor about where a character
-- offset falls, since every hit test and caret placement below reads its output.
local function wrapLines(font, text, width)
    local lines = {}
    local offset = 0
    local paragraphStart = 1
    local length = #text

    for index = 1, length + 1 do
        if index > length or text:sub(index, index) == "\n" then
            wrapParagraph(font, text:sub(paragraphStart, index - 1), offset, width, lines)
            offset = lines[#lines].stop + 1
            paragraphStart = index + 1
        end
    end

    return lines
end

function TextEditSession:load()
    self.request = nil
    self.editor = nil
    self.blink = 0
    self.scroll = 0
    self.scrollY = 0
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
--   multiline optional; wraps to the field's width, Enter inserts a newline
--             instead of committing (Ctrl+Enter commits), and Up/Down move a
--             visual line instead of jumping to the start/end of the text
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
    self.editor = TextEditor.new(request.text,
        { maxLength = request.maxLength, multiline = request.multiline })
    self.editor:selectAll()
    self.blink = 0
    self.scroll = 0
    self.scrollY = 0
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

-- Same idea as offsetOf, but from the start of one wrapped line rather than the
-- start of the whole text -- what a multiline field measures against, since each
-- line is drawn at its own x origin.
function TextEditSession:lineOffsetOf(line, index)
    return self:getFont():getWidth(self.editor:sub(line.start, index))
end

-- The wrapped lines of the current text at the field's live width. Recomputed on
-- demand rather than cached: fields hold a note's worth of text, not a document, so
-- the cost of rebuilding this on every call that needs it (draw, a click, an
-- arrow key) doesn't matter, and there's no edit path that could leave a cached
-- copy stale this way.
function TextEditSession:getLines()
    local _, _, width = self:getRect()
    return wrapLines(self:getFont(), self.editor:getText(), width)
end

-- The line a caret offset falls on. Ambiguous only at a pure word-wrap boundary
-- (no "\n" consumed, so one line's stop equals the next one's start); the earlier
-- line wins, which is what puts the caret at the *end* of a wrapped line rather
-- than the start of the next one.
local function lineAt(lines, offset)
    for index, line in ipairs(lines) do
        if offset >= line.start and offset <= line.stop then
            return index, line
        end
    end
    return #lines, lines[#lines]
end

-- The caret offset nearest a point in the field's space: the boundary the click is
-- closest to, so clicking the right half of a character puts the caret after it.
--
-- Linear in the length of the text and quadratic in substring work; fields hold
-- titles or a note's body, not documents, and this runs on a click or an arrow key,
-- not per frame.
function TextEditSession:indexAt(localX, localY)
    if not self.request.multiline then
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

    local x, y = self:getRect()
    local font = self:getFont()
    local lineHeight = font:getHeight()
    local lines = self:getLines()

    local rowIndex = math.floor((localY - y + self.scrollY) / lineHeight) + 1
    rowIndex = math.max(1, math.min(rowIndex, #lines))
    local line = lines[rowIndex]

    local target = localX - x
    local best, bestDistance = line.start, math.abs(target)
    for offset = line.start, line.stop do
        local distance = math.abs(target - self:lineOffsetOf(line, offset))
        if distance < bestDistance then
            best, bestDistance = offset, distance
        end
    end

    return best
end

-- Moves the caret up or down one wrapped line, keeping it as close as possible to
-- its current horizontal position -- the usual arrow-key behaviour in any multiline
-- field. A no-op at the first/last line, same as TextEditor's own moveCaret at the
-- start/end of the text.
function TextEditSession:moveCaretVertically(direction, extend)
    local lines = self:getLines()
    local editor = self.editor
    local lineIndex, line = lineAt(lines, editor:getCaret())

    local targetX = self:lineOffsetOf(line, editor:getCaret())
    local newLineIndex = lineIndex + direction
    if newLineIndex < 1 or newLineIndex > #lines then
        return
    end
    local newLine = lines[newLineIndex]

    local best, bestDistance = newLine.start, math.abs(targetX)
    for offset = newLine.start, newLine.stop do
        local distance = math.abs(targetX - self:lineOffsetOf(newLine, offset))
        if distance < bestDistance then
            best, bestDistance = offset, distance
        end
    end

    editor:setCaret(best, extend)
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

-- Same idea, vertically: keeps the caret's wrapped line inside the field's height.
-- Wrapping already keeps every line inside the width, so there's no horizontal
-- counterpart to this in multiline mode.
function TextEditSession:updateScrollY(height)
    local font = self:getFont()
    local lineHeight = font:getHeight()
    local lines = self:getLines()
    local lineIndex = lineAt(lines, self.editor:getCaret())
    local caretY = (lineIndex - 1) * lineHeight

    local maxScroll = math.max(0, #lines * lineHeight - height)
    local scroll = math.min(self.scrollY, maxScroll)
    scroll = math.min(scroll, caretY)
    scroll = math.max(scroll, caretY - height + lineHeight)

    self.scrollY = math.max(0, math.min(scroll, maxScroll))
end

function TextEditSession:update(dt)
    if not self.editor then
        return
    end

    local _, _, width, height = self:getRect()
    if not width then
        -- Whatever was being edited is gone -- a document swap, say. Discard rather
        -- than commit: there's nothing left to commit onto.
        self:cancel()
        return
    end

    self.blink = self.blink + dt
    if self.request.multiline then
        self:updateScrollY(height)
    else
        self:updateScroll(width)
    end
    self:updateTextInput()
end

-- ── Drawing ──────────────────────────────────────────────────────────────

-- Called from both draw passes; renders only when the space matches, so the board
-- draws world-space fields inside its transform and the app draws screen-space ones
-- over the chrome.
-- The single-line body: one row of text, scrolled horizontally to keep the caret in
-- view.
function TextEditSession:drawSingleLine(x, y, width, height, pixel)
    local editor = self.editor
    local font = self:getFont()

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
end

-- The multiline body: one row per wrapped line, scrolled vertically. No horizontal
-- scroll -- wrapping already keeps every line inside the field's width.
function TextEditSession:drawMultiline(x, y, width, height, pixel)
    local editor = self.editor
    local font = self:getFont()
    local lineHeight = font:getHeight()
    local lines = self:getLines()

    love.graphics.setFont(font)

    local from, to = editor:getSelection()
    local caret = editor:getCaret()
    local caretDrawn = false

    for index, line in ipairs(lines) do
        local lineY = y - self.scrollY + (index - 1) * lineHeight

        if from then
            local selFrom = math.max(from, line.start)
            local selTo = math.min(to, line.stop)
            if selTo > selFrom then
                love.graphics.setColor(Theme:color("textSelection"):unpacked())
                love.graphics.rectangle("fill",
                    x + self:lineOffsetOf(line, selFrom), lineY,
                    self:lineOffsetOf(line, selTo) - self:lineOffsetOf(line, selFrom), lineHeight)
            end
        end

        love.graphics.setColor(Theme:resolveColor(self.request.color or "foreground"):unpacked())
        love.graphics.print(line.text, x, lineY)

        if not caretDrawn and caret >= line.start and caret <= line.stop then
            caretDrawn = true
            local caretX = x + self:lineOffsetOf(line, caret)

            if self.composition ~= "" then
                love.graphics.print(self.composition, caretX, lineY)
                local compositionWidth = font:getWidth(self.composition)
                love.graphics.rectangle("fill",
                    caretX, lineY + lineHeight - pixel, compositionWidth, pixel)
                caretX = caretX + compositionWidth
            end

            if self.blink % (CARET_BLINK * 2) < CARET_BLINK then
                love.graphics.setColor(Theme:color("textCaret"):unpacked())
                love.graphics.rectangle("fill", caretX, lineY, pixel, lineHeight)
            end
        end
    end
end

function TextEditSession:drawIn(space)
    if not self.editor or self.request.space.name ~= space then
        return
    end

    local x, y, width, height = self:getRect()
    if not x then
        return
    end

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

    if self.request.multiline then
        self:drawMultiline(x, y, width, height, pixel)
    else
        self:drawSingleLine(x, y, width, height, pixel)
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

    local ctrl = isDown("lctrl", "rctrl") or isDown("lgui", "rgui")
    local shift = isDown("lshift", "rshift")

    if key == "return" or key == "kpenter" then
        -- A multiline field's Enter inserts a newline, matching what a click away
        -- or Escape already do for the rest of the field -- typed content changes
        -- what the field holds, not whether the edit is kept. Ctrl+Enter is the one
        -- explicit "I'm done" for Enter itself, since there's no plain Enter left to
        -- ask with.
        if self.request.multiline and not ctrl then
            self.editor:insert("\n")
            self:touch()
            return true
        end
        self:commit()
        return true
    end

    -- Up/Down move a wrapped line at a time rather than jumping to the start/end of
    -- the whole text (TextEditor's own mapping, still what a single-line field
    -- wants): only the session knows the wrap, so it intercepts these two before
    -- the editor ever sees them.
    if self.request.multiline and (key == "up" or key == "down") then
        self:moveCaretVertically(key == "up" and -1 or 1, shift)
        self:touch()
        return true
    end

    self.editor:keypressed(key, ctrl, shift)
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
        local localX, localY = self.request.space.toLocal(x, y)
        if presses and presses >= 2 then
            self.editor:selectAll()
        else
            self.editor:setCaret(self:indexAt(localX, localY), isDown("lshift", "rshift"))
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

    local localX, localY = self.request.space.toLocal(x, y)
    self.editor:setCaret(self:indexAt(localX, localY), true)
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
