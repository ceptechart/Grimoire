local Theme = require "application.Style.Theme"
local Clip = require "application.Style.Clip"
local PanelElement = require "application.Canvas.elements.PanelElement"
local ContentScroll = require "application.Canvas.ContentScroll"
local Markdown = require "application.Text.Markdown"
local MarkdownLayout = require "application.Text.MarkdownLayout"

-- A panel whose body is markdown: edited as source, drawn as formatted text.
--
-- Deliberately a second type alongside TextElement rather than a replacement for
-- it. A note is a note -- you type into it and what you typed is what you see --
-- and a great deal of ordinary board text contains an asterisk or an underscore
-- that was never meant as markup. This type opts in to the other reading, and
-- shares everything else: PanelElement's frame, header-as-drag-handle and editable
-- title come through the same delegation TextElement and ImageElement use.
--
-- **The board file stores the source, never the rendering.** That's the whole
-- point of the format being markdown: the prop is a plain string a human can read
-- in the JSON and edit outside the app, and the layout below is derived from it the
-- same way a container's child geometry is derived from its tree rather than saved.
--
-- Editing is raw source in the monospace font -- there's no rich-text editing here,
-- and there deliberately isn't: the buffer stays the exact text the file holds, so
-- an edit can't lose syntax the renderer doesn't happen to understand.
local MarkdownElement = { name = "markdown" }

local BODY_PADDING = 10
local DEFAULT_WIDTH = 380
local DEFAULT_HEIGHT = 300
local MIN_WIDTH = 180
local MIN_HEIGHT = PanelElement.getHeaderHeight() + 60

local EMPTY_HINT = "Double-click to write markdown"

local STYLE = PanelElement.newStyle("elementSurface", "elementHeader", "elementBorder", "res/img/tool/text_md.png")

function MarkdownElement.defaultSize()
    return DEFAULT_WIDTH, DEFAULT_HEIGHT
end

function MarkdownElement.defaultProps()
    return { title = "Markdown", body = "" }
end

function MarkdownElement.minSize()
    return MIN_WIDTH, MIN_HEIGHT
end

function MarkdownElement.bodyRect(element)
    local header = PanelElement.getHeaderHeight()
    return element.x + BODY_PADDING,
        element.y + header + BODY_PADDING,
        math.max(0, element.width - BODY_PADDING * 2),
        math.max(0, element.height - header - BODY_PADDING * 2)
end

-- ── The rendered layout ──────────────────────────────────────────────────
--
-- Parsing and laying out markdown is a great deal more work than measuring a
-- wrapped string, and the answer only changes when the source or the width does --
-- so unlike TextElement, which re-wraps its body every frame, this caches.
--
-- Keyed by element id and validated on both inputs, so a stale entry is impossible
-- rather than merely unlikely: an undo that restores an older body, or a paste that
-- gives an identical body a new id, both miss the check and rebuild. The cache is
-- dropped wholesale past a bound rather than swept, since an entry costs nothing to
-- rebuild and ids accumulate across a long session of pastes and undos.
local CACHE_LIMIT = 256

local cache = {}
local cached = 0

local function layoutFor(element, width)
    local source = element.props.body or ""
    local entry = cache[element.id]
    if entry and entry.source == source and entry.width == width then
        return entry.layout
    end

    if cached >= CACHE_LIMIT then
        cache, cached = {}, 0
    end

    local layout = MarkdownLayout.build(Markdown.parse(source), width)
    if not cache[element.id] then
        cached = cached + 1
    end
    cache[element.id] = { source = source, width = width, layout = layout }
    return layout
end

-- ── Element hooks ────────────────────────────────────────────────────────

-- The title field is PanelElement's, scoped to the header; the body field is this
-- type's own. Ordered so ElementRegistry:textFieldAt -- which returns the first
-- match -- renames on a header double-click and opens the source anywhere else.
function MarkdownElement.textFields(element)
    local fields = PanelElement.textFields(element)
    local x, y, width, height = MarkdownElement.bodyRect(element)

    table.insert(fields, {
        prop = "body",
        x = x, y = y, width = width, height = height,
        -- Monospace while editing even though the rendering isn't: it's source,
        -- and a table's pipes only line up in a fixed-width font.
        font = "code",
        color = "foreground",
        multiline = true,
        hit = {
            x = element.x,
            y = element.y + PanelElement.getHeaderHeight(),
            width = element.width,
            height = element.height - PanelElement.getHeaderHeight(),
        },
    })

    return fields
end

MarkdownElement.hitTestHandle = PanelElement.hitTestHandle

