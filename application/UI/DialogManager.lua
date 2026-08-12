local InputManager = require "application.InputManager"
local Theme = require "application.Style.Theme"
local TextEditSession = require "application.Text.TextEditSession"
local Dialog = require "application.UI.Elements.Dialog"

-- The one modal confirm dialog open anywhere in the app -- at most one at a time,
-- the same invariant TextEditSession keeps for text fields, and for the same reason:
-- MODAL exists to give one thing a turn at demanding an answer before anything else
-- can happen, and two things both claiming that turn is a contradiction.
--
-- Replaces the native love.window.showMessageBox prompt BoardFile used for unsaved
-- changes (TODO 4) with one built from this app's own widgets, so it matches the
-- theme instead of the OS's.
local DialogManager = {}

local FADE_DURATION = 0.5
local SLIDE_DISTANCE = 12

function DialogManager:load()
    self.dialog = nil
    self.openTime = 0

    InputManager:subscribe("keypressed", self, InputManager.PRIORITY.MODAL)
    InputManager:subscribeAll(InputManager.MOUSE_EVENTS, self, InputManager.PRIORITY.MODAL)
end

function DialogManager:isOpen()
    return self.dialog ~= nil
end

-- options: { title, message, buttons = { { label, style, default, cancel, onPress }, ... } }
-- style is "primary" | "danger" | "secondary" (the default). default/cancel mark
-- which button Enter/Escape trigger -- the same vocabulary love.window.showMessageBox
-- used (enterbutton/escapebutton), so callers moving off it barely change shape.
--
-- Each button's onPress is wrapped to close the dialog first: the button that was
-- pressed stops mattering the moment its own callback does something else (opening a
-- save dialog, say), so callers never have to remember to close() themselves.
function DialogManager:confirm(options)
    -- A dialog outranks an in-progress text edit -- both live at MODAL, and only one
    -- can actually hold it. Commit, not cancel: the field isn't being discarded,
    -- just interrupted by something more urgent than what was being typed.
    TextEditSession:commit()

    local buttons = {}
    for _, spec in ipairs(options.buttons) do
        local onPress = spec.onPress
        table.insert(buttons, {
            label = spec.label,
            style = spec.style,
            default = spec.default,
            cancel = spec.cancel,
            onPress = function()
                self:close()
                if onPress then onPress() end
            end,
        })
    end

    self.dialog = Dialog.new({ title = options.title, message = options.message, buttons = buttons })
    self.openTime = 0
end

function DialogManager:close()
    self.dialog = nil
end

function DialogManager:update(dt)
    if self.dialog then
        self.openTime = self.openTime + dt
    end
end

function DialogManager:draw()
    if not self.dialog then
        return
    end

    -- A native message box just appears, and that snap is part of what reads as
    -- dated. The overlay fades in and the panel slides up a few pixels over
    -- FADE_DURATION, eased so it settles rather than arriving at a constant rate.
    local t = math.min(1, self.openTime / FADE_DURATION)
    local eased = 1 - (1 - t) ^ 3

    local r, g, b, a = love.graphics.getColor()
    local overlay = Theme:color("overlay")
    love.graphics.setColor(overlay.r, overlay.g, overlay.b, overlay.a * eased)
    love.graphics.rectangle("fill", 0, 0, love.graphics.getDimensions())
    love.graphics.setColor(r, g, b, a)

    -- Visual only: the input handlers below read the dialog's real, untranslated
    -- position, so a click mid-slide can't land a few pixels off from what's drawn.
    love.graphics.push()
    love.graphics.translate(0, SLIDE_DISTANCE * (1 - eased))
    self.dialog:draw()
    love.graphics.pop()
end

-- ── Input ────────────────────────────────────────────────────────────────
--
-- Every handler below consumes unconditionally while a dialog is open, whether or
-- not the dialog itself wanted the event -- the same "opaque surface" rule Container
-- applies to one widget's rect, just extended to the whole screen: that's what
-- "blocks input beneath" means for something modal.

function DialogManager:mousemoved(x, y, dx, dy, istouch)
    if not self.dialog then
        return false
    end
    self.dialog:mousemoved(x, y, dx, dy, istouch)
    return true
end

function DialogManager:mousepressed(x, y, button, istouch, presses)
    if not self.dialog then
        return false
    end
    self.dialog:mousepressed(x, y, button, istouch, presses)
    return true
end

function DialogManager:mousereleased(x, y, button, istouch, presses)
    if not self.dialog then
        return false
    end
    self.dialog:mousereleased(x, y, button, istouch, presses)
    return true
end

function DialogManager:wheelmoved(x, y)
    return self.dialog ~= nil
end

local function findButton(buttons, matches)
    for _, button in ipairs(buttons) do
        if matches(button) then
            return button
        end
    end
    return nil
end

local function isDefault(button) return button.isDefault end
local function isCancel(button) return button.isCancel end

function DialogManager:keypressed(key, scancode, isrepeat)
    if not self.dialog then
        return false
    end

    if key == "return" or key == "kpenter" then
        local button = findButton(self.dialog.buttons, isDefault)
        if button then button.onPress(button) end
    elseif key == "escape" then
        -- Only if a button actually claims the cancel role: swallowing Escape but
        -- doing nothing is safer than treating "no explicit cancel" as "dismiss and
        -- proceed" on a dialog whose caller didn't mark that safe.
        local button = findButton(self.dialog.buttons, isCancel)
        if button then button.onPress(button) end
    end

    -- Consumed regardless: every key belongs to the dialog while it's open, same
    -- rule TextEditSession applies to its own field.
    return true
end

return DialogManager
