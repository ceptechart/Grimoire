local Theme = require "application.Style.Theme"
local utf8 = require "utf8"

-- Turns the block tree application/Text/Markdown.lua produces into positioned draw
-- items at a given width, and draws them.
--
-- The other half of the markdown split: Markdown.lua decides what the text says,
-- this decides how tall it is. Everything that needs a font or a theme token lives
-- here, and nothing here parses anything -- the same seam ContainerLayout draws
-- between the tree math and the element that draws the tree.
--
-- Build once, draw many: a layout is a flat list of two primitives -- positioned
-- text runs and filled rects -- in local coordinates with the content's top-left at
-- (0, 0). That's what makes it cacheable per (source, width) rather than recomputed
-- per frame (see MarkdownElement), and what makes link hit testing a lookup rather
-- than a second pass over the parse tree.
--
--   item   { kind = "text", x, y, text, font, color, link? }
--          { kind = "rect", x, y, width, height, color, link? }
--   link   { x, y, width, height, url, id }
--
-- Rules, borders and underlines are filled rects one world unit thick rather than
-- lines: at zoom 1 that's the one pixel they want, and it keeps the draw loop to
-- two cases. They scale with the canvas like everything else on the board does.
local MarkdownLayout = {}

-- Nothing here is a theme metric because none of it is chrome: these are the
-- proportions of a document, and they're expressed against the body font's size the
-- way a stylesheet's ems would be.
local BODY_SIZE = "small"
local HEADING_SIZE = { "xxlarge", "xlarge", "large", "medium", "small", "small" }

local PARAGRAPH_SPACING = 8
local HEADING_SPACE_ABOVE = 14
local HEADING_SPACE_BELOW = 6
local HEADING_RULE_LEVELS = 2 -- h1/h2 get an underline, as they do on the web
local LIST_INDENT = 24
local LIST_ITEM_SPACING = 2
local LIST_MARKER_GAP = 6
local QUOTE_INDENT = 16
local QUOTE_BAR_WIDTH = 3
local CODE_PADDING = 8
local RULE_SPACING = 8
local CELL_PADDING_X = 8
local CELL_PADDING_Y = 4
local HAIRLINE = 1
-- How far the fill behind inline code or highlighted text extends past the glyphs,
-- so the run reads as a marked stretch rather than as text with a tight box drawn
-- round it. Small enough that consecutive runs on one line don't touch.
local INLINE_FILL_PAD = 2

-- ── Fonts ────────────────────────────────────────────────────────────────

-- The theme's font tokens are named `<size>[_bold][_italic]`, so a style is a token
-- built by concatenation rather than a table of every combination. A new size in
-- the theme is usable here the moment its four variants exist.
local function fontFor(size, bold, italic, code)
    if code then
        return Theme:font("code")
    end
    if bold and italic then
        return Theme:font(size .. "_bold_italic")
    elseif bold then
        return Theme:font(size .. "_bold")
    elseif italic then
        return Theme:font(size .. "_italic")
    end
    return Theme:font(size)
end

-- One step down the theme's size scale, which is what a sub/superscript is drawn
-- at. A table rather than arithmetic because the sizes are named tokens, not
-- numbers -- and "tiny" is its own floor, since there's nothing below it.
local SMALLER = {
    xxlarge = "xlarge",
    xlarge  = "large",
    large   = "medium",
    medium  = "small",
    small   = "tiny",
    tiny    = "tiny",
}

-- Hovering a link recolors it, and the swap happens at draw time rather than in the
-- layout: a layout is cached per (source, width) and the pointer moves every frame,
-- so which link is lit can't be baked into one. Hence the pair as constants -- draw
-- substitutes the second for the first on the hovered link's items, and only on
-- those, so a link whose text is inline code keeps the code colors it drew in.
local LINK_COLOR = "markdownLink"
local LINK_HOVER_COLOR = "markdownLinkHover"

local function colorFor(span, default)
    if span.code then
        return "markdownCodeText"
    elseif span.link then
        return LINK_COLOR
    elseif span.highlight then
        return "markdownHighlightText"
    end
    return default
end

-- ── Inline wrapping ──────────────────────────────────────────────────────

