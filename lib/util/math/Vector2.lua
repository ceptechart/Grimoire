local Class = require "lib.util.Class"

local Vector2 = Class.extend()

function Vector2.new(x, y)
    return setmetatable({ x = x or 0, y = y or 0 }, Vector2)
end

-- Mutating setter, for updating a vector that is re-read every frame (a widget's
-- position, say) without allocating a replacement each time.
function Vector2:set(x, y)
    self.x = x or 0
    self.y = y or 0
    return self
end

function Vector2:unpacked()
    return self.x, self.y
end

return Vector2
