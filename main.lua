-- ATTACH DEBUGGER --
-- Captured unconditionally: love.errorhandler below needs it in both modes.
local defaultErrorHandler = love.errorhandler

if arg[2] == "debug" then
    require("lldebugger").start()
end

local ApplicationManager = require "application.ApplicationManager"
local InputManager = require "application.InputManager"

-- `love . test [name]` runs tests/<name>.lua (default "smoke") against the real app
-- instead of waiting for a user, then quits with a non-zero status if anything
-- failed. The app loads exactly as normal -- the runner only supplies the input.
local testRunner = arg[2] == "test" and require "tests.runner" or nil

-- LOVE 2D CALLBACKS --
function love.load()
    ApplicationManager:load()

    if testRunner then
        testRunner.load(arg[3])
    end
end

function love.update(dt)
    ApplicationManager:update(dt)

    if testRunner then
        testRunner.update()
    end
end

function love.draw()
    ApplicationManager:draw()
end

function love.quit()
    return ApplicationManager:quit()
end

function love.resize(w, h)
    ApplicationManager:resize(w, h)
end

-- Input goes straight to InputManager, which routes it by priority and stops at
-- the first handler that consumes it.
function love.keypressed(key, scancode, isrepeat)
    InputManager:dispatch("keypressed", key, scancode, isrepeat)
end

function love.keyreleased(key, scancode)
    InputManager:dispatch("keyreleased", key, scancode)
end

function love.textinput(text)
    InputManager:dispatch("textinput", text)
end

function love.textedited(text, start, length)
    InputManager:dispatch("textedited", text, start, length)
end

function love.mousemoved(x, y, dx, dy, istouch)
    InputManager:dispatch("mousemoved", x, y, dx, dy, istouch)
end

function love.mousepressed(x, y, button, istouch, presses)
    InputManager:dispatch("mousepressed", x, y, button, istouch, presses)
end

function love.mousereleased(x, y, button, istouch, presses)
    InputManager:dispatch("mousereleased", x, y, button, istouch, presses)
end

function love.wheelmoved(x, y)
    InputManager:dispatch("wheelmoved", x, y)
end

function love.errorhandler(msg)
    if lldebugger then
        error(msg, 2)
    end
    return defaultErrorHandler(msg)
end
