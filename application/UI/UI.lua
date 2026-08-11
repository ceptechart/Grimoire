local InputManager = require "application.InputManager"
local Panel = require "application.Style.Panel"
local Label = require "application.UI.Elements.Label"
local Button = require "application.UI.Elements.Button"
local MenuBar = require "application.UI.Elements.MenuBar"
local VerticalMenu = require "application.UI.Elements.VerticalMenu"
local ToastManager = require "application.UI.ToastManager"
local Canvas = require "application.Canvas.Canvas"
-- Both lazily required: Board requires UI, so requiring either here at load time
-- would be a circular require. Board is resolved in updateStatusBar, BoardFile in
-- UI:load() -- by then every module in the cycle is loaded.
local Board
local BoardFile

-- The application chrome: menu bar, status bar, and the menus they open.
--
-- Everything is built in load() rather than at require time, so the theme is
-- guaranteed to be loaded first and so the chrome can be rebuilt later (for a theme
-- swap, say) without restarting.
local UI = {}

local APP_NAME = "Grimoire"

local panels
local topMenuBar
local statusBar
local menus

-- Drawn back to front. Menus come last so they overlay the bars that open them.
local layers

-- Panels carry no position, so one instance backs every widget that shares a style.
local function buildPanels()
    panels = {
        bar = Panel.new()
            :withColor("surface")
            :withLineColor("border")
            :withCornerRadius(0),

        menu = Panel.new()
            :withColor("surface")
            :withLineColor("border"),

        buttonHover = Panel.new()
            :withColor("surfaceHover")
            :withLineWeight(0),

        buttonPress = Panel.new()
            :withColor("surfacePress")
            :withLineWeight(0),
    }
end

local function barLabel(text, color)
    return Label.new(text)
        :withFont("small")
        :withColor(color or "foreground")
        :withPadding(8, 4)
end

local function barButton(text)
    return Button.new(barLabel(text))
        :withHoverPanel(panels.buttonHover)
        :withPressPanel(panels.buttonPress)
end

local function barIconButton(icon)
    return Button.new(barLabel(""):withFont("medium"):withIcon(icon))
        :withHoverPanel(panels.buttonHover)
        :withPressPanel(panels.buttonPress)
end

-- Builds the dropdown anchored beneath `button` and wires the button to toggle it,
-- closing any other open top-menu dropdown first (only one open at a time).
local function buildDropdown(button, itemSpecs)
    local menu = VerticalMenu.new()
        :withPanel(panels.menu)
        :withPadding(4, 4)
        :withItemSpacing(2)
        :withMinWidth(button:getWidth())
        :withAnchor(button)
        :withPosition(button.position.x, button.position.y + button:getHeight())

    for _, spec in ipairs(itemSpecs) do
        menu:addItem(barButton(spec[1]):withOnPress(spec[2]))
    end

    button:withOnPress(function()
        local wasVisible = menu.visible
        for _, other in ipairs(menus) do
            other:close()
        end
        if not wasVisible then
            menu:open()
        end
    end)

    return menu
end

local function buildTopMenuBar()
    local fileButton = barButton("File")
    local editButton = barButton("Edit")
    local viewButton = barButton("View")
    local helpButton = barButton("Help")

    topMenuBar = MenuBar.new()
        :withPanel(panels.bar)
        :withPadding(12, 4)
        :withItemSpacing(2)
        :withPosition(0, 0)
        :withMinWidth(love.graphics.getWidth())
        :addLeftItem(fileButton)
        :addLeftItem(editButton)
        :addLeftItem(viewButton)
        :addLeftItem(helpButton)
        :addCenterItem(barLabel(APP_NAME, "accent"))

    -- Positions the buttons now so their menus can anchor beneath them.
    topMenuBar:layout()

    menus = {}

    -- Same entry points the Ctrl+N/O/S shortcuts call, so menu and keyboard can't
    -- drift apart.
    local fileMenu = buildDropdown(fileButton, {
        { "New", function() BoardFile:new() end },
        { "Open", function() BoardFile:open() end },
        { "Save", function() BoardFile:save() end },
        { "Save As", function() BoardFile:saveAs() end },
        { "Exit", function() love.event.quit() end },
    })
    table.insert(menus, fileMenu)

    local editMenu = buildDropdown(editButton, {
        { "Undo", function() print("Undo pressed!") end },
        { "Redo", function() print("Redo pressed!") end },
        { "Cut", function() print("Cut pressed!") end },
        { "Copy", function() print("Copy pressed!") end },
        { "Paste", function() print("Paste pressed!") end },
        { "Delete", function() print("Delete pressed!") end },
    })
    table.insert(menus, editMenu)

    local viewMenu = buildDropdown(viewButton, {
        { "Zoom In", function() print("Zoom In pressed!") end },
        { "Zoom Out", function() print("Zoom Out pressed!") end },
        { "Reset Zoom", function() print("Reset Zoom pressed!") end },
    })
    table.insert(menus, viewMenu)

    local helpMenu = buildDropdown(helpButton, {
        { "Documentation", function() print("Documentation pressed!") end },
        { "About", function() print("About pressed!") end },
    })
    table.insert(menus, helpMenu)