-- Runs of consecutive spaces or consecutive non-spaces. Byte-indexed, which is safe
-- for the same reason TextEditSession's own tokenizer is: a UTF-8 continuation byte
-- is never 0x20, so a space boundary always falls on a character boundary.
local function tokenize(text)
    local tokens = {}
    local length, index = #text, 1
    while index <= length do
        local space = text:sub(index, index) == " "
        local stop = index
        while stop <= length and (text:sub(stop, stop) == " ") == space do
            stop = stop + 1
        end
        tokens[#tokens + 1] = text:sub(index, stop - 1)
        index = stop
    end
    return tokens
end

local function newLine()
    return { pieces = {}, width = 0, height = 0 }
end

-- Appends to the previous piece when it's drawn the same way, so a paragraph of
-- plain text is one draw call rather than one per word. Styles are built once per
-- span, so identity is the right comparison: two pieces share a style table
-- exactly when they came out of the same span.
local function pushPiece(line, text, style)
    local font = style.font
    local last = line.pieces[#line.pieces]

    if last and last.style == style then
        line.width = line.width - last.width
        last.text = last.text .. text
        last.width = font:getWidth(last.text)
        line.width = line.width + last.width
    else
        local width = font:getWidth(text)
        line.pieces[#line.pieces + 1] = {
            text = text, style = style, x = line.width, width = width,
        }
        line.width = line.width + width
    end

    -- A sub/superscript is deliberately excluded from the line's height: it's
    -- drawn inside the space its own line already occupies (see emitLines), and
    -- letting a smaller font raise the line height would do nothing but add a gap.
    line.height = math.max(line.height, font:getHeight())
end

-- Greedy word wrap across a run of spans, so a line can hold several styles and
-- break between any two words of them. A span wider than the field is broken inside
-- the word rather than allowed to run past the edge forever -- the same rule
-- TextEditSession applies to a long word in an open field.
local function layoutInlines(spans, size, defaultColor, width)
    local lines = { newLine() }

    local function current()
        return lines[#lines]
    end

    local function breakLine()
        lines[#lines + 1] = newLine()
        return lines[#lines]
    end

    for _, span in ipairs(spans) do
        if span.br then
            breakLine()
        else
            -- A sub/superscript drops a step down the size scale and gives up
            -- bottom alignment: raising a superscript is the whole of what makes
            -- it one, and a subscript is already where it belongs on the baseline
            -- every other piece sits on.
            local spanSize = size
            if span.sub or span.sup then
                spanSize = SMALLER[size] or size
            end

            local style = {
                font = fontFor(spanSize, span.bold, span.italic, span.code),
                color = colorFor(span, defaultColor),
                link = span.link,
                strike = span.strike,
                code = span.code,
                highlight = span.highlight,
                raised = span.sup or nil,
            }

            for _, token in ipairs(tokenize(span.text)) do
                local line = current()
                local tokenWidth = style.font:getWidth(token)

                if token:sub(1, 1) == " " then
                    -- A space at the start of a line is the one a wrap consumed.
                    if #line.pieces > 0 then
                        pushPiece(line, token, style)
                    end
                elseif tokenWidth > width and line.width == 0 then
                    for _, codepoint in utf8.codes(token) do
                        local char = utf8.char(codepoint)
                        local charWidth = style.font:getWidth(char)
                        if line.width > 0 and line.width + charWidth > width then
                            line = breakLine()
                        end
                        pushPiece(line, char, style)
                    end
                else
                    if line.width > 0 and line.width + tokenWidth > width then
                        line = breakLine()
                    end
                    pushPiece(line, token, style)
                end
            end
        end
    end

    -- An empty line still occupies a row -- a blank line inside a paragraph's hard
    -- breaks, or an empty table cell.
    local fallback = fontFor(size, false, false, false):getHeight()
    for _, line in ipairs(lines) do
        if line.height == 0 then
            line.height = fallback
        end
    end

    return lines
end

local function measureInlines(spans, size)
    local width = 0
    for _, span in ipairs(spans) do
        if not span.br then
            local spanSize = (span.sub or span.sup) and (SMALLER[size] or size) or size
            width = width
                + fontFor(spanSize, span.bold, span.italic, span.code):getWidth(span.text)
        end
    end
    return width
end

local function boldened(spans)
    local out = {}
    for index, span in ipairs(spans) do
        local copy = {}
        for key, value in pairs(span) do
            copy[key] = value
        end
        copy.bold = true
        out[index] = copy
    end
    return out
end

-- ── Emitting ─────────────────────────────────────────────────────────────

local function addText(ctx, x, y, text, font, color)
    ctx.items[#ctx.items + 1] = { kind = "text", x = x, y = y, text = text, font = font, color = color }
end

local function addRect(ctx, x, y, width, height, color)
    ctx.items[#ctx.items + 1] =
        { kind = "rect", x = x, y = y, width = width, height = height, color = color }
end

-- Draws one wrapped run of lines and returns the y below it. Pieces sit on a common
-- bottom edge rather than a common top, so a line mixing sizes -- inline code in a
-- heading, say -- reads as one line of text rather than two staggered ones.
local function emitLines(ctx, lines, x, y, align, boxWidth)
    for _, line in ipairs(lines) do
        local offset = 0
        if align == "center" then
            offset = math.max(0, (boxWidth - line.width) / 2)
        elseif align == "right" then
            offset = math.max(0, boxWidth - line.width)
        end

        for _, piece in ipairs(line.pieces) do
            local style = piece.style
            local pieceX = x + offset + piece.x
            local height = style.font:getHeight()
            local firstItem = #ctx.items + 1
            -- Pieces bottom-align on a shared baseline; a superscript top-aligns
            -- instead, which is exactly what raises it. Nothing else needs an
            -- offset, and no magic fraction of the line height is involved.
            local pieceY = style.raised and y or (y + line.height - height)

            -- Backgrounds go in before the text so the flat item list draws them
            -- behind it -- the list is painted in order, there's no z within it.
            if style.code or style.highlight then
                addRect(ctx, pieceX - INLINE_FILL_PAD, pieceY - INLINE_FILL_PAD,
                    piece.width + INLINE_FILL_PAD * 2, height + INLINE_FILL_PAD * 2,
                    style.code and "markdownCodeSurface" or "markdownHighlight")
            end

            addText(ctx, pieceX, pieceY, piece.text, style.font, style.color)

            if style.strike then
                addRect(ctx, pieceX, pieceY + height * 0.55, piece.width, HAIRLINE, style.color)
            end
            if style.link then
                addRect(ctx, pieceX, pieceY + height - HAIRLINE, piece.width, HAIRLINE, style.color)

                -- One id per link, not per piece: a link that wrapped across two
                -- lines is two pieces and two hit rects, and hovering either has to
                -- light both. Pieces from one link share their style table -- it's
                -- built once per span (see layoutInlines) -- so identity is what
                -- makes them the same link, and two links to the same url stay
                -- separate the way a reader would expect.
                local id = ctx.linkIds[style]
                if not id then
                    id = ctx.linkCount + 1
                    ctx.linkCount, ctx.linkIds[style] = id, id
                end

                ctx.links[#ctx.links + 1] = {
                    x = pieceX, y = pieceY, width = piece.width, height = height,
                    url = style.link, id = id,
                }
                for index = firstItem, #ctx.items do
                    ctx.items[index].link = id
                end
            end
        end

        y = y + line.height
    end

    return y
end

-- ── Blocks ───────────────────────────────────────────────────────────────

local layoutBlocks

local function layoutCode(ctx, block, x, y, width)
    local font = Theme:font("code")
    local lineHeight = font:getHeight()
    local count = math.max(#block.lines, 1)
    local height = count * lineHeight + CODE_PADDING * 2

    addRect(ctx, x, y, width, height, "markdownCodeSurface")
    -- Border as four thin rects: cheaper than a stroked rounded rect, and it keeps
    -- the draw loop to the two primitives every other item uses.
    addRect(ctx, x, y, width, HAIRLINE, "markdownCodeBorder")
    addRect(ctx, x, y + height - HAIRLINE, width, HAIRLINE, "markdownCodeBorder")
    addRect(ctx, x, y, HAIRLINE, height, "markdownCodeBorder")
    addRect(ctx, x + width - HAIRLINE, y, HAIRLINE, height, "markdownCodeBorder")

    for index, text in ipairs(block.lines) do
        -- Unwrapped on purpose: code lines mean their indentation, and wrapping
        -- them would misrepresent it. A long line runs under the element's clip.
        addText(ctx, x + CODE_PADDING, y + CODE_PADDING + (index - 1) * lineHeight,
            text, font, "markdownCodeText")
    end

    return y + height
end

local function layoutTable(ctx, block, x, y, width, color)
    local columns = #block.header
    if columns == 0 then
        return y
    end

    -- Columns take their share of the element's width in proportion to the width
    -- their content would want, then fill it exactly: a narrow table stretches to
    -- the element, a wide one shrinks and its cells wrap.
    local natural, total = {}, 0
    for column = 1, columns do
        local widest = measureInlines(block.header[column], BODY_SIZE)
        for _, row in ipairs(block.rows) do
            widest = math.max(widest, measureInlines(row[column] or {}, BODY_SIZE))
        end
        natural[column] = widest + CELL_PADDING_X * 2
        total = total + natural[column]
    end
    total = math.max(total, 1)

    local columnWidth, used = {}, 0
    for column = 1, columns - 1 do
        columnWidth[column] = math.floor(natural[column] * width / total)
        used = used + columnWidth[column]
    end
    columnWidth[columns] = width - used

    -- Row boundaries, kept so the separators can be drawn after the text rather
    -- than needing a second measuring pass.
    local boundaries = { y }

    local function emitRow(cells, top, header)
        local cellLines, height = {}, 0
        for column = 1, columns do
            local spans = cells[column] or {}
            if header then
                spans = boldened(spans)
            end
            local inner = math.max(columnWidth[column] - CELL_PADDING_X * 2, 1)
            local lines = layoutInlines(spans, BODY_SIZE, color, inner)
            cellLines[column] = lines
            local cellHeight = 0
            for _, line in ipairs(lines) do
                cellHeight = cellHeight + line.height
            end
            height = math.max(height, cellHeight)
        end
        height = height + CELL_PADDING_Y * 2

        if header then
            addRect(ctx, x, top, width, height, "markdownTableHeader")
        end

        local cellX = x
        for column = 1, columns do
            emitLines(ctx, cellLines[column], cellX + CELL_PADDING_X, top + CELL_PADDING_Y,
                block.align[column] or "left", columnWidth[column] - CELL_PADDING_X * 2)
            cellX = cellX + columnWidth[column]
        end

        return top + height
    end

    y = emitRow(block.header, y, true)
    boundaries[#boundaries + 1] = y
    for _, row in ipairs(block.rows) do
        y = emitRow(row, y, false)
        boundaries[#boundaries + 1] = y
    end

    local top, bottom = boundaries[1], boundaries[#boundaries]
    for _, edge in ipairs(boundaries) do
        addRect(ctx, x, edge, width, HAIRLINE, "markdownTableBorder")
    end
    local edgeX = x
    for column = 1, columns do
        addRect(ctx, edgeX, top, HAIRLINE, bottom - top, "markdownTableBorder")
        edgeX = edgeX + columnWidth[column]
    end
    addRect(ctx, x + width - HAIRLINE, top, HAIRLINE, bottom - top, "markdownTableBorder")

    return y
end

local function layoutList(ctx, block, x, y, width, color)
    local font = Theme:font(BODY_SIZE)
    local markerHeight = font:getHeight()

    for index, item in ipairs(block.items) do
        local contentX = x + LIST_INDENT

        if item.checked ~= nil then
            -- A task box is drawn rather than typed: the body font has no reliable
            -- ballot-box glyph, and two rects always render.
            local side = markerHeight * 0.62
            local boxX = contentX - LIST_MARKER_GAP - side
            local boxY = y + (markerHeight - side) / 2
            addRect(ctx, boxX, boxY, side, HAIRLINE, "markdownBullet")
            addRect(ctx, boxX, boxY + side - HAIRLINE, side, HAIRLINE, "markdownBullet")
            addRect(ctx, boxX, boxY, HAIRLINE, side, "markdownBullet")
            addRect(ctx, boxX + side - HAIRLINE, boxY, HAIRLINE, side, "markdownBullet")
            if item.checked then
                addRect(ctx, boxX + side * 0.25, boxY + side * 0.25,
                    side * 0.5, side * 0.5, "markdownLink")
            end
        else
            -- U+2022 by its bytes rather than as a literal, so this file's encoding
            -- can never be what decides whether the bullet renders.
            local marker = block.ordered and ((block.start + index - 1) .. ".") or "\226\128\162"
            -- Right-aligned into the indent, so a two-digit number keeps its
            -- content column rather than pushing the text across.
            addText(ctx, contentX - LIST_MARKER_GAP - font:getWidth(marker), y,
                marker, font, "markdownBullet")
        end

        local itemY, trailing =
            layoutBlocks(ctx, item.blocks, contentX, y, width - LIST_INDENT, color)
        -- A list stays tight: the paragraph spacing inside the item is traded for
        -- the (much smaller) gap between items.
        y = itemY - trailing + (index < #block.items and LIST_ITEM_SPACING or 0)
    end

    return y
end

-- Lays a run of blocks out at (x, y) within `width`, returning the y below them and
-- how much of that was trailing spacing -- which is what lets a caller that wants a
-- tight fit (a list item, a blockquote's bar) take it back off.
layoutBlocks = function(ctx, blocks, x, y, width, color)
    local trailing = 0

    for index, block in ipairs(blocks) do
        if block.kind == "heading" then
            if index > 1 then
                y = y + HEADING_SPACE_ABOVE
            end
            local size = HEADING_SIZE[block.level] or BODY_SIZE
            y = emitLines(ctx, layoutInlines(boldened(block.inlines), size, "markdownHeading", width),
                x, y, nil, width)
            y = y + HEADING_SPACE_BELOW
            if block.level <= HEADING_RULE_LEVELS then
                addRect(ctx, x, y, width, HAIRLINE, "markdownRule")
                y = y + HEADING_SPACE_BELOW
            end
            trailing = 0

        elseif block.kind == "paragraph" then
            y = emitLines(ctx, layoutInlines(block.inlines, BODY_SIZE, color, width), x, y, nil, width)
            y = y + PARAGRAPH_SPACING
            trailing = PARAGRAPH_SPACING

        elseif block.kind == "rule" then
            y = y + RULE_SPACING
            addRect(ctx, x, y, width, HAIRLINE, "markdownRule")
            y = y + RULE_SPACING + PARAGRAPH_SPACING
            trailing = PARAGRAPH_SPACING

        elseif block.kind == "code" then
            y = layoutCode(ctx, block, x, y, width) + PARAGRAPH_SPACING
            trailing = PARAGRAPH_SPACING

        elseif block.kind == "quote" then
            local top = y
            local inner, innerTrailing = layoutBlocks(ctx, block.blocks,
                x + QUOTE_INDENT, y, width - QUOTE_INDENT, "markdownQuoteText")
            -- The bar spans the quoted content and nothing else, which is why the
            -- inner run's own trailing spacing comes off first.
            addRect(ctx, x, top, QUOTE_BAR_WIDTH, math.max(inner - innerTrailing - top, 1),
                "markdownQuoteBar")
            y = inner - innerTrailing + PARAGRAPH_SPACING
            trailing = PARAGRAPH_SPACING

        elseif block.kind == "list" then
            y = layoutList(ctx, block, x, y, width, color) + PARAGRAPH_SPACING
            trailing = PARAGRAPH_SPACING

        elseif block.kind == "table" then
            y = layoutTable(ctx, block, x, y, width, color) + PARAGRAPH_SPACING
            trailing = PARAGRAPH_SPACING
        end
    end

    return y, trailing
end

-- ── Public ───────────────────────────────────────────────────────────────

function MarkdownLayout.build(blocks, width)
    local ctx = { items = {}, links = {}, linkIds = {}, linkCount = 0 }
    width = math.max(width, 1)

    local height, trailing = layoutBlocks(ctx, blocks, 0, 0, width, "markdownText")

    return {
        items = ctx.items,
        links = ctx.links,
        width = width,
        height = math.max(height - trailing, 0),
    }
end

-- `hoveredLink` is a link id (from linkAt) or nil: its text and underline are drawn
-- in the hover color instead, and nothing else about the layout changes.
function MarkdownLayout.draw(layout, x, y, hoveredLink)
    local previousFont = love.graphics.getFont()
    local r, g, b, a = love.graphics.getColor()

    for _, item in ipairs(layout.items) do
        local color = item.color
        if hoveredLink and item.link == hoveredLink and color == LINK_COLOR then
            color = LINK_HOVER_COLOR
        end
        love.graphics.setColor(Theme:color(color):unpacked())
        if item.kind == "text" then
            love.graphics.setFont(item.font)
            love.graphics.print(item.text, x + item.x, y + item.y)
        else
            love.graphics.rectangle("fill", x + item.x, y + item.y, item.width, item.height)
        end
    end

    love.graphics.setFont(previousFont)
    love.graphics.setColor(r, g, b, a)
end

-- The link under a point in the layout's own coordinates, or nil. Front to back is
-- meaningless here -- links never overlap -- so the first hit wins.
function MarkdownLayout.linkAt(layout, x, y)
    for _, link in ipairs(layout.links) do
        if x >= link.x and x <= link.x + link.width
            and y >= link.y and y <= link.y + link.height then
            return link
        end
    end
    return nil
end

return MarkdownLayout
