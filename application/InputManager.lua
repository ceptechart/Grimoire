local InputManager = {}

-- Handlers receive events in descending priority order and consume an event by
-- returning true, which stops it reaching anything below. This is what lets the
-- canvas subscribe to raw mouse input without having to ask the UI whether the
-- pointer happens to be over a menu.
InputManager.PRIORITY = {
    MODAL   = 400,
    POPUP   = 300,
    CHROME  = 200,
    ELEMENT = 100,
    CANVAS  = 0,
}

local EVENTS = {
    "keypressed",
    "keyreleased",
    -- textinput is a typed character, already mapped through the OS keyboard layout;
    -- textedited is an in-progress IME composition, which isn't text yet.
    "textinput",
    "textedited",
    "mousemoved",
    "mousepressed",
    "mousereleased",
    "wheelmoved",
}

-- Convenience set for widgets, which want every pointer event at one priority.
InputManager.MOUSE_EVENTS = {
    "mousemoved",
    "mousepressed",
    "mousereleased",
    "wheelmoved",
}

-- mousemoved reaches every handler even after one consumes it. Widgets derive
-- hover state from the pointer position, so a widget the pointer has just left
-- still needs the event in order to clear that state.
--
-- mousereleased is broadcast for the same underlying reason: a handler mid-gesture
-- (Canvas panning, Board's move/resize/marquee/create, a text selection drag) tracks
-- "is this happening" in its own state, not by position, and the button going up is
-- what has to end it -- regardless of whether the pointer is currently over a
-- higher-priority widget that would otherwise consume the event first. Every such
-- handler already guards on its own state (self.panning, self.gesture, ...), so the
-- broadcast is a no-op for handlers that weren't mid-gesture.
local BROADCAST_EVENTS = {
    mousemoved = true,
    mousereleased = true,
}

local subscriptions = {}
for _, event in ipairs(EVENTS) do
    subscriptions[event] = {}
end

local function subscriptionsFor(event)
    local handlers = subscriptions[event]
    if not handlers then
        error("unknown input event: " .. tostring(event), 3)
    end
    return handlers
end

-- Registers handler:<event>(...) at the given priority. Equal priorities keep
-- subscription order, so peers run oldest-first.
function InputManager:subscribe(event, handler, priority)
    local handlers = subscriptionsFor(event)

    if type(handler[event]) ~= "function" then
        error("handler has no '" .. tostring(event) .. "' callback", 2)
    end

    priority = priority or self.PRIORITY.ELEMENT

    local index = #handlers + 1
    for i, entry in ipairs(handlers) do
        if entry.priority < priority then
            index = i
            break
        end
    end

    table.insert(handlers, index, { handler = handler, priority = priority })
end

-- Subscribes to each event the handler actually implements, so a widget that
-- ignores (say) the scroll wheel doesn't have to declare an empty callback.
function InputManager:subscribeAll(events, handler, priority)
    for _, event in ipairs(events) do
        if type(handler[event]) == "function" then
            self:subscribe(event, handler, priority)
        end
    end
end

function InputManager:unsubscribe(event, handler)
    local handlers = subscriptionsFor(event)
    for i = #handlers, 1, -1 do
        if handlers[i].handler == handler then
            table.remove(handlers, i)
        end
    end
end

function InputManager:unsubscribeAll(handler)
    for _, event in ipairs(EVENTS) do
        self:unsubscribe(event, handler)
    end
end

-- Returns true if any handler consumed the event. The handler list is walked in
-- place, so subscribing or unsubscribing from inside a callback is not supported.
function InputManager:dispatch(event, ...)
    local handlers = subscriptionsFor(event)
    local broadcast = BROADCAST_EVENTS[event]
    local consumed = false

    for i = 1, #handlers do
        local handler = handlers[i].handler
        if handler[event](handler, ...) then
            if not broadcast then
                return true
            end
            consumed = true
        end
    end

    return consumed
end

return InputManager