end

local mousePositionLabel
local selectionCountLabel
local fileNameLabel

local function buildStatusBar()
    local refreshIcon = love.graphics.newImage("res/img/icon/refresh_icon.png")

    fileNameLabel = barLabel("Untitled", "foreground")

    mousePositionLabel = barLabel("X: 0, Y: 0", "muted")
    -- Widest plausible reading, so the bar doesn't shift width as digit count changes.
    mousePositionLabel:withMinWidth(
        mousePositionLabel:getFont():getWidth("X: -9999, Y: -9999")
        + mousePositionLabel.padding.x * 2 + mousePositionLabel:getBorderWidth() * 2)

    selectionCountLabel = barLabel("0 Selected", "muted")

    statusBar = MenuBar.new()
        :withPanel(panels.bar)
        :withPadding(12, 4)
        :withItemSpacing(16)
        :withMinWidth(love.graphics.getWidth())
        :addLeftItem(fileNameLabel)
        :addLeftItem(mousePositionLabel)
        :addLeftItem(selectionCountLabel)
        :addRightItem(barIconButton(refreshIcon):withOnPress(function() print("Refresh pressed!") end))

    statusBar:withPosition(0, love.graphics.getHeight() - statusBar:getHeight())
end

local function updateStatusBar()
    Board = Board or require "application.Canvas.Board"

    -- Name of the open board, with a trailing asterisk while it has unsaved edits.
    fileNameLabel:withText(BoardFile:getStatusText())

    local mouseX, mouseY = love.mouse.getPosition()
    local worldX = Canvas:screenToWorldX(mouseX)
    local worldY = Canvas:screenToWorldY(mouseY)
    mousePositionLabel:withText(("X: %.2f, Y: %.2f"):format(worldX/100, worldY/100))

    local count = Board:getSelection():count()
    selectionCountLabel:withText(("%d Selected"):format(count))
end

function UI:load()
    -- Before buildTopMenuBar: the File menu's items call straight into it.
    BoardFile = require "application.BoardFile"

    buildPanels()
    buildTopMenuBar()
    buildStatusBar()

    layers = { topMenuBar, statusBar }
    for _, menu in ipairs(menus) do
        table.insert(layers, menu)
    end

    ToastManager:load()
    ToastManager:setAnchorY(statusBar.position.y)

    -- POPUP outranks CHROME so an open menu sees clicks before the bar behind it.
    InputManager:subscribeAll(InputManager.MOUSE_EVENTS, topMenuBar, InputManager.PRIORITY.CHROME)
    InputManager:subscribeAll(InputManager.MOUSE_EVENTS, statusBar, InputManager.PRIORITY.CHROME)
    for _, menu in ipairs(menus) do
        InputManager:subscribeAll(InputManager.MOUSE_EVENTS, menu, InputManager.PRIORITY.POPUP)
    end
end

-- Public entry point for the rest of the app to raise a notification. options:
-- { timeout = seconds or false for no auto-dismiss, onClick = function(toast) }
function UI:showToast(type, text, options)
    return ToastManager:show(type, text, options)
end

-- Cursor ownership is exclusive, global OS state -- unlike click routing (handled by
-- InputManager's priority + consumption), only one thing can own the cursor icon at
-- a time. mousemoved deliberately reaches every handler regardless of who consumed
-- it (see InputManager's BROADCAST_EVENTS note), so canvas code can't tell from
-- consumption alone whether the pointer is actually over the chrome. This is the
-- direct position query for that -- not meant for click routing, which doesn't need it.
function UI:isPointOverUI(x, y)
    if topMenuBar:containsPoint(x, y) then
        return true
    end
    if statusBar:containsPoint(x, y) then
        return true
    end
    for _, menu in ipairs(menus) do
        if menu.visible and menu:containsPoint(x, y) then
            return true
        end
    end
    if ToastManager:isPointOverToasts(x, y) then
        return true
    end
    return false
end

function UI:update(dt)
    updateStatusBar()
    ToastManager:update(dt)
end

function UI:draw()
    for _, widget in ipairs(layers) do
        widget:draw()
    end
    ToastManager:draw()
end

function UI:resize(width, height)
    topMenuBar:withMinWidth(width)

    statusBar:withMinWidth(width)
    statusBar:withPosition(0, height - statusBar:getHeight())

    ToastManager:setAnchorY(statusBar.position.y)
end

return UI
