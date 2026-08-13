-- The test harness behind `love . test [name]`, which loads `tests/<name>.lua`
-- (default "smoke") and drives it through the real frame loop.
--
-- There is no headless mode and no mocking. Most of this codebase only means anything
-- with a graphics context and a running event loop -- fonts have widths, the input
-- manager dispatches, gestures span frames -- so a test here is the actual app with
-- synthetic input pushed into `InputManager:dispatch`, which is the same door
-- `love.mousepressed` uses. That makes these integration tests by nature, and it's
-- why they live behind a launch argument rather than in a separate process.
--
-- It replaces the older workflow of pasting assertions into `love.update` and
-- scrubbing them out again afterwards: the scrubbing was the step that kept losing
-- them, so the scaffolding is a tracked file instead.
--
-- A test file returns an array of step functions. One runs per frame, in order, which
-- is what lets a test hold a gesture open across frames (press on one, capture a
-- screenshot on the next, release on a third) and see the same thing a user would.
-- Steps run under pcall, so one blowing up is a reported failure rather than the end
-- of the run.
local InputManager = require "application.InputManager"

local Runner = {}

-- Frames to let the app settle before the first step: fonts, layout, and the tool
-- palette's slide-in all want a tick before anything hit-tests against them.
local SETTLE_FRAMES = 3

local steps = {}
local frame = 0
local passes, failures = 0, 0

-- ── Assertions ───────────────────────────────────────────────────────────

function Runner.check(name, ok, detail)
    if ok then
        passes = passes + 1
        print("PASS  " .. name)
    else
        failures = failures + 1
        print("FAIL  " .. name .. (detail ~= nil and ("  -- " .. tostring(detail)) or ""))
    end
    return ok
end

function Runner.eq(name, actual, expected)
    return Runner.check(name, actual == expected,
        ("got %s, want %s"):format(tostring(actual), tostring(expected)))
end

-- For anything that has been through world/screen conversion, where exact equality is
-- the wrong question.
function Runner.near(name, actual, expected, tolerance)
    return Runner.check(name, math.abs(actual - expected) <= (tolerance or 0.001),
        ("got %s, want %s"):format(tostring(actual), tostring(expected)))
end

-- ── Synthetic input ──────────────────────────────────────────────────────
--
-- Everything goes through InputManager:dispatch rather than the love.* callbacks, for
-- the same reason the app does: dispatch is where priority and consumption live, and
-- the callbacks are a one-line shim over it.

function Runner.press(x, y, presses)
    return InputManager:dispatch("mousepressed", x, y, 1, false, presses or 1)
end

function Runner.moveTo(x, y)
    return InputManager:dispatch("mousemoved", x, y, 0, 0, false)
end

function Runner.release(x, y)
    return InputManager:dispatch("mousereleased", x, y, 1, false, 1)
end

-- A whole press-move-release in one call, for gestures a test doesn't need to see
-- mid-flight. The midpoint move matters: a gesture that only ever saw its start and
-- end points would hide a bug in how it accumulates.
function Runner.drag(x1, y1, x2, y2)
    Runner.press(x1, y1)
    Runner.moveTo((x1 + x2) / 2, (y1 + y2) / 2)
    Runner.moveTo(x2, y2)
    Runner.release(x2, y2)
end

-- One wheel notch, positive being up/away. LOVE's wheelmoved carries the amount and
-- not a position, so a handler that cares where the pointer is reads it from the
-- real mouse -- which means a test driving this has to set that first, the same way
-- the paste tests do.
function Runner.wheel(dy)
    return InputManager:dispatch("wheelmoved", 0, dy)
end

function Runner.key(key)
    return InputManager:dispatch("keypressed", key, key, false)
end

function Runner.typeText(text)
    return InputManager:dispatch("textinput", text)
end

-- ── Helpers ──────────────────────────────────────────────────────────────

-- A document's element ids as one comparable string, for asserting z-order survived
-- a round trip.
function Runner.orderOf(document)
    local out = {}
    for index, element in ipairs(document.elements) do
        out[index] = element.id
    end
    return table.concat(out, ",")
end

-- Written to the LOVE save directory, whose path is printed at the end of a run.
function Runner.screenshot(name)
    love.graphics.captureScreenshot(name .. ".png")
end

-- ── Running ──────────────────────────────────────────────────────────────

function Runner.load(name)
    name = name or "smoke"

    local ok, result = pcall(require, "tests." .. name)
    if not ok then
        print("ERROR  could not load tests/" .. name .. ".lua: " .. tostring(result))
        love.event.quit(1)
        return
    end

    steps = result
    print(("==== tests/%s.lua: %d steps ===="):format(name, #steps))
end

function Runner.update()
    frame = frame + 1

    local index = frame - SETTLE_FRAMES
    if index < 1 then
        return
    end

    if index > #steps then
        Runner.finish()
        return
    end

    local ok, err = pcall(steps[index])
    if not ok then
        failures = failures + 1
        print(("ERROR  step %d: %s"):format(index, tostring(err)))
    end
end

function Runner.finish()
    print(("\n==== %d passed, %d failed ===="):format(passes, failures))
    print("screenshots: " .. love.filesystem.getSaveDirectory())

    -- A run's board is scratch, and any step that leaves an edit on it would
    -- otherwise be met by the unsaved-changes prompt: that blocks the quit and waits
    -- for a button press nobody is there to make, so the run hangs on the last frame
    -- instead of exiting with its result. Declaring it clean is the honest version of
    -- "yes, discard it" -- there's nothing here anyone wanted kept.
    require("application.BoardFile"):markClean()
    -- Non-zero on failure, so this can gate a CI job without parsing the output.
    love.event.quit(failures > 0 and 1 or 0)
end

return Runner
