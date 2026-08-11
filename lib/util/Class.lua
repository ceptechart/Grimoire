-- Minimal prototype-based inheritance helper.
--
-- A class is a plain table that doubles as the metatable for its instances.
-- Class.extend(base) chains lookups instance -> class -> base -> ... so a derived
-- class inherits methods without copying them.
--
-- Constructors stay explicit: each class writes its own `new`, and derived
-- constructors call the base's `init` to populate inherited fields. Fields are
-- always assigned in `new`/`init` rather than on the class table itself -- a
-- default parked on the class (`Label.position = Vector2.new(0, 0)`) is a single
-- object shared by every instance that never overwrites it.
local Class = {}

function Class.extend(base)
    local class = setmetatable({}, { __index = base })
    class.__index = class
    class.super = base
    return class
end

return Class
