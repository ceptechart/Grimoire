-- Maps a hit-tested handle name to an OS cursor and keeps LOVE's cursor state in
-- sync, without re-setting it on every idle mousemoved (setCursor isn't free, and
-- this runs on every hover check).
local Cursor = {}

-- Cursor objects are created lazily and cached: love.mouse.getSystemCursor
-- allocates.
local cache = {}
local current = "arrow"

local HANDLE_CURSORS = {
    ["resize-e"]  = "sizewe",
    ["resize-w"]  = "sizewe",
    ["resize-n"]  = "sizens",
    ["resize-s"]  = "sizens",
    ["resize-ne"] = "sizenesw",
    ["resize-sw"] = "sizenesw",
    ["resize-nw"] = "sizenwse",
    ["resize-se"] = "sizenwse",
}

local function set(systemCursorName)
    if current == systemCursorName then
        return
    end

    local cursor = cache[systemCursorName]
    if not cursor then
        cursor = love.mouse.getSystemCursor(systemCursorName)
        cache[systemCursorName] = cursor
    end

    love.mouse.setCursor(cursor)
    current = systemCursorName
end

-- handle is whatever a hit test returned: a resize-* name, "move", or nil.
-- Anything without a dedicated cursor (including "move" -- header dragging uses the
-- plain arrow) falls back to the default.
function Cursor:setForHandle(handle)
    set(HANDLE_CURSORS[handle] or "arrow")
end

function Cursor:reset()
    set("arrow")
end

-- The currently-set system cursor name, for tests and debugging.
function Cursor:getCurrent()
    return current
end

return Cursor
