local Canvas = require "application.Canvas.Canvas"

-- The app's verbs, in one place.
--
-- Every editing command has at least two ways in -- a menu item and a keyboard
-- shortcut, and eventually a context menu and a toolbar button -- and the failure
-- mode when each wires itself up separately is that they drift: the menu keeps
-- working after the shortcut is changed, or one of them grows a guard the other
-- doesn't have. So the callers here are entry points and this is the implementation,
-- rather than three copies of it.
--
-- Every action returns whether it actually did something, which is what a keyboard
-- handler needs in order to decide whether to consume the key. Menus ignore it.
--
-- Deliberately not a Widget, not a subsystem, and not stateful: it holds nothing and
-- loads nothing. Board is resolved lazily because Board requires this at load time --
-- resolving it here at require time would close the cycle.
local Actions = {}

local Board

local function board()
    Board = Board or require "application.Canvas.Board"
    return Board
end

-- ── History ──────────────────────────────────────────────────────────────

function Actions.undo()
    return board():getDocument():undo()
end

function Actions.redo()
    return board():getDocument():redo()
end

function Actions.canUndo()
    return board():getDocument().history:canUndo()
end

function Actions.canRedo()
    return board():getDocument().history:canRedo()
end

-- ── Selection ────────────────────────────────────────────────────────────

function Actions.delete()
    return board():deleteSelection()
end

function Actions.selectAll()
    return board():selectAll()
end

function Actions.deselectAll()
    return board():deselectAll()
end

function Actions.invertSelection()
    return board():invertSelection()
end

-- ── Clipboard ────────────────────────────────────────────────────────────

function Actions.cut()
    return board():cutSelection()
end

function Actions.copy()
    return board():copySelection()
end

function Actions.paste()
    return board():pasteClipboard()
end

-- ── View ─────────────────────────────────────────────────────────────────

function Actions.zoomIn()
    Canvas:zoomIn()
    return true
end

function Actions.zoomOut()
    Canvas:zoomOut()
    return true
end

function Actions.resetZoom()
    Canvas:resetZoom()
    return true
end

function Actions.resetView()
    Canvas:resetView()
    return true
end

return Actions
