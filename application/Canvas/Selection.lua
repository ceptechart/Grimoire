local Class = require "lib.util.Class"

-- Which elements are currently selected -- nothing else. No undo history, no
-- serialized form: selection says nothing about the board's content, so it has no
-- business in Document or in a saved file. It lives on Board instead.
--
-- A membership set and nothing more: it holds ids, not elements, and deliberately
-- can't tell you what order they're in. Ask `Document:selectedIds(selection)` for
-- that -- ordering is a property of the document, and a hash set doesn't have one.
local Selection = Class.extend()

function Selection.new()
    return setmetatable({ ids = {}, size = 0 }, Selection)
end

function Selection:clear()
    self.ids = {}
    self.size = 0
end

function Selection:add(id)
    if not self.ids[id] then
        self.ids[id] = true
        self.size = self.size + 1
    end
end

function Selection:remove(id)
    if self.ids[id] then
        self.ids[id] = nil
        self.size = self.size - 1
    end
end

function Selection:toggle(id)
    if self.ids[id] then
        self:remove(id)
    else
        self:add(id)
    end
end

-- Replaces the whole selection with a single element.
function Selection:set(id)
    self.ids = { [id] = true }
    self.size = 1
end

function Selection:contains(id)
    return self.ids[id] == true
end

-- Tracked rather than counted on demand: the status bar asks every frame.
function Selection:count()
    return self.size
end

-- Drops every id the predicate rejects.
--
-- The only way to iterate a selection, and deliberately a narrow one: the order ids
-- come out in is meaningless (that's Document:selectedIds' job), and handing the set
-- out would let a caller mutate it behind the tracked count. Removing the current key
-- mid-`pairs` is the one table mutation Lua guarantees is safe.
function Selection:retain(predicate)
    for id in pairs(self.ids) do
        if not predicate(id) then
            self.ids[id] = nil
            self.size = self.size - 1
        end
    end
end

function Selection:isEmpty()
    return self.size == 0
end

return Selection
