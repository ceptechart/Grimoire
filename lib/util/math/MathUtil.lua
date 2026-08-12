local MathUtil = {}

MathUtil.Vector2 = require "lib.util.math.Vector2"
MathUtil.Color = require "lib.util.math.Color"
MathUtil.BoundingBox = require "lib.util.math.BoundingBox"

-- Frame-rate independent ease toward a target: the remaining distance decays
-- exponentially, so the motion reads the same at 60 and 144 fps and a target that
-- changes mid-flight is picked up smoothly rather than restarting.
--
-- `duration` is "time to mostly arrive" rather than a literal asymptote, which is
-- what the factor of 4 buys. Never reaches the target exactly -- callers that need a
-- resting state snap once they're within a hair of it.
function MathUtil.approach(current, target, dt, duration)
    local rate = 1 - math.exp(-dt / duration * 4)
    return current + (target - current) * rate
end

return MathUtil