local InputManager = require "application.InputManager"
local Theme = require "application.Style.Theme"
local Canvas = require "application.Canvas.Canvas"
local Board = require "application.Canvas.Board"
local UI = require "application.UI.UI"
local BoardFile = require "application.BoardFile"
local TextEditSession = require "application.Text.TextEditSession"
local DialogManager = require "application.UI.DialogManager"

local DEFAULT_THEME = require "application.Style.themes.Dark"

-- Owns application lifecycle and the order subsystems load and draw in.
local ApplicationManager = {}


function ApplicationManager:load()
    -- Before any subsystem loads: widgets resolve theme tokens, and Canvas and UI
    -- both read colors as soon as they draw.
    Theme:load(DEFAULT_THEME)

    -- Held Backspace and arrows have to repeat for text editing to be usable.
    -- Everything that handles a shortcut either wants the repeat (undo) or ignores
    -- it explicitly (BoardFile's file actions).
    love.keyboard.setKeyRepeat(true)

    Canvas:load()
    Board:load()
    UI:load()
    TextEditSession:load()
    DialogManager:load()

    -- Last: it reads the board's state for the window title and raises toasts
    -- through UI, so both have to exist first.
    BoardFile:load()
end

function ApplicationManager:update(dt)
    UI:update(dt)
    TextEditSession:update(dt)
    DialogManager:update(dt)
    BoardFile:update(dt)
end

function ApplicationManager:draw()
    Canvas:draw()
    Board:draw()
    UI:draw()

    -- Board draws world-space fields inside its own transform; this is the pass for
    -- fields anchored to the chrome, which belong over the top of it.
    TextEditSession:drawIn("screen")

    -- Last: a modal dialog dims and sits over everything else, toasts included.
    DialogManager:draw()
end

function ApplicationManager:resize(width, height)
    UI:resize(width, height)
end

-- Returning true from love.quit aborts it, which is how the unsaved-changes prompt
-- gets to stop the app closing over the top of unsaved work.
function ApplicationManager:quit()
    return BoardFile:shouldBlockQuit()
end

return ApplicationManager
