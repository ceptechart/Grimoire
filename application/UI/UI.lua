local InputManager = require "application.InputManager"
local Panel = require "application.Style.Panel"
local Label = require "application.UI.Elements.Label"
local Button = require "application.UI.Elements.Button"
local MenuBar = require "application.UI.Elements.MenuBar"
local VerticalMenu = require "application.UI.Elements.VerticalMenu"
local ToolBar = require "application.UI.Elements.ToolBar"
local ToastManager = require "application.UI.ToastManager"
local DialogManager = require "application.UI.DialogManager"
local Canvas = require "application.Canvas.Canvas"
local Tools = require "application.Canvas.Tools"
local Actions = require "application.Actions"
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
local APP_VERSION = "a0.1.0"

-- Help > About. A confirm dialog with a single button is the only dialog shape there
-- is so far -- worth a plain alert variant if a second one of these turns up.
local function showAboutDialog()
    DialogManager:confirm({
        title = ("%s %s"):format(APP_NAME, APP_VERSION),
        message = "A local-first bulletin board for game projects.\n\n"
            .. "TODO: "
            .. "Include external libraries and lisences.",
        buttons = {
            { label = "Close", style = "primary", default = true, cancel = true },
        },
    })
end

-- Tool palette geometry. The buttons are circles, so the button size is a diameter
-- and the icon is inset by half the difference; the toggle above them is smaller so
-- it reads as chrome rather than as another tool.
local TOOL_BUTTON_SIZE = 40
local TOOL_ICON_SIZE = 22
local TOGGLE_BUTTON_SIZE = 26
local TOGGLE_ICON_SIZE = 14
-- Distance from the screen's left edge and from the menu bar above.
local TOOL_MARGIN = 12
local TOOL_SPACING = 8

-- A circular button background: a square panel whose corner radius is half its side.
-- Borderless, so a button's size is exactly icon + padding with nothing to inset for,
-- and shadowed because these float over the board rather than sitting in a bar.
local function circlePanel(color, size)
    return Panel.new()
        :withColor(color)
        :withLineWeight(0)
        :withCornerRadius((size or TOOL_BUTTON_SIZE) / 2)
        :withShadow(true)
end

local panels
local topMenuBar
local statusBar
local toolBar
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

        tool              = circlePanel("toolSurface"),
        toolHover         = circlePanel("toolSurfaceHover"),
        toolPress         = circlePanel("toolSurfacePress"),
        toolSelected      = circlePanel("toolSelected"),
        toolSelectedHover = circlePanel("toolSelectedHover"),

        -- Same three states at the toggle's smaller diameter: the radius has to be
        -- half of *its* side or the circle comes out as a rounded square.
        toolToggle      = circlePanel("toolSurface", TOGGLE_BUTTON_SIZE),
        toolToggleHover = circlePanel("toolSurfaceHover", TOGGLE_BUTTON_SIZE),
        toolTogglePress = circlePanel("toolSurfacePress", TOGGLE_BUTTON_SIZE),
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
    local selectionButton = barButton("Selection")
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
        :addLeftItem(selectionButton)
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

    -- Every item below goes through Actions, which is also what Board's keyboard
    -- shortcuts call -- menu and keyboard are two doors onto one implementation.
    local editMenu = buildDropdown(editButton, {
        { "Undo", Actions.undo },
        { "Redo", Actions.redo },
        { "Cut", Actions.cut },
        { "Copy", Actions.copy },
        { "Paste", Actions.paste },
        { "Delete", Actions.delete },
    })
    table.insert(menus, editMenu)

    local selectionMenu = buildDropdown(selectionButton, {
        { "Select All", Actions.selectAll },
        { "Deselect All", Actions.deselectAll },
        { "Invert Selection", Actions.invertSelection },
    })
    table.insert(menus, selectionMenu)

    local viewMenu = buildDropdown(viewButton, {
        { "Zoom In", Actions.zoomIn },
        { "Zoom Out", Actions.zoomOut },
        { "Reset View", Actions.resetView },
        { "Reset Zoom", Actions.resetZoom },
    })
    table.insert(menus, viewMenu)

    local helpMenu = buildDropdown(helpButton, {
        { "About", showAboutDialog },
    })
    table.insert(menus, helpMenu)
end

-- The tool palette down the left edge. Buttons are built from Tools:list(), so a new
-- tool is an entry in Tools.lua and nothing here changes.
local toolButtons
local toggleOpenIcon
local toggleCloseIcon

-- A round icon button: the icon at a fixed size, centred by padding that makes the
-- whole thing square, on a circular panel.
local function circleButton(icon, size, iconSize, statePanels)
    local padding = (size - iconSize) / 2

    local label = Label.new("")
        :withIcon(icon)
        :withIconSize(iconSize)
        :withColor("toolIcon")
        :withPadding(padding, padding)

    return Button.new(label)
        :withPanel(statePanels.default)
        :withHoverPanel(statePanels.hover)
        :withPressPanel(statePanels.press)
        :withStateColor(Button.HOVER, "toolIconHover")
end

