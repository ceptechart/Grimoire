local Class = require "lib.util.Class"
local utf8 = require "utf8"

-- The model half of text editing: a string being edited, a caret, a selection, and
-- the operations a text field needs -- insert, delete, move, select, clipboard.
--
-- Deliberately free of drawing and of input subscriptions, so the same editor backs a
-- canvas element in world space and a UI field in screen space. It's fed by whatever
-- owns the input (see TextEditSession) rather than reaching for love.keyboard or
-- love.graphics itself; the one exception is the clipboard, which is process state
-- rather than either of those.
--
-- Positions are *character* offsets, not byte offsets: 0 is before the first
-- character and getLength() is after the last. The text is held split into UTF-8
-- characters, so a multi-byte character is one step of the caret and one press of
-- backspace, and no operation can cut one in half. Fields hold titles and labels, so
-- the cost of rebuilding the string on each edit doesn't matter here.
--
-- Enter and Escape are deliberately *not* handled: whether they commit, cancel or
-- insert a newline is the session's policy, not the buffer's.
local TextEditor = Class.extend()

-- Nothing that isn't printable gets in: textinput won't produce control characters,
-- but a pasted clipboard readily contains newlines and tabs. A multiline editor is the
-- one case that wants to keep "\n" (0x0A), so it's carved out of the strip class
-- rather than handled as a special case in every caller.
local CONTROL_CHARACTERS = "[%z\1-\31\127]"
local CONTROL_CHARACTERS_KEEP_NEWLINE = "[%z\1-\9\11-\31\127]"

local function sanitize(text, multiline)
    local pattern = multiline and CONTROL_CHARACTERS_KEEP_NEWLINE or CONTROL_CHARACTERS
    return (tostring(text or ""):gsub(pattern, ""))
end

