-- Which pointer tool is active, and the list of tools the toolbar offers.
--
-- A tool decides what a left-drag on the canvas means. "select" is the default and
-- is exactly the behaviour everything had before there were tools: click to select,
-- drag an element to move it, drag empty canvas to marquee. A tool carrying a
-- `createType` instead drags out a new element of that type, so a tool for a new
-- element type is one entry in this list -- Board branches on the field, never on a
-- tool's name.
--
-- Pure data plus one piece of state: no love calls and no requires, so both UI
-- (which builds buttons from list()) and Board (which reads getActive()) can depend
-- on it without a cycle. Icons are stored as paths and loaded by whoever draws them,
-- the same way theme files hold font paths rather than Fonts.
local Tools = {}

-- The tool everything falls back to. Named because Board and the UI both reach for
-- it, and because a string literal in three files is one typo away from a bug.
Tools.SELECT = "select"

-- Order here is the order the toolbar shows them in.
--
--   name        stable identifier, and what setActive takes
--   label       human-readable; the toolbar's tooltip once there are tooltips
--   icon        path to the button image
--   shortcut    optional single key that selects this tool
--   createType  optional element type this tool drags out (see CreateGesture)
--   connectType optional element type this tool connects two elements with (see
--               LineGesture) -- mutually exclusive with createType: unlike a plain
--               create, the press has to land on an element already, since a
--               connector means nothing without two elements to join.
local definitions = {
    {
        name = Tools.SELECT,
        label = "Select",
        icon = "res/img/tool/select.png",
        shortcut = "v",
    },
    {
        -- The tool name and the element type happen to match here; they're separate
        -- fields because they won't always (a "sticky note" tool making a "note").
        name = "panel",
        label = "Panel",
        icon = "res/img/tool/panel.png",
        shortcut = "p",
        createType = "panel",
    },
    {
        name = "container",
        label = "Container",
        icon = "res/img/tool/container.png",
        shortcut = "c",
        createType = "container",
    },
    {
        name = "text",
        label = "Text",
        icon = "res/img/tool/text.png",
        shortcut = "t",
        createType = "text",
    },
    {
        name = "image",
        label = "Image",
        icon = "res/img/tool/image.png",
        shortcut = "i",
        createType = "image",
    },
    {
        name = "line",
        label = "Line",
        icon = "res/img/tool/line.png",
        shortcut = "l",
        connectType = "line",
    },
}

local byName = {}
for _, definition in ipairs(definitions) do
    byName[definition.name] = definition
end

local active = byName[Tools.SELECT]

-- The definitions in toolbar order. Treat the result as immutable.
function Tools:list()
    return definitions
end

function Tools:get(name)
    return byName[name]
end

-- Always a definition table, never nil -- callers read `.createType` off it directly.
function Tools:getActive()
    return active
end

function Tools:isActive(name)
    return active.name == name
end

function Tools:setActive(name)
    local definition = byName[name]
    if not definition then
        error("unknown tool: " .. tostring(name), 2)
    end
    active = definition
    return active
end

function Tools:reset()
    return self:setActive(Tools.SELECT)
end

-- The tool a key selects, or nil. Shortcuts are plain unmodified keys, so the caller
-- is responsible for checking no modifier is held.
function Tools:forShortcut(key)
    for _, definition in ipairs(definitions) do
        if definition.shortcut == key then
            return definition
        end
    end
    return nil
end

return Tools
