local Class = require "lib.util.Class"

-- Changes any set of an element's props, recording what they were.
--
-- The generic prop editor: a title rename, a note body, a colour override. Props are
-- arbitrary values rather than numbers, so unlike MoveElements there's no delta to
-- store -- the old and new values *are* the delta, and both are captured up front so
-- apply and revert stay exact inverses however far the user walks the stack.
local SetProps = Class.extend()

-- A Lua table can't hold nil, so "this prop wasn't set" needs a value of its own.
-- Assigning it writes nil back, which is what makes adding a prop undoable.
local NONE = setmetatable({}, { __tostring = function() return "SetProps.NONE" end })
SetProps.NONE = NONE

function SetProps.new(id, newValues, oldValues)
    return setmetatable({
        id = id,
        newValues = newValues,
        oldValues = oldValues,
    }, SetProps)
end

-- The usual way in: reads the current values off the element as the old ones.
function SetProps.capture(element, newValues)
    local oldValues = {}
    for key in pairs(newValues) do
        local existing = element.props[key]
        oldValues[key] = existing == nil and NONE or existing
    end
    return SetProps.new(element.id, newValues, oldValues)
end

local function assign(document, id, values)
    local element = document:getById(id)
    -- Skip silently: the element may have been removed by a later command the user
    -- has since undone past. Same rule as MoveElements.
    if not element then
        return
    end

    for key, value in pairs(values) do
        if value == NONE then
            element.props[key] = nil
        else
            element.props[key] = value
        end
    end
end

function SetProps:apply(document)
    assign(document, self.id, self.newValues)
end

function SetProps:revert(document)
    assign(document, self.id, self.oldValues)
end

return SetProps
