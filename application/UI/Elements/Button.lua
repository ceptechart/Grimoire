local Class = require "lib.util.Class"
local Widget = require "application.UI.Elements.Widget"

-- A Label plus a background Panel per interaction state.
--
-- Only the panel (and optionally the text color) differs between states, so the
-- label is built once rather than once per state. The button's rect is the label's
-- rect: the label carries the padding, and the state panel is drawn behind it.
local Button = Class.extend(Widget)

Button.DEFAULT = "default"
Button.HOVER = "hover"
Button.PRESS = "press"

function Button.new(label)
    local button = Widget.init(setmetatable({}, Button))

    button.label = label
    button.state = Button.DEFAULT
    button.pressed = false
    button.statePanels = {}
    button.stateColors = {}

    return button
end

function Button:withPosition(x, y)
    Widget.withPosition(self, x, y)
    self.label:withPosition(x, y)
    return self
end

function Button:withLabel(label)
    self.label = label:withPosition(self.position.x, self.position.y)
    return self
end

function Button:withStatePanel(state, panel)
    self.statePanels[state] = panel
    return self
end

function Button:withHoverPanel(panel)
    return self:withStatePanel(Button.HOVER, panel)
end

function Button:withPressPanel(panel)
    return self:withStatePanel(Button.PRESS, panel)
end

-- Optional per-state override of the label's color, for buttons that need more
-- than a background change.
function Button:withStateColor(state, color)
    self.stateColors[state] = color
    return self
end

function Button:withOnPress(callback)
    self.onPress = callback
    return self
end

function Button:withOnMouseEnter(callback)
    self.onMouseEnter = callback
    return self
end

function Button:withOnMouseLeave(callback)
    self.onMouseLeave = callback
    return self
end

-- Falls back to the plain panel, so a button with no per-state panels still has a
-- background if one was set via withPanel.
function Button:getPanel()
    return self.statePanels[self.state] or self.panel
end

function Button:getDefaultWidth()
    return self.label:getWidth()
end

function Button:getHeight()
    return self.label:getHeight()
end

function Button:draw()
    local panel = self:getPanel()
    if panel then
        panel:draw(self.position.x, self.position.y, self:getWidth(), self:getHeight())
    end

    local stateColor = self.stateColors[self.state]
    if stateColor then
        local previousColor = self.label.color
        self.label.color = stateColor
        self.label:draw()
        self.label.color = previousColor
    else
        self.label:draw()
    end
end

function Button:mousemoved(x, y, dx, dy, istouch)
    local inside = self:containsPoint(x, y)
    local wasInside = self.state ~= Button.DEFAULT

    if inside and not wasInside then
        self.state = Button.HOVER
        if self.onMouseEnter then
            self.onMouseEnter(self)
        end
    elseif not inside and wasInside then
        self.state = Button.DEFAULT
        self.pressed = false
        if self.onMouseLeave then
            self.onMouseLeave(self)
        end
    end
    -- Deliberately does not consume; see InputManager's broadcast note.
end

function Button:mousepressed(x, y, button, istouch, presses)
    if button ~= 1 or not self:containsPoint(x, y) then
        return false
    end

    self.pressed = true
    self.state = Button.PRESS

    if self.onPress then
        self.onPress(self)
    end

    return true
end

function Button:mousereleased(x, y, button, istouch, presses)
    if button ~= 1 or not self.pressed then
        return false
    end

    self.pressed = false
    self.state = self:containsPoint(x, y) and Button.HOVER or Button.DEFAULT

    return true
end

return Button
