local Class = require "lib.util.Class"
local Theme = require "application.Style.Theme"
local Widget = require "application.UI.Elements.Widget"
local Label = require "application.UI.Elements.Label"
local Panel = require "application.Style.Panel"

-- A single dismissible notification.
--
-- A Toast only knows its own animation and lifecycle (slide in, hold, fade out,
-- done) plus how to respond to a click. Stack order, spacing, and where the bottom
-- slot sits belong to ToastManager -- a Toast is just told its target row via
-- setTargetY and eases toward it every frame, so an insertion elsewhere in the
-- stack reads as this toast sliding rather than jumping.
local Toast = Class.extend(Widget)

Toast.SUCCESS = "success"
Toast.INFO = "info"
Toast.WARN = "warn"
Toast.ERROR = "error"

local ACCENT_TOKEN = {
    [Toast.SUCCESS] = "toastSuccess",
    [Toast.INFO] = "toastInfo",
    [Toast.WARN] = "toastWarn",
    [Toast.ERROR] = "toastError",
}

local ICON_PATH = {
    [Toast.SUCCESS] = "res/img/icon/success.png",
    [Toast.INFO] = "res/img/icon/info.png",
    [Toast.WARN] = "res/img/icon/warn.png",
    [Toast.ERROR] = "res/img/icon/error.png",
}

-- Loaded lazily (not at require time, love.graphics may not exist yet) and shared
-- across every toast of a given type.
local iconCache = {}
local function iconFor(type)
    local icon = iconCache[type]
    if not icon then
        icon = love.graphics.newImage(ICON_PATH[type])
        iconCache[type] = icon
    end
    return icon
end

-- Rest distance from the right/bottom screen edges. ToastManager reuses this so the
-- stack's vertical margin matches a toast's own horizontal one.
Toast.MARGIN = 16

local MIN_WIDTH = 240
local SLIDE_DURATION = 0.25
local FADE_DURATION = 0.3
local DEFAULT_TIMEOUT = 4

Toast.ENTERING = "entering"
Toast.HOLDING = "holding"
Toast.LEAVING = "leaving"
Toast.DONE = "done"

-- Eases current toward target rather than snapping, so simultaneous stack reflows
-- read as one smooth motion. dt/duration*4 makes duration read as "time to mostly
-- arrive" rather than a literal asymptote.
local function approach(current, target, dt, duration)
    local rate = 1 - math.exp(-dt / duration * 4)
    return current + (target - current) * rate
end

local function fadedColor(value, opacity)
    local color = Theme:resolveColor(value)
    return color:withAlpha(color.a * opacity)
end

-- options: { timeout = seconds or false for no auto-dismiss, onClick = function(toast) }
function Toast.new(type, text, options)
    options = options or {}

    local toast = Widget.init(setmetatable({}, Toast))

    toast.type = type
    toast.onClick = options.onClick
    toast.timeout = options.timeout == nil and DEFAULT_TIMEOUT or options.timeout

    toast:withMinWidth(MIN_WIDTH)

    toast.panel = Panel.new()
        :withColor("surface")
        :withLineColor(ACCENT_TOKEN[type])
        :withLineWeight(2)
        :withShadow(true)

    toast.label = Label.new(text)
        :withFont("medium")
        :withColor(ACCENT_TOKEN[type])
        :withIcon(iconFor(type), 8)
        :withPadding(12, 10)

    toast.targetY = 0
    toast.holdTime = 0
    toast.fadeTime = 0
    toast.opacity = 1
    toast.state = Toast.ENTERING

    return toast
end

function Toast:getDefaultWidth()
    return self.label:getDefaultWidth()
end

function Toast:getHeight()
    return self.label:getHeight()
end

-- Called by ToastManager whenever the stack reflows.
function Toast:setTargetY(y)
    self.targetY = y
end

function Toast:isDone()
    return self.state == Toast.DONE
end

function Toast:dismiss()
    if self.state == Toast.LEAVING or self.state == Toast.DONE then
        return
    end
    self.state = Toast.LEAVING
    self.fadeTime = 0
end

function Toast:update(dt, screenWidth)
    if self.state == Toast.ENTERING then
        local restX = screenWidth - self:getWidth() - Toast.MARGIN
        self.position.x = approach(self.position.x, restX, dt, SLIDE_DURATION)
        if math.abs(self.position.x - restX) < 0.5 then
            self.position.x = restX
            self.state = Toast.HOLDING
        end
    elseif self.state == Toast.HOLDING then
        self.holdTime = self.holdTime + dt
        if self.timeout and self.holdTime >= self.timeout then
            self:dismiss()
        end
    elseif self.state == Toast.LEAVING then
        self.fadeTime = self.fadeTime + dt
        self.opacity = math.max(0, 1 - self.fadeTime / FADE_DURATION)
        if self.fadeTime >= FADE_DURATION then
            self.state = Toast.DONE
        end
    end

    self.position.y = approach(self.position.y, self.targetY, dt, SLIDE_DURATION)
end

function Toast:draw()
    if self.opacity <= 0 then
        return
    end

    if self.opacity >= 1 then
        self:drawContent()
        return
    end

    -- Temporary swap, same pattern as Button's stateColor: resolve to a literal
    -- faded Color, draw, then restore the token so the next frame resolves fresh
    -- (the theme itself could change between frames).
    local panelColor, lineColor, shadowColor = self.panel.color, self.panel.lineColor, self.panel.shadowColor
    local labelColor = self.label.color

    self.panel.color = fadedColor(panelColor, self.opacity)
    self.panel.lineColor = fadedColor(lineColor, self.opacity)
    self.panel.shadowColor = fadedColor(shadowColor, self.opacity)
    self.label.color = fadedColor(labelColor, self.opacity)

    self:drawContent()

    self.panel.color, self.panel.lineColor, self.panel.shadowColor = panelColor, lineColor, shadowColor
    self.label.color = labelColor
end

function Toast:drawContent()
    self.panel:draw(self.position.x, self.position.y, self:getWidth(), self:getHeight())
    self.label:withPosition(self.position.x, self.position.y)
    self.label:draw()
end

function Toast:mousepressed(x, y, button, istouch, presses)
    if button ~= 1 or self.state == Toast.LEAVING or self.state == Toast.DONE then
        return false
    end

    if not self:containsPoint(x, y) then
        return false
    end

    if self.onClick then
        self.onClick(self)
    end
    self:dismiss()

    return true
end

return Toast
