local Class = require "lib.util.Class"

-- Which elements are currently selected -- nothing else. No undo history, no
-- serialized form: selection says nothing about the board's content, so it has no
-- business in Document or in a saved file. It lives on Board instead.
local Selection = Class.extend()

function Selection.new()
    return setmetatable({ ids = {} }, Selection)
end

function Selection:clear()
    self.ids = {}
end

function Selection:add(id)
    self.ids[id] = true
end

function Selection:remove(id)
    self.ids[id] = nil
end

function Selection:toggle(id)
    if self.ids[id] then
        self.ids[id] = nil
    else
        self.ids[id] = true
    end
end

-- Replaces the whole selection with a single element.
function Selection:set(id)
    self.ids = { [id] = true }
end

function Selection:contains(id)
    return self.ids[id] == true
end

function Selection:count()
    local count = 0
    for _ in pairs(self.ids) do
        count = count + 1
    end
    return count
end

function Selection:isEmpty()
    return next(self.ids) == nil
end

-- Order is unspecified; callers that move or raise a selection don't care.
function Selection:list()
    local list = {}
    for id in pairs(self.ids) do
        table.insert(list, id)
    end
    return list
end

return Selection
