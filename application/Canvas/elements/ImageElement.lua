local Theme = require "application.Style.Theme"
local Clip = require "application.Style.Clip"
local PanelElement = require "application.Canvas.elements.PanelElement"
local Path = require "lib.util.Path"

-- A panel whose body shows a picture instead of holding other elements. Derived from
-- PanelElement the same way ContainerElement is: the frame, the header-as-drag-handle
-- and the editable title are reused through drawFrame/hitTestHandle/textFields, and
-- what's added here is a second interaction (double-clicking the body picks a file)
-- and a second thing to draw (the image, or a placeholder for one that's missing or
-- hasn't been chosen yet).
--
-- **The path is stored relative to the board's own .grimoire file** (`lib.util.Path`
-- does the conversion both ways), not absolute -- an absolute path would break the
-- moment the project folder was cloned or moved, which is exactly the failure mode a
-- git-friendly save format exists to avoid (see CLAUDE.md's "Persistence"). That
-- means an image can't be picked before the board itself has a path to be relative
-- to: BoardFile:getPath() nil is met with a toast asking to save first, not a
-- half-working absolute fallback.
local ImageElement = { name = "image" }

local DEFAULT_WIDTH = 320
local DEFAULT_HEIGHT = 240
local MIN_WIDTH = 120
local MIN_HEIGHT = PanelElement.getHeaderHeight() + 60

local STYLE = PanelElement.newStyle("elementSurface", "elementHeader", "elementBorder", "res/img/tool/image.png")

-- name -> extension, the same shape BoardFile's own FILTERS use (see
-- love.window.showFileDialog's `filters` setting) -- one entry per extension rather
-- than a combined pattern, since that bare-extension shape is the one already proven
-- to work in this codebase.
local IMAGE_FILTERS = {
    ["PNG"]  = "png",
    ["JPG"]  = "jpg",
    ["JPEG"] = "jpeg",
    ["BMP"]  = "bmp",
    ["TGA"]  = "tga",
}

local EMPTY_HINT = "Double-click to add an image"
local UNSAVED_HINT = "Save the board before adding images"

function ImageElement.defaultSize()
    return DEFAULT_WIDTH, DEFAULT_HEIGHT
end

function ImageElement.defaultProps()
    -- path: nil until an image is picked; relative to the board file afterwards.
    return { title = "Image", path = nil }
end

function ImageElement.minSize()
    return MIN_WIDTH, MIN_HEIGHT
end

-- The title bar behaves exactly as a panel's; the body is a click target like any
-- other element's, with double-click on it handled below instead of through a text
-- field.
ImageElement.hitTestHandle = PanelElement.hitTestHandle
ImageElement.textFields = PanelElement.textFields

function ImageElement.contentRect(element)
    local header = PanelElement.getHeaderHeight()
    return element.x, element.y + header, element.width, element.height - header
end

local function withinContentRect(element, x, y)
    local cx, cy, cw, ch = ImageElement.contentRect(element)
    return x >= cx and x <= cx + cw and y >= cy and y <= cy + ch
end

-- ── Loading ──────────────────────────────────────────────────────────────
--
-- Keyed by resolved absolute path rather than by element: two elements pointing at
-- the same picture share one Image, and the same relative path in two different
-- boards (different directories) correctly loads two different files.
local cache = {}

-- love.graphics.newImage(filename) reads through love.filesystem, which is sandboxed
-- to the game source and save directories -- it can't see an arbitrary path anywhere
-- else on disk, same as love.filesystem couldn't be used for the board file itself
-- (see BoardFile's own reasoning for reading that with plain io.* instead). So the
-- bytes are read by hand here too, then handed to LOVE as FileData, which
-- love.graphics.newImage decodes exactly like it would a filename.
local function readFileBytes(path)
    local file, err = io.open(path, "rb")
    if not file then
        return nil, err or "could not be opened"
    end

    local bytes = file:read("*a")
    file:close()

    if not bytes then
        return nil, "could not be read"
    end
    return bytes
end

local function loadImage(absolutePath)
    local entry = cache[absolutePath]
    if entry then
        return entry
    end

    local bytes, readErr = readFileBytes(absolutePath)
    if not bytes then
        entry = { error = readErr }
    else
        local name = absolutePath:match("[^/\\]+$") or absolutePath
        local ok, imageOrError = pcall(function()
            return love.graphics.newImage(love.filesystem.newFileData(bytes, name))
        end)
        entry = ok and { image = imageOrError } or { error = tostring(imageOrError) }
    end

    cache[absolutePath] = entry
    return entry
end

-- Exposed so a test can drive the actual loading path (an absolute path outside the
-- LOVE sandbox, decoded from raw bytes) directly, without going through a whole
-- double-click/file-dialog/draw cycle to observe whether it worked.
ImageElement.load = loadImage

-- application.BoardFile is required lazily, from inside the functions that need it,
-- the same way UI.lua and BoardFile.lua break this exact cycle elsewhere: BoardFile
-- requires Document, which requires ElementRegistry, which this file registers
-- itself into (via Board.lua) -- requiring it at the top of this module would ask
-- for BoardFile before it exists yet the first time the require chain reaches here.
local function boardDirectory()
    local BoardFile = require "application.BoardFile"
    local path = BoardFile:getPath()
    return path and Path.dirname(path)
end

-- ── Drawing ──────────────────────────────────────────────────────────────

local function drawHint(text, x, y, width, height, colorToken)
    local font = Theme:font("small")
    local previousFont = love.graphics.getFont()
    love.graphics.setFont(font)
    love.graphics.setColor(Theme:color(colorToken):unpacked())
    love.graphics.printf(text, x, y + (height - font:getHeight()) / 2, width, "center")
    love.graphics.setFont(previousFont)
end

function ImageElement.draw(element, context)
    PanelElement.drawFrame(element, context, STYLE)

    local x, y, width, height = ImageElement.contentRect(element)
    local r, g, b, a = love.graphics.getColor()
    Clip.push(x, y, width, height)

    if not element.props.path then
        drawHint(EMPTY_HINT, x, y, width, height, "muted")
    else
        local directory = boardDirectory()
        if not directory then
            drawHint(UNSAVED_HINT, x, y, width, height, "toastWarn")
        else
            local entry = loadImage(Path.join(directory, element.props.path))
            if entry.image then
                local iw, ih = entry.image:getDimensions()
                local scale = math.min(width / iw, height / ih)
                local drawWidth, drawHeight = iw * scale, ih * scale
                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.draw(entry.image,
                    x + (width - drawWidth) / 2, y + (height - drawHeight) / 2, 0, scale, scale)
            else
                drawHint(("Could not load %s: %s"):format(element.props.path, entry.error),
                    x, y, width, height, "toastError")
            end
        end
    end

    Clip.pop()
    love.graphics.setColor(r, g, b, a)
end

-- ── Picking a file ───────────────────────────────────────────────────────

-- love.window.showFileDialog is single-flight per call site the same way
-- BoardFile:showDialog guards its own -- opening a second picker on top of one
-- already open would leave the first's callback pointed at a dialog that's since
-- been superseded.
local dialogOpen = false

function ImageElement.handleDoubleClick(element, x, y, setProp)
    if not withinContentRect(element, x, y) then
        return false
    end

    if dialogOpen then
        return true
    end

    local directory = boardDirectory()
    if not directory then
        local UI = require "application.UI.UI"
        UI:showToast("warn", UNSAVED_HINT, { timeout = 3 })
        return true
    end

    dialogOpen = true
    love.window.showFileDialog("openfile", function(files, filtername, err)
        dialogOpen = false
        local picked = not err and files and files[1]
        if not picked then
            return
        end
        setProp({ path = Path.relative(directory, picked) })
    end, { filters = IMAGE_FILTERS, attachtowindow = true })

    return true
end

return ImageElement
