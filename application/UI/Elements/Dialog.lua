local Class = require "lib.util.Class"
local Theme = require "application.Style.Theme"
local Widget = require "application.UI.Elements.Widget"
local Label = require "application.UI.Elements.Label"
local Button = require "application.UI.Elements.Button"
local Panel = require "application.Style.Panel"

-- A centered modal confirmation dialog: a title, a wrapped message, and a row of
-- buttons. Built and shown by DialogManager, which owns whether one exists and
-- routes input to it; this is just the shape and the draw.
--
-- A bespoke Widget rather than a Container of stacked children: the layout (title
-- above wrapped message above a right-aligned button row, sized to its content) is a
-- one-off shape nothing else in the widget tree needs, so Container's generic
-- stacking would be more machinery than these three rows call for.
local Dialog = Class.extend(Widget)

local CONTENT_WIDTH = 360
local PADDING_X, PADDING_Y = 24, 20
local TITLE_SPACING = 10
local MESSAGE_BUTTON_SPACING = 22
local BUTTON_SPACING = 10
local BUTTON_PADDING_X, BUTTON_PADDING_Y = 16, 8

-- Three button tones: "primary" for the recommended action, "danger" for a
-- destructive one (discarding work), "secondary" for everything else. Filled,
-- unlike the menu bar's flat buttons -- a dialog's buttons have to read as buttons
-- on their own, with no bar around them to imply it.
local STYLE_TOKENS = {
    primary = {
        fill = "dialogPrimary", hover = "dialogPrimaryHover", press = "dialogPrimaryPress",
        text = "dialogButtonText",
    },
    danger = {
        fill = "dialogDanger", hover = "dialogDangerHover", press = "dialogDangerPress",
        text = "dialogButtonText",
    },
    secondary = {
        fill = "dialogSecondary", hover = "dialogSecondaryHover", press = "dialogSecondaryPress",
        text = "foreground",
    },
}

-- Built once at module load rather than per dialog: Panel.new() only stores token
-- strings (no Theme or graphics-context dependency), and a dialog can open and close
-- many times in a session -- repeatedly hitting Ctrl+N with unsaved changes, say.
local panelsByStyle = {}
for style, tokens in pairs(STYLE_TOKENS) do
    panelsByStyle[style] = {
        default = Panel.new():withColor(tokens.fill):withLineWeight(0),
        hover = Panel.new():withColor(tokens.hover):withLineWeight(0),
        press = Panel.new():withColor(tokens.press):withLineWeight(0),
    }
end

local function buildButton(spec)
    local tokens = STYLE_TOKENS[spec.style or "secondary"]
    local panels = panelsByStyle[spec.style or "secondary"]

    local label = Label.new(spec.label)
        :withFont("small")
        :withColor(tokens.text)
        :withPadding(BUTTON_PADDING_X, BUTTON_PADDING_Y)

    local button = Button.new(label)
        :withPanel(panels.default)
        :withHoverPanel(panels.hover)
        :withPressPanel(panels.press)
        :withOnPress(function() spec.onPress() end)

    -- Not part of Button's own vocabulary -- DialogManager reads these to decide
    -- what Enter/Escape should trigger.
    button.isDefault = spec.default == true
    button.isCancel = spec.cancel == true

    return button
end

-- options: { title, message, buttons = { { label, style, default, cancel, onPress }, ... } }
function Dialog.new(options)
    local dialog = Widget.init(setmetatable({}, Dialog))

    dialog.title = options.title
    dialog.message = options.message
    dialog.panel = Panel.new()
        :withColor("surface")
        :withLineColor("border")
        :withShadow(true)

    dialog.buttons = {}
    for _, spec in ipairs(options.buttons) do
        table.insert(dialog.buttons, buildButton(spec))
    end

    return dialog
end

function Dialog:getTitleFont()
    return Theme:font("medium")
end

function Dialog:getMessageFont()
    return Theme:font("small")
end

function Dialog:getMessageLines()
    local _, lines = self:getMessageFont():getWrap(self.message, CONTENT_WIDTH)
    return lines
end

function Dialog:getButtonRowWidth()
    local width = 0
    for index, button in ipairs(self.buttons) do
        width = width + button:getWidth()
        if index > 1 then
            width = width + BUTTON_SPACING
        end
    end
    return width
end

function Dialog:getButtonRowHeight()
    local height = 0
    for _, button in ipairs(self.buttons) do
        height = math.max(height, button:getHeight())
    end
    return height
end

-- Wide enough for the message's wrap width, unless a long button row needs more.
function Dialog:getDefaultWidth()
    return math.max(CONTENT_WIDTH, self:getButtonRowWidth()) + PADDING_X * 2
end

function Dialog:getHeight()
    return PADDING_Y * 2
        + self:getTitleFont():getHeight() + TITLE_SPACING
        + #self:getMessageLines() * self:getMessageFont():getHeight()
        + MESSAGE_BUTTON_SPACING
        + self:getButtonRowHeight()
end

-- Recomputes the centered position and every button's position. Called before
-- drawing and before handling input, same as Container's widgets, so a resize
-- between frames can't leave either stale.
function Dialog:layout()
    local screenWidth, screenHeight = love.graphics.getDimensions()
    local width, height = self:getWidth(), self:getHeight()
    self.position:set((screenWidth - width) / 2, (screenHeight - height) / 2)

    local buttonHeight = self:getButtonRowHeight()
    local y = self.position.y + height - PADDING_Y - buttonHeight
    local x = self.position.x + width - PADDING_X

    -- Walked back to front so the last-declared button lands rightmost -- the
    -- buttons read left to right in the order they were declared.
    for index = #self.buttons, 1, -1 do
        local button = self.buttons[index]
        x = x - button:getWidth()
        button:withPosition(x, y)
        x = x - BUTTON_SPACING
    end
end

function Dialog:draw()
    self:layout()

    local width, height = self:getWidth(), self:getHeight()
    self.panel:draw(self.position.x, self.position.y, width, height)

    local r, g, b, a = love.graphics.getColor()
    local previousFont = love.graphics.getFont()

    local titleFont = self:getTitleFont()
    love.graphics.setFont(titleFont)
    love.graphics.setColor(Theme:color("foreground"):unpacked())
    love.graphics.print(self.title, self.position.x + PADDING_X, self.position.y + PADDING_Y)

    local messageFont = self:getMessageFont()
    love.graphics.setFont(messageFont)
    love.graphics.setColor(Theme:color("muted"):unpacked())
    love.graphics.printf(self.message,
        self.position.x + PADDING_X,
        self.position.y + PADDING_Y + titleFont:getHeight() + TITLE_SPACING,
        CONTENT_WIDTH, "left")

    love.graphics.setFont(previousFont)
    love.graphics.setColor(r, g, b, a)

    for _, button in ipairs(self.buttons) do
        button:draw()
    end
end

function Dialog:mousemoved(x, y, dx, dy, istouch)
    self:layout()
    for _, button in ipairs(self.buttons) do
        button:mousemoved(x, y, dx, dy, istouch)
    end
end

function Dialog:mousepressed(x, y, mouseButton, istouch, presses)
    self:layout()
    for _, button in ipairs(self.buttons) do
        if button:mousepressed(x, y, mouseButton, istouch, presses) then
            return true
        end
    end
    return false
end

function Dialog:mousereleased(x, y, mouseButton, istouch, presses)
    local consumed = false
    for _, button in ipairs(self.buttons) do
        if button:mousereleased(x, y, mouseButton, istouch, presses) then
            consumed = true
        end
    end
    return consumed
end

return Dialog
