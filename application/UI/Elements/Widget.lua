local Class = require "lib.util.Class"
local MathUtil = require "lib.util.math.MathUtil"

-- Base for anything that occupies a rect on screen and can be laid out by a
-- container. Subclasses supply getWidth/getHeight/draw; the rest is shared
-- plumbing.
local Widget = Class.extend()

-- Populates the fields every widget owns. Subclass constructors call this on their
-- fresh instance before adding their own state, so no mutable default ever sits on
-- a class table where instances would share it.
function Widget.init(widget)
    widget.position = MathUtil.Vector2.new(0, 0)
    widget.padding = MathUtil.Vector2.new(0, 0)
    widget.panel = nil
    widget.minWidth = 0
    widget.bounds = MathUtil.BoundingBox.new()
    return widget
end

function Widget:withPosition(x, y)
    self.position:set(x, y)
    return self
end

function Widget:withMinWidth(width)
    self.minWidth = width
    return self
end

function Widget:withPadding(x, y)
    self.padding:set(x, y)
    return self
end

function Widget:withPanel(panel)
    self.panel = panel
    return self
end

-- Width of the panel's border on one side. Widgets inset their content by this so
-- the border never draws over what's inside.
function Widget:getBorderWidth()
    return self.panel and self.panel:getLineWeight() or 0
end

-- Subclasses override this, not getWidth, so minWidth applies uniformly.
function Widget:getDefaultWidth()
    return 0
end

function Widget:getWidth()
    return math.max(self.minWidth, self:getDefaultWidth())
end

function Widget:getHeight()
    return 0
end

-- Reuses one BoundingBox per widget: the result is valid only until the next call
-- on the same widget. Fine for hit tests, but it must not be stored.
function Widget:getBoundingBox()
    return self.bounds:set(self.position.x, self.position.y, self:getWidth(), self:getHeight())
end

function Widget:containsPoint(x, y)
    return self:getBoundingBox():containsXY(x, y)
end

function Widget:draw()
end

return Widget
