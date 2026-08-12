local Class = require "lib.util.Class"
local Theme = require "application.Style.Theme"
local Canvas = require "application.Canvas.Canvas"
local Gesture = require "application.Canvas.gestures.Gesture"
local AddElement = require "application.Canvas.commands.AddElement"
local LineElement = require "application.Canvas.elements.LineElement"

-- Dragging out a line connecting two elements, for any tool carrying a `connectType`
-- (see Tools.lua). Unlike CreateGesture, the pointer position alone doesn't describe
-- anything to make -- a connector means nothing without two elements to join -- so
-- the press has to land on one already (Board:mousepressed hit-tests for it before
-- this gesture is even created) and the release has to land on a second, different
-- one or nothing is added.
--
-- Nothing is added to the document until release, the same as CreateGesture and for
-- the same reason: the command is the change happening for the first time, so it's
-- executed rather than pushed as already-applied.
local LineGesture = Class.extend(Gesture)

-- Matches CreateGesture's own ghost opacity: solid enough to read, not solid enough
-- to mistake for a line that's already connected.
local PREVIEW_OPACITY = 0.5

function LineGesture.new(board, connectType, fromElement, worldX, worldY)
    local gesture = Gesture.init(setmetatable({}, LineGesture), board, worldX, worldY)
    gesture.connectType = connectType
    gesture.fromId = fromElement.id
    return gesture
end

-- update() has nothing to do -- nothing lives in the document until release, and the
-- preview reads self.currentX/currentY directly in draw() -- but Gesture:move calls
-- it unconditionally, so the base no-op implementation is inherited rather than
-- overridden here.

-- The element under the pointer right now, if it's a valid second endpoint: a real
-- element, not another line (connectType is "line", so this also rules out chaining
-- a connector off another connector), and not the one the drag started from.
function LineGesture:hoveredTarget()
    local target = self.document:elementAt(self.currentX, self.currentY)
    if target and target.type ~= self.connectType and target.id ~= self.fromId then
        return target
    end
    return nil
end

function LineGesture:finish()
    local toElement = self:hoveredTarget()
    if not toElement then
        return nil, false
    end

    local fromElement = self.document:getById(self.fromId)
    if not fromElement then
        return nil, false
    end

    local element = LineElement.connect(fromElement, toElement)

    -- Selected as it lands, the same as CreateGesture leaves the thing it just made --
    -- so switching back to the select tool has something under the pointer already.
    self.selection:set(element.id)

    return AddElement.new(element), false
end

-- Follows the pointer to a snapped preview once it's over a valid second element, and
-- to the raw pointer position otherwise -- so the line visibly commits to a target
-- before the drag actually has to end there.
function LineGesture:draw()
    local fromElement = self.document:getById(self.fromId)
    if not fromElement then
        return
    end

    local toElement = self:hoveredTarget()
    local fromX, fromY, toX, toY
    if toElement then
        fromX, fromY, toX, toY = LineElement.previewPoints(fromElement, toElement)
    else
        fromX, fromY = LineElement.anchorPoint(fromElement, self.currentX, self.currentY)
        toX, toY = self.currentX, self.currentY
    end

    Theme:pushOpacity(PREVIEW_OPACITY)
    LineElement.drawSegment(fromX, fromY, toX, toY, Theme:color("line"), Canvas.zoom)
    Theme:popOpacity()
end

return LineGesture
