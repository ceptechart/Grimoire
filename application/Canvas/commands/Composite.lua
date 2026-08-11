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
