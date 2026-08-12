local InputManager = require "application.InputManager"
local Theme = require "application.Style.Theme"
local MathUtil = require "lib.util.math.MathUtil"

-- The infinite board: pan, zoom, and the background grid.
local Canvas = {}

local MIN_ZOOM = 0.1
local MAX_ZOOM = 8
-- Per wheel notch. Small, because a wheel delivers a lot of them.
local ZOOM_STEP = 1.05
-- Per keypress or menu click, where one input is one deliberate step and 5% wouldn't
-- look like anything happened.
local ZOOM_KEY_STEP = 1.25
local PAN_BUTTON = 3

local BASE_GRID_SPACING = 32
local TARGET_SCREEN_SPACING = 64
local SUBGRID_DIVISIONS = 4

Canvas.offset = MathUtil.Vector2.new(0, 0)
Canvas.zoom = 1
Canvas.panning = false

function Canvas:load()
    self.offset:set(love.graphics.getWidth() / 2, love.graphics.getHeight() / 2)

    -- Lowest priority: the canvas only sees pointer input the UI didn't consume.
    InputManager:subscribeAll(InputManager.MOUSE_EVENTS, self, InputManager.PRIORITY.CANVAS)
end

function Canvas:worldToScreenX(x)
    return x * self.zoom + self.offset.x
end

function Canvas:worldToScreenY(y)
    return y * self.zoom + self.offset.y
end

function Canvas:screenToWorldX(x)
    return (x - self.offset.x) / self.zoom
end

function Canvas:screenToWorldY(y)
    return (y - self.offset.y) / self.zoom
end

-- Picks a grid spacing (world units) whose on-screen size stays near
-- TARGET_SCREEN_SPACING regardless of zoom, so the grid never looks too dense or
-- too sparse.
function Canvas:getGridSpacing()
    local spacing = BASE_GRID_SPACING
    while spacing * self.zoom < TARGET_SCREEN_SPACING do
        spacing = spacing * 2
    end
    while spacing * self.zoom > TARGET_SCREEN_SPACING * 2 do
        spacing = spacing / 2
    end
    return spacing
end

function Canvas:drawGridLines(spacing, color, width, height)
    love.graphics.setColor(color:unpacked())

    local worldLeft = self:screenToWorldX(0)
    local worldRight = self:screenToWorldX(width)
    local worldTop = self:screenToWorldY(0)
    local worldBottom = self:screenToWorldY(height)

    for x = math.floor(worldLeft / spacing) * spacing, worldRight, spacing do
        local screenX = self:worldToScreenX(x)
        love.graphics.line(screenX, 0, screenX, height)
    end

    for y = math.floor(worldTop / spacing) * spacing, worldBottom, spacing do
        local screenY = self:worldToScreenY(y)
        love.graphics.line(0, screenY, width, screenY)
    end
end

function Canvas:drawGrid()
    local width, height = love.graphics.getDimensions()
    local spacing = self:getGridSpacing()
    local previousLineWidth = love.graphics.getLineWidth()

    love.graphics.setLineWidth(1)
    self:drawGridLines(spacing / SUBGRID_DIVISIONS, Theme:color("canvasGridSubline"), width, height)
    self:drawGridLines(spacing, Theme:color("canvasGridLine"), width, height)

    love.graphics.setColor(Theme:color("canvasGridOrigin"):unpacked())
    love.graphics.setLineWidth(2)
    local originX = self:worldToScreenX(0)
    local originY = self:worldToScreenY(0)
    love.graphics.line(originX, 0, originX, height)
    love.graphics.line(0, originY, width, originY)

    love.graphics.setLineWidth(previousLineWidth)
end

function Canvas:draw()
    local r, g, b, a = love.graphics.getColor()

    love.graphics.clear(Theme:color("canvasBackground"):unpacked())
    self:drawGrid()

    love.graphics.setColor(r, g, b, a)
end

function Canvas:mousemoved(x, y, dx, dy, istouch)
    if self.panning then
        self.offset:set(self.offset.x + dx, self.offset.y + dy)
    end
end

function Canvas:mousepressed(x, y, button, istouch, presses)
    if button ~= PAN_BUTTON then
        return false
    end

    self.panning = true
    love.mouse.setRelativeMode(true)
    return true
end

function Canvas:mousereleased(x, y, button, istouch, presses)
    if button ~= PAN_BUTTON or not self.panning then
        return false
    end

    self.panning = false
    love.mouse.setRelativeMode(false)
    return true
end

-- Keeps the world point under the cursor fixed while the zoom changes.
function Canvas:zoomAt(screenX, screenY, factor)
    local worldX = self:screenToWorldX(screenX)
    local worldY = self:screenToWorldY(screenY)

    self.zoom = math.max(MIN_ZOOM, math.min(MAX_ZOOM, self.zoom * factor))

    self.offset:set(screenX - worldX * self.zoom, screenY - worldY * self.zoom)
end

-- Zoom without a pointer position to anchor to -- a keyboard shortcut or a View menu
-- item. Anchored to the middle of the window instead, so whatever you were looking at
-- stays roughly where it was.
function Canvas:zoomByStep(factor)
    local width, height = love.graphics.getDimensions()
    self:zoomAt(width / 2, height / 2, factor)
end

function Canvas:zoomIn()
    self:zoomByStep(ZOOM_KEY_STEP)
end

function Canvas:zoomOut()
    self:zoomByStep(1 / ZOOM_KEY_STEP)
end

-- Back to 1:1 without recentering: "reset zoom" is about scale, and quietly panning
-- as well would lose the user's place on the board.
function Canvas:resetZoom()
    self:zoomByStep(1 / self.zoom)
end

function Canvas:wheelmoved(x, y)
    if y == 0 then
        return false
    end

    local mouseX, mouseY = love.mouse.getPosition()
    self:zoomAt(mouseX, mouseY, y > 0 and ZOOM_STEP or 1 / ZOOM_STEP)

    return true
end

return Canvas
