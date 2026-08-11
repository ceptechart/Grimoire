local InputManager = require "application.InputManager"
local Theme = require "application.Style.Theme"
local Canvas = require "application.Canvas.Canvas"
local Board = require "application.Canvas.Board"
local UI = require "application.UI.UI"

local DEFAULT_THEME = require "application.Style.themes.Dark"

-- Owns application lifecycle and the order subsystems load and draw in.
local ApplicationManager = {}

-- Registered above everything else so it works no matter what has the pointer.
local quitHandler = {
    keypressed = function(_, key)
        if key == "escape" then
            love.event.quit()
            return true
        end
        return false
    end,
}

function ApplicationManager:load()
    -- Before any subsystem loads: widgets resolve theme tokens, and Canvas and UI
    -- both read colors as soon as they draw.
    Theme:load(DEFAULT_THEME)

    InputManager:subscribe("keypressed", quitHandler, InputManager.PRIORITY.MODAL)

    Canvas:load()
    Board:load()
    UI:load()
end

function ApplicationManager:update(dt)
    UI:update(dt)
end

function ApplicationManager:draw()
    Canvas:draw()
    Board:draw()
    UI:draw()
end

function ApplicationManager:resize(width, height)
    UI:resize(width, height)
end

-- Returning true from love.quit aborts it; this is where an unsaved-changes prompt
-- will go.
function ApplicationManager:quit()
    return false
end

return ApplicationManager
