local InputManager = require "application.InputManager"
local Toast = require "application.UI.Elements.Toast"

-- Owns the stack of notification toasts in the lower-right corner, above the
-- status bar.
--
-- A Toast only animates itself toward a target row; this decides what that target
-- is. New toasts take the bottom slot and slide in from off screen, everything
-- already in the stack is retargeted one slot higher and eases up to make room, and
-- a toast that finishes fading is pruned and the rest reflow to close the gap.
local ToastManager = {}

local SPACING = 8

local toasts
local anchorY

function ToastManager:load()
    toasts = {}
    anchorY = love.graphics.getHeight()

    -- POPUP outranks CHROME so a toast overlapping the status bar gets first look at
    -- a click, regardless of subscription order.
    InputManager:subscribe("mousepressed", self, InputManager.PRIORITY.POPUP)
end

-- y is the top edge of whatever chrome sits at the bottom of the screen (the status
-- bar); the stack builds upward from there.
function ToastManager:setAnchorY(y)
    anchorY = y
    self:reflow()
end

function ToastManager:show(type, text, options)
    local toast = Toast.new(type, text, options)

    local bottomY = anchorY - Toast.MARGIN - toast:getHeight()
    toast.position:set(love.graphics.getWidth(), bottomY)
    toast:setTargetY(bottomY)

    table.insert(toasts, toast)
    self:reflow()

    return toast
end

-- Newest toast is last in the list and takes the bottom-most slot, so this walks
-- back to front, stacking each one above the last.
function ToastManager:reflow()
    local y = anchorY - Toast.MARGIN
    for i = #toasts, 1, -1 do
        local toast = toasts[i]
        y = y - toast:getHeight()
        toast:setTargetY(y)
        y = y - SPACING
    end
end

function ToastManager:update(dt)
    local screenWidth = love.graphics.getWidth()
    local anyDone = false

    for _, toast in ipairs(toasts) do
        toast:update(dt, screenWidth)
        anyDone = anyDone or toast:isDone()
    end

    if anyDone then
        for i = #toasts, 1, -1 do
            if toasts[i]:isDone() then
                table.remove(toasts, i)
            end
        end
        self:reflow()
    end
end

function ToastManager:draw()
    for _, toast in ipairs(toasts) do
        toast:draw()
    end
end

-- Used by UI:isPointOverUI so canvas hover logic treats the pointer as being over
-- chrome while it's over a toast, not the board beneath it.
function ToastManager:isPointOverToasts(x, y)
    for _, toast in ipairs(toasts) do
        if toast:containsPoint(x, y) then
            return true
        end
    end
    return false
end

function ToastManager:mousepressed(x, y, button, istouch, presses)
    for i = #toasts, 1, -1 do
        if toasts[i]:mousepressed(x, y, button, istouch, presses) then
            return true
        end
    end
    return false
end

return ToastManager
