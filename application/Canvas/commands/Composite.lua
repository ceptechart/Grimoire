local Class = require "lib.util.Class"

-- Groups several commands into one undo step.
--
-- Reverting runs the children backwards, which is what makes the group a true
-- inverse: a later command may depend on what an earlier one did, so undoing in
-- forward order would unwind them against their own preconditions.
local Composite = Class.extend()

function Composite.new(commands)
    return setmetatable({ commands = commands }, Composite)
end

-- The way callers that assemble a command list should build one: a gesture doesn't
-- know up front how many commands it produced (a drag that also raised z-order makes
-- two, one that didn't move makes none), and wrapping a single command in a Composite
-- just to unwrap it again is a layer nobody needs. Returns nil for an empty list, so
-- "nothing happened" reads as a missing command rather than an empty undo step.
function Composite.of(commands)
    if #commands == 0 then
        return nil
    end
    if #commands == 1 then
        return commands[1]
    end
    return Composite.new(commands)
end

function Composite:apply(document)
    for index = 1, #self.commands do
        self.commands[index]:apply(document)
    end
end

function Composite:revert(document)
    for index = #self.commands, 1, -1 do
        self.commands[index]:revert(document)
    end
end

return Composite