-- Invalid byte sequences simply don't match charpattern and are dropped, which is the
-- right failure for text arriving from a file or the clipboard.
local function split(text)
    local characters = {}
    for character in text:gmatch(utf8.charpattern) do
        characters[#characters + 1] = character
    end
    return characters
end

local function isWordCharacter(character)
    return character ~= nil and character:match("[%w_]") ~= nil
end

-- options: { maxLength = n, multiline = bool }
function TextEditor.new(text, options)
    options = options or {}

    local editor = setmetatable({
        characters = {},
        cachedText = nil,
        -- caret is where typing happens; anchor is the other end of the selection,
        -- and equals caret when nothing is selected.
        caret = 0,
        anchor = 0,
        maxLength = options.maxLength,
        multiline = options.multiline or false,
    }, TextEditor)

    editor:setText(text)
    return editor
end

-- ── Reading ──────────────────────────────────────────────────────────────

function TextEditor:getText()
    if not self.cachedText then
        self.cachedText = table.concat(self.characters)
    end
    return self.cachedText
end

function TextEditor:getLength()
    return #self.characters
end

-- The text between two character offsets, which is what a renderer measures to place
-- the caret and the selection box.
function TextEditor:sub(from, to)
    return table.concat(self.characters, "", from + 1, to)
end

function TextEditor:getCaret()
    return self.caret
end

-- Ordered, so callers don't have to care which end the drag started at. Returns nil
-- when nothing is selected rather than an empty range, so `if from then` reads as
-- "is there a selection".
function TextEditor:getSelection()
    if self.caret == self.anchor then
        return nil
    end
    return math.min(self.caret, self.anchor), math.max(self.caret, self.anchor)
end

function TextEditor:hasSelection()
    return self.caret ~= self.anchor
end

function TextEditor:getSelectedText()
    local from, to = self:getSelection()
    if not from then
        return ""
    end
    return self:sub(from, to)
end

-- ── Caret and selection ──────────────────────────────────────────────────

function TextEditor:clamp(index)
    return math.max(0, math.min(index, #self.characters))
end

-- extend keeps the anchor put (shift-select); without it the selection collapses.
function TextEditor:setCaret(index, extend)
    self.caret = self:clamp(index)
    if not extend then
        self.anchor = self.caret
    end
    return self
end

function TextEditor:selectAll()
    self.anchor = 0
    self.caret = #self.characters
    return self
end

function TextEditor:selectNone()
    self.anchor = self.caret
    return self
end

-- Offset of the word boundary to the left of the caret: past any run of non-word
-- characters, then past the word itself.
function TextEditor:wordLeft()
    local index = self.caret
    while index > 0 and not isWordCharacter(self.characters[index]) do
        index = index - 1
    end
    while index > 0 and isWordCharacter(self.characters[index]) do
        index = index - 1
    end
    return index
end

function TextEditor:wordRight()
    local index = self.caret
    local length = #self.characters
    while index < length and not isWordCharacter(self.characters[index + 1]) do
        index = index + 1
    end
    while index < length and isWordCharacter(self.characters[index + 1]) do
        index = index + 1
    end
    return index
end

-- motion: "left" | "right" | "wordleft" | "wordright" | "home" | "end"
function TextEditor:moveCaret(motion, extend)
    local from, to = self:getSelection()

    -- An unshifted arrow with a selection collapses to that edge instead of stepping
    -- from the caret, which is what every other text field does.
    if from and not extend and (motion == "left" or motion == "right") then
        return self:setCaret(motion == "left" and from or to)
    end

    if motion == "left" then
        return self:setCaret(self.caret - 1, extend)
    elseif motion == "right" then
        return self:setCaret(self.caret + 1, extend)
    elseif motion == "wordleft" then
        return self:setCaret(self:wordLeft(), extend)
    elseif motion == "wordright" then
        return self:setCaret(self:wordRight(), extend)
    elseif motion == "home" then
        return self:setCaret(0, extend)
    elseif motion == "end" then
        return self:setCaret(#self.characters, extend)
    end

    return self
end

-- ── Writing ──────────────────────────────────────────────────────────────

function TextEditor:invalidate()
    self.cachedText = nil
end

function TextEditor:setText(text)
    self.characters = split(sanitize(text, self.multiline))
    self.caret = #self.characters
    self.anchor = self.caret
    self:invalidate()
    return self
end

-- Returns true if it removed anything, so callers can tell a selection delete from a
-- plain backspace.
function TextEditor:deleteSelection()
    local from, to = self:getSelection()
    if not from then
        return false
    end

    for index = to, from + 1, -1 do
        table.remove(self.characters, index)
    end

    self.caret = from
    self.anchor = from
    self:invalidate()
    return true
end

function TextEditor:insert(text)
    self:deleteSelection()

    local incoming = split(sanitize(text, self.multiline))
    if self.maxLength then
        local room = self.maxLength - #self.characters
        while #incoming > math.max(0, room) do
            table.remove(incoming)
        end
    end
    if #incoming == 0 then
        return false
    end

    for offset, character in ipairs(incoming) do
        table.insert(self.characters, self.caret + offset, character)
    end

    self:setCaret(self.caret + #incoming)
    self:invalidate()
    return true
end

function TextEditor:deleteBackward()
    if self:deleteSelection() then
        return true
    end
    if self.caret == 0 then
        return false
    end

    table.remove(self.characters, self.caret)
    self:setCaret(self.caret - 1)
    self:invalidate()
    return true
end

function TextEditor:deleteForward()
    if self:deleteSelection() then
        return true
    end
    if self.caret >= #self.characters then
        return false
    end

    table.remove(self.characters, self.caret + 1)
    self:invalidate()
    return true
end

-- ── Clipboard ────────────────────────────────────────────────────────────

function TextEditor:copy()
    if not self:hasSelection() then
        return false
    end
    love.system.setClipboardText(self:getSelectedText())
    return true
end

function TextEditor:cut()
    if not self:copy() then
        return false
    end
    return self:deleteSelection()
end

function TextEditor:paste()
    return self:insert(love.system.getClipboardText() or "")
end

-- ── Input ────────────────────────────────────────────────────────────────

function TextEditor:textinput(text)
    return self:insert(text)
end

-- Modifier state is passed in rather than read from love.keyboard, so this stays
-- drivable from a test. Returns true if the key was an editing key -- Enter, Escape
-- and everything else are the caller's to interpret.
function TextEditor:keypressed(key, ctrl, shift)
    if ctrl then
        if key == "a" then
            self:selectAll()
            return true
        elseif key == "c" then
            self:copy()
            return true
        elseif key == "x" then
            self:cut()
            return true
        elseif key == "v" then
            self:paste()
            return true
        end
    end

    if key == "backspace" then
        -- Ctrl+Backspace deletes the word: select back to the boundary, then delete
        -- that, rather than reimplementing the walk.
        if ctrl and not self:hasSelection() then
            self:setCaret(self:wordLeft(), true)
        end
        self:deleteBackward()
        return true
    elseif key == "delete" then
        if ctrl and not self:hasSelection() then
            self:setCaret(self:wordRight(), true)
        end
        self:deleteForward()
        return true
    elseif key == "left" then
        self:moveCaret(ctrl and "wordleft" or "left", shift)
        return true
    elseif key == "right" then
        self:moveCaret(ctrl and "wordright" or "right", shift)
        return true
    elseif key == "home" or key == "up" then
        self:moveCaret("home", shift)
        return true
    elseif key == "end" or key == "down" then
        self:moveCaret("end", shift)
        return true
    end

    return false
end

return TextEditor
