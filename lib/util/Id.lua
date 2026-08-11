local Id = {}

local TEMPLATE = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"

-- Random UUID (version 4). Element ids have to be stable across saves and unique
-- across machines: two people adding an element to the same board offline must not
-- collide, which rules out a counter.
function Id.new()
    return (TEMPLATE:gsub("[xy]", function(placeholder)
        local value = placeholder == "x" and love.math.random(0, 15)
            or love.math.random(8, 11) -- variant bits
        return ("%x"):format(value)
    end))
end

return Id