-- The body is the window and the rendered document is what's behind it. The layout
-- already knows its own height, so this is a cache hit in every frame that also
-- draws (see ElementRegistry:scrollView, and ContentScroll for what's done with it).
function MarkdownElement.scrollView(element)
    local x, y, width, height = MarkdownElement.bodyRect(element)
    if width <= 0 or (element.props.body or "") == "" then
        return nil
    end
    return x, y, width, height, layoutFor(element, width).height
end

-- A board file is JSON anything could have written, and the renderer below assumes
-- a string. Repair rather than refuse, the same rule ContainerElement's own
-- normalize follows: a body that came back as a number or a table costs the text,
-- not the board.
function MarkdownElement.normalizeProps(element)
    local body = element.props.body
    if body ~= nil and type(body) ~= "string" then
        element.props.body = type(body) == "number" and tostring(body) or ""
    end
end

function MarkdownElement.draw(element, context)
    PanelElement.drawFrame(element, context, STYLE)

    -- While the source is being edited the editor draws it instead -- rendering
    -- underneath it would show the formatted text through the raw text.
    if context.editingId == element.id and context.editingProp == "body" then
        return
    end

    local x, y, width, height = MarkdownElement.bodyRect(element)
    if width <= 0 or height <= 0 then
        return
    end

    local r, g, b, a = love.graphics.getColor()
    Clip.push(x, y, width, height)

    local source = element.props.body or ""
    if source == "" then
        local font = Theme:font("small")
        local previousFont = love.graphics.getFont()
        love.graphics.setFont(font)
        love.graphics.setColor(Theme:color("muted"):unpacked())
        love.graphics.printf(EMPTY_HINT, x, y + (height - font:getHeight()) / 2, width, "center")
        love.graphics.setFont(previousFont)
    else
        -- Which link (if any) the pointer is over is view state Board tracks and puts
        -- on the context, the same way the open editor's field is -- this type never
        -- reads the mouse itself, so the hover it draws is the one that survived the
        -- chrome, the modal and the gesture checks in Board:updateHoverCursor.
        local hovered = context.hoverId == element.id and context.hoverTarget or nil
        MarkdownLayout.draw(layoutFor(element, width), x, y - ContentScroll.offsetOf(element), hovered)
    end

    Clip.pop()
    love.graphics.setColor(r, g, b, a)

    -- Outside the clip and after the content, since it's drawn over it rather than
    -- in a gutter beside it (see ContentScroll).
    ContentScroll.draw(element, context)
end

-- ── Links ────────────────────────────────────────────────────────────────

-- Only what a board can honestly hand to the OS. A `.grimoire` file is content
-- people share, so a link in one is untrusted input: `file:` would turn a shared
-- board into a way to open arbitrary local paths, and a scheme nobody vetted is
-- worse. Everything else is left visible and inert rather than silently dropped.
local function isOpenable(url)
    return url:match("^https?://") ~= nil or url:match("^mailto:") ~= nil
end

-- The link under a world point, or nil. Shared by the hover affordance and the
-- double-click that follows one, so the link that lit up is by construction the link
-- that opens.
local function linkAt(element, x, y)
    local bodyX, bodyY, width, height = MarkdownElement.bodyRect(element)
    if width <= 0 or height <= 0 or (element.props.body or "") == "" then
        return nil
    end
    if x < bodyX or x > bodyX + width or y < bodyY or y > bodyY + height then
        return nil
    end

    -- Into the layout's own coordinates, which are the document's rather than the
    -- element's -- so how far it's scrolled has to come back out of the point, or a
    -- scrolled document would follow whichever link used to be under the pointer.
    return MarkdownLayout.linkAt(layoutFor(element, width),
        x - bodyX, y - bodyY + ContentScroll.offsetOf(element))
end

-- The pointer affordance for an idle hover: the link under the point, plus the
-- cursor to show over it. Board keeps the target and hands it back on the draw
-- context (see draw above); nothing about it is stored here, so a second markdown
-- element can't be left lit by a pointer that has moved on to this one.
function MarkdownElement.hover(element, x, y)
    local link = linkAt(element, x, y)
    if not link then
        return nil
    end
    return link.id, "link"
end

-- Double-clicking a link follows it; double-clicking anywhere else in the body
-- falls through (by returning false) to the source editor, which is why Board asks
-- this before it looks for a text field -- the body field's hit region covers every
-- link on the element, so a lookup that ran first would always win.
function MarkdownElement.handleDoubleClick(element, x, y)
    local link = linkAt(element, x, y)
    if not link then
        return false
    end

    local UI = require "application.UI.UI"
    if isOpenable(link.url) then
        love.system.openURL(link.url)
    else
        UI:showToast("warn", "Only http, https and mailto links can be opened", { timeout = 3 })
    end
    return true
end

return MarkdownElement