local function buildToolBar()
    toggleOpenIcon = love.graphics.newImage("res/img/tool/open.png")
    toggleCloseIcon = love.graphics.newImage("res/img/tool/close.png")

    toolBar = ToolBar.new()
        :withItemSpacing(TOOL_SPACING)
        :withPosition(TOOL_MARGIN, topMenuBar:getHeight() + TOOL_MARGIN)

    local toggle = circleButton(toggleCloseIcon, TOGGLE_BUTTON_SIZE, TOGGLE_ICON_SIZE, {
        default = panels.toolToggle,
        hover = panels.toolToggleHover,
        press = panels.toolTogglePress,
    })
    toggle:withOnPress(function() toolBar:toggle() end)
    toolBar:withToggle(toggle)

    -- Keyed by tool name rather than a plain list: the only thing done with these
    -- afterwards is asking "is your tool the active one", which is a name comparison.
    toolButtons = {}
    for _, tool in ipairs(Tools:list()) do
        local button = circleButton(love.graphics.newImage(tool.icon),
            TOOL_BUTTON_SIZE, TOOL_ICON_SIZE, {
                default = panels.tool,
                hover = panels.toolHover,
                press = panels.toolPress,
            })
            :withSelectedPanel(panels.toolSelected)
            :withSelectedStatePanel(Button.HOVER, panels.toolSelectedHover)
            :withSelectedColor("toolIconSelected")
            :withOnPress(function() Tools:setActive(tool.name) end)

        toolButtons[tool.name] = button
        toolBar:addItem(button)
    end
end

-- Pushed every frame rather than set on press: a tool can also be chosen by keyboard
-- shortcut or reset by Escape (see Board:keypressed), and the button that lights up
-- has to be the active tool's whichever way it was picked.
local function updateToolBar(dt)
    for name, button in pairs(toolButtons) do
        button:withSelected(Tools:isActive(name))
    end

    toolBar:getToggle().label:withIcon(
        toolBar:isExpanded() and toggleCloseIcon or toggleOpenIcon)

    toolBar:update(dt)
end

local mousePositionLabel
local selectionCountLabel
local fileNameLabel
local zoomLabel

local function buildStatusBar()
    fileNameLabel = barLabel("Untitled", "foreground")

    mousePositionLabel = barLabel("X: 0, Y: 0", "muted")
    -- Widest plausible reading, so the bar doesn't shift width as digit count changes.
    mousePositionLabel:withMinWidth(
        mousePositionLabel:getFont():getWidth("X: -9999, Y: -9999")
        + mousePositionLabel.padding.x * 2 + mousePositionLabel:getBorderWidth() * 2)

    selectionCountLabel = barLabel("0 Selected", "muted")

    -- Zoom is now reachable from the keyboard and the View menu, neither of which is
    -- attached to a pointer position, so it needs a readout to land on.
    zoomLabel = barLabel("100%", "muted")

    statusBar = MenuBar.new()
        :withPanel(panels.bar)
        :withPadding(12, 4)
        :withItemSpacing(16)
        :withMinWidth(love.graphics.getWidth())
        :addLeftItem(fileNameLabel)
        :addLeftItem(mousePositionLabel)
        :addLeftItem(selectionCountLabel)
        :addRightItem(zoomLabel)

    statusBar:withPosition(0, love.graphics.getHeight() - statusBar:getHeight())
end

local function updateStatusBar()
    Board = Board or require "application.Canvas.Board"

    -- Name of the open board, with a trailing asterisk while it has unsaved edits.
    fileNameLabel:withText(BoardFile:getStatusText())

    local mouseX, mouseY = love.mouse.getPosition()
    local worldX = Canvas:screenToWorldX(mouseX)
    local worldY = Canvas:screenToWorldY(mouseY)
    mousePositionLabel:withText(("X: %.2f, Y: %.2f"):format(worldX, worldY))

    local count = Board:getSelection():count()
    selectionCountLabel:withText(("%d Selected"):format(count))

    zoomLabel:withText(("%d%%"):format(math.floor(Canvas.zoom * 100 + 0.5)))
end

function UI:load()
    -- Before buildTopMenuBar: the File menu's items call straight into it.
    BoardFile = require "application.BoardFile"

    buildPanels()
    buildTopMenuBar()
    buildStatusBar()
    -- After the menu bar: the palette hangs below it, so it needs its height.
    buildToolBar()

    layers = { topMenuBar, statusBar, toolBar }
    for _, menu in ipairs(menus) do
        table.insert(layers, menu)
    end

    ToastManager:load()
    ToastManager:setAnchorY(statusBar.position.y)

    -- POPUP outranks CHROME so an open menu sees clicks before the bar behind it.
    InputManager:subscribeAll(InputManager.MOUSE_EVENTS, topMenuBar, InputManager.PRIORITY.CHROME)
    InputManager:subscribeAll(InputManager.MOUSE_EVENTS, statusBar, InputManager.PRIORITY.CHROME)
    InputManager:subscribeAll(InputManager.MOUSE_EVENTS, toolBar, InputManager.PRIORITY.CHROME)
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
    -- The palette is a column of separate circles, not a strip: its containsPoint is
    -- true only over a button, so the gaps between them stay canvas.
    if toolBar:containsPoint(x, y) then
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
    updateToolBar(dt)
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
