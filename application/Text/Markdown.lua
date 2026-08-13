-- Markdown source -> a block tree. Pure data in, pure data out: no love calls and
-- no requires, so it's drivable from a test without a graphics context and can't
-- drag a dependency cycle in behind it (the same reasoning Tools.lua and
-- ContainerLayout.lua are written under).
--
-- The split is deliberate. This module decides *what the text says*; measuring and
-- drawing it is application/Text/MarkdownLayout.lua's job, because that needs fonts
-- and a width and this doesn't. Nothing here knows how tall a heading is.
--
-- Coverage is the basic + extended syntax from markdownguide.org that a board
-- element can usefully show:
--
--   blocks   ATX headings, paragraphs, fenced code, blockquotes (nesting, and
--            holding any other block), ordered/unordered/task lists (nesting, and
--            holding any other block), tables with per-column alignment,
--            thematic breaks
--   inline   **bold**, *italic*, ***both***, ~~strikethrough~~, ==highlight==,
--            ~subscript~, ^superscript^, `code`, [links](url), <autolinks>,
--            bare URLs, and backslash escapes
--
-- Two rules here are deliberately *not* CommonMark, because this is a board
-- element rather than a document renderer and the surprise costs more than the
-- fidelity:
--
--   * **A line break in the source is a line break on the board.** Standard
--     markdown collapses a single newline into a space and needs two trailing
--     spaces to mean it; invisible trailing whitespace is a bad thing to require
--     of someone typing into a panel. Both older spellings (two spaces, a trailing
--     backslash) still parse -- they just no longer make any difference.
--   * **A heading doesn't need the space after its hashes**: `#Heading` is one.
--     The cost is that a line starting with `#` can't be prose about a `#`
--     character, which a board note is much less likely to want than a heading
--     typed quickly.
--
-- Deliberately not handled, because each is a real chunk of specification for very
-- little on a board: setext headings, reference-style links, indented (non-fenced)
-- code blocks, raw HTML, and footnotes. Unrecognized syntax falls through as
-- literal text rather than being dropped -- the same principle as
-- UnknownElement's, one level down.
--
--   block   { kind = "heading",   level = 1..6, inlines = {span} }
--           { kind = "paragraph", inlines = {span} }
--           { kind = "code",      lang = string?, lines = {string} }
--           { kind = "quote",     blocks = {block} }
--           { kind = "list",      ordered = bool, start = int, items = {item} }
--           { kind = "table",     align = {string}, header = {inlines}, rows = {{inlines}} }
--           { kind = "rule" }
--   item    { blocks = {block}, checked = bool? }   -- checked only for task items
--   span    { text = string, bold, italic, strike, highlight, sub, sup, code,
--             link = url? }
--           { br = true }                           -- a line break
local Markdown = {}

-- One tab is four columns. Normalizing here means every indent test below is a
-- plain space count rather than an expand-tabs-as-you-go measurement.
local TAB_WIDTH = 4

-- ── Line helpers ─────────────────────────────────────────────────────────

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function splitLines(source)
    local lines = {}
    for line in (source .. "\n"):gmatch("(.-)\r?\n") do
        lines[#lines + 1] = line:gsub("\t", (" "):rep(TAB_WIDTH))
    end
    return lines
end

local function isBlank(line)
    return line:match("^%s*$") ~= nil
end

local function indentOf(line)
    return #(line:match("^ *"))
end

-- Removes up to `columns` leading spaces. Fewer is fine -- a continuation line can
-- be under-indented and still belong to the block that claimed it.
local function dedent(line, columns)
    local indent = math.min(indentOf(line), columns)
    return line:sub(indent + 1)
end

-- ── Block openers ────────────────────────────────────────────────────────
--
-- Each returns the pieces of whatever it matched, or nil. They're also used as
-- lookahead by the paragraph collector, which has to stop at the first line that
-- would open something else.

local function matchRule(line)
    if indentOf(line) > 3 then
        return false
    end
    local squashed = line:gsub("%s", "")
    if #squashed < 3 then
        return false
    end
    local char = squashed:sub(1, 1)
    if char ~= "-" and char ~= "*" and char ~= "_" then
        return false
    end
    return squashed == char:rep(#squashed)
end

-- The space after the hashes is optional (see the header): `#Heading` is a heading,
-- not a paragraph about a hash. One pattern covers both spellings, since `%s*` is
-- happy with no space at all.
local function matchHeading(line)
    if indentOf(line) > 3 then
        return nil
    end
    local hashes, rest = line:match("^ *(#+)%s*(.*)$")
    if not hashes or #hashes > 6 then
        return nil
    end
    -- A closing run of #s is decoration, not content.
    return #hashes, (trim(rest):gsub("%s*#+$", ""))
end

-- Returns the fence's indent and its exact opening run, so the closing fence can be
-- required to be at least as long -- which is what lets a fenced block contain a
-- shorter run of the same character.
local function matchFence(line)
    if indentOf(line) > 3 then
        return nil
    end
    local indent, run, rest = line:match("^( *)(`+)(.*)$")
    -- An info string can't contain a backtick, or ``a`` inline would open a fence.
    if run and #run >= 3 and not rest:find("`", 1, true) then
        return #indent, run, trim(rest)
    end
    indent, run, rest = line:match("^( *)(~+)(.*)$")
    if run and #run >= 3 then
        return #indent, run, trim(rest)
    end
    return nil
end

local function matchQuote(line)
    if indentOf(line) > 3 then
        return nil
    end
    return line:match("^ *>%s?(.*)$")
end

-- indent, marker width, content, ordered, start number. The marker's width is what
-- the item's continuation lines are measured against, so `10. x` accepts less
-- indentation than `1. x` does -- which is what the source looks like in practice.
local function matchListItem(line)
    if matchRule(line) then
        return nil
    end

    local indent, bullet, rest = line:match("^( *)([%-%*%+])%s+(.*)$")
    if not indent then
        indent, bullet = line:match("^( *)([%-%*%+])%s*$")
        rest = ""
    end
    if indent then
        return #indent, #bullet + 1, rest, false, nil
    end

    local number, delimiter
    indent, number, delimiter, rest = line:match("^( *)(%d+)([%.%)])%s+(.*)$")
    if not indent then
        indent, number, delimiter = line:match("^( *)(%d+)([%.%)])%s*$")
        rest = ""
    end
    if indent then
        return #indent, #number + #delimiter + 1, rest, true, tonumber(number)
    end

    return nil
end

-- ── Tables ───────────────────────────────────────────────────────────────

-- Splits a row on unescaped pipes, dropping the optional leading/trailing ones.
local function splitRow(line)
    local body = trim(line):gsub("^|", ""):gsub("|$", "")
    local cells, current, index = {}, {}, 1

    while index <= #body do
        local char = body:sub(index, index)
        if char == "\\" then
            current[#current + 1] = body:sub(index, index + 1)
            index = index + 2
        elseif char == "|" then
            cells[#cells + 1] = trim(table.concat(current))
            current = {}
            index = index + 1
        else
            current[#current + 1] = char
            index = index + 1
        end
    end

    cells[#cells + 1] = trim(table.concat(current))
    return cells
end

-- `| --- | :--: | ---: |` -- the row that turns the line above it into a header and
-- carries each column's alignment.
local function matchDelimiterRow(line)
    if not line:find("|", 1, true) then
        return nil
    end

    local align = {}
    for _, cell in ipairs(splitRow(line)) do
        local left, dashes, right = cell:match("^(:?)(%-+)(:?)$")
        if not dashes then
            return nil
        end
        if left == ":" and right == ":" then
            align[#align + 1] = "center"
        elseif right == ":" then
            align[#align + 1] = "right"
        else
            align[#align + 1] = "left"
        end
    end

    return #align > 0 and align or nil
end

-- ── Inline ───────────────────────────────────────────────────────────────

local function isAlphanumeric(char)
    return char ~= "" and char:match("%w") ~= nil
end

local function runLengthAt(text, index, char)
    local stop = index
    while text:sub(stop, stop) == char do
        stop = stop + 1
    end
    return stop - index
end

local function withStyle(style, key, value)
    local copy = {}
    for name, existing in pairs(style) do
        copy[name] = existing
    end
    copy[key] = value
    return copy
end

local function emit(out, text, style)
    if text == "" then
        return
    end
    out[#out + 1] = {
        text = text,
        bold = style.bold,
        italic = style.italic,
        strike = style.strike,
        highlight = style.highlight,
        sub = style.sub,
        sup = style.sup,
        code = style.code,
        link = style.link,
    }
end

-- The closing delimiter for an emphasis run opened at `from - count`, or nil.
--
-- The run length has to match *exactly*, which is the one rule that keeps a
-- lightweight scanner honest about nesting: searching for a single `*` in
-- "*a **b** c*" would otherwise stop inside the inner bold. Requiring an exact run
-- makes the inner `**` invisible to the outer scan, so the outer emphasis closes
-- where it should and the inner one is found by the recursive pass over its
-- content. Code spans are skipped over for the same reason -- a `*` inside
-- backticks isn't a delimiter.
local function findEmphasisClose(text, from, char, count)
    local index = from
    while index <= #text do
        local current = text:sub(index, index)

        if current == "\\" then
            index = index + 2
        elseif current == "`" then
            local run = runLengthAt(text, index, "`")
            local closeAt = text:find(("`"):rep(run), index + run, true)
            index = closeAt and (closeAt + run) or (index + run)
        elseif current == char then
            local run = runLengthAt(text, index, char)
            local before = text:sub(index - 1, index - 1)
            local after = text:sub(index + run, index + run)
            -- A closer can't follow a space ("a * b" is a literal asterisk), and an
            -- underscore can't close inside a word, or snake_case_names would come
            -- out italicised.
            if run == count and before ~= "" and before ~= " "
                and (char ~= "_" or not isAlphanumeric(after)) then
                return index
            end
            index = index + run
        else
            index = index + 1
        end
    end
    return nil
end

-- The matching close bracket for the one at `from`, respecting nesting and escapes
-- -- what "[a [b] c](url)" needs and a plain find() gets wrong.
local function findMatching(text, from, open, close)
    local depth, index = 0, from
    while index <= #text do
        local char = text:sub(index, index)
        if char == "\\" then
            index = index + 2
        else
            if char == open then
                depth = depth + 1
            elseif char == close then
                depth = depth - 1
                if depth == 0 then
                    return index
                end
            end
            index = index + 1
        end
    end
    return nil
end

local function isUrlLike(text)
    return text:match("^%a[%w+.%-]*://") ~= nil
        or text:match("^mailto:") ~= nil
        or text:match("^[%w._%%+%-]+@[%w.%-]+%.%a%a+$") ~= nil
end

-- A URL written on its own, with no [label](...) around it. Returns the text as
-- typed and the address to open, which differ for a bare `www.` -- that gets an
-- https:// the author didn't write, since a scheme-less address isn't openable.
--
-- Trailing punctuation is the whole difficulty: "see https://x.com." ends a
-- sentence, and "(https://x.com)" is a URL in brackets -- neither final character
-- belongs to the address. A closing paren is kept only when the URL opened one
-- itself, which is what makes a wikipedia-style /wiki/Foo_(bar) link survive.
local function matchBareUrl(text, from)
    local candidate = text:match("^https?://[^%s<>]+", from)
    local scheme = candidate ~= nil
    if not candidate then
        candidate = text:match("^www%.[^%s<>]+", from)
    end
    if not candidate then
        return nil
    end

    while #candidate > 0 do
        local last = candidate:sub(-1)
        if last:match("[%.,;:!%?'\"]") then
            candidate = candidate:sub(1, -2)
        elseif last == ")" then
            local _, opens = candidate:gsub("%(", "")
            local _, closes = candidate:gsub("%)", "")
            if closes > opens then
                candidate = candidate:sub(1, -2)
            else
                break
            end
        else
            break
        end
    end

    -- Whatever survived the trim still has to be an address rather than a bare
    -- scheme or a lone "www.".
    if not (candidate:match("^https?://.") or candidate:match("^www%..")) then
        return nil
    end

    return candidate, scheme and candidate or ("https://" .. candidate)
end

local parseInline

-- Everything between the delimiters is re-parsed with the added style rather than
-- flattened, which is what makes **bold with *italic* inside** work at any depth
-- without the scanner tracking a stack of its own.
parseInline = function(text, style, out)
    out = out or {}
    style = style or {}

    local buffer = {}
    local index, length = 1, #text

    local function flush()
        if #buffer > 0 then
            emit(out, table.concat(buffer), style)
            buffer = {}
        end
    end

    local function literal(count)
        buffer[#buffer + 1] = text:sub(index, index + count - 1)
        index = index + count
    end

    while index <= length do
        local char = text:sub(index, index)

        if char == "\\" and text:sub(index + 1, index + 1):match("%p") then
            buffer[#buffer + 1] = text:sub(index + 1, index + 1)
            index = index + 2

        elseif char == "\n" then
            -- Only a hard break reaches here: soft wraps were already collapsed to
            -- spaces when the paragraph was assembled.
            flush()
            out[#out + 1] = { br = true }
            index = index + 1

        elseif char == "`" then
            local run = runLengthAt(text, index, "`")
            local closeAt = text:find(("`"):rep(run), index + run, true)
            if closeAt then
                flush()
                -- Code spans are literal all the way down: no escapes, no nesting.
                emit(out, text:sub(index + run, closeAt - 1), withStyle(style, "code", true))
                index = closeAt + run
            else
                literal(run)
            end

        elseif char == "*" or char == "_" then
            local run = runLengthAt(text, index, char)
            local before = text:sub(index - 1, index - 1)
            local after = text:sub(index + run, index + run)
            -- Mirror of the closer test in findEmphasisClose: an opener can't be
            -- followed by a space, and `_` can't open inside a word.
            local opens = run <= 3 and after ~= "" and after ~= " "
                and (char ~= "_" or not isAlphanumeric(before))
            local closeAt = opens and findEmphasisClose(text, index + run, char, run) or nil

            if closeAt then
                flush()
                local nested = style
                if run == 1 then
                    nested = withStyle(style, "italic", true)
                elseif run == 2 then
                    nested = withStyle(style, "bold", true)
                else
                    nested = withStyle(withStyle(style, "bold", true), "italic", true)
                end
                parseInline(text:sub(index + run, closeAt - 1), nested, out)
                index = closeAt + run
            else
                literal(run)
            end

        elseif char == "~" then
            -- Two tildes strike text out, one makes it a subscript -- H~2~O. The
            -- exact-run rule in findEmphasisClose is what keeps those two from
            -- reading each other's delimiters.
            local run = runLengthAt(text, index, "~")
            local closeAt = (run == 1 or run == 2)
                and findEmphasisClose(text, index + run, "~", run) or nil
            if closeAt then
                flush()
                local key = run == 2 and "strike" or "sub"
                parseInline(text:sub(index + run, closeAt - 1), withStyle(style, key, true), out)
                index = closeAt + run
            else
                literal(run)
            end

        elseif char == "^" then
            local run = runLengthAt(text, index, "^")
            local closeAt = run == 1 and findEmphasisClose(text, index + 1, "^", 1) or nil
            if closeAt then
                flush()
                parseInline(text:sub(index + 1, closeAt - 1), withStyle(style, "sup", true), out)
                index = closeAt + 1
            else
                literal(run)
            end

        elseif char == "=" and text:sub(index + 1, index + 1) == "=" then
            local closeAt = findEmphasisClose(text, index + 2, "=", 2)
            if closeAt then
                flush()
                parseInline(text:sub(index + 2, closeAt - 1),
                    withStyle(style, "highlight", true), out)
                index = closeAt + 2
            else
                literal(2)
            end

        elseif char == "[" or (char == "!" and text:sub(index + 1, index + 1) == "[") then
            -- An image is parsed as a link showing its alt text: a board can't
            -- fetch a remote picture, but the destination is still worth keeping
            -- reachable, and ImageElement is the element for actually showing one.
            local bracket = char == "!" and index + 1 or index
            local closeBracket = findMatching(text, bracket, "[", "]")
            local consumed = 0

            if closeBracket and text:sub(closeBracket + 1, closeBracket + 1) == "(" then
                local closeParen = findMatching(text, closeBracket + 1, "(", ")")
                if closeParen then
                    flush()
                    local destination = trim(text:sub(closeBracket + 2, closeParen - 1))
                    -- Drop an optional "title" and the <> a destination with spaces
                    -- in it is wrapped in.
                    destination = destination:match("^<(.-)>") or destination:match("^%S+") or ""
                    local label = text:sub(bracket + 1, closeBracket - 1)
                    -- An empty label shows the address rather than nothing at all,
                    -- which is what `[](url)` can only have meant.
                    if trim(label) == "" then
                        label = destination
                    end
                    parseInline(label, withStyle(style, "link", destination), out)
                    consumed = closeParen + 1 - index
                end
            end

            if consumed > 0 then
                index = index + consumed
            else
                literal(1)
            end

        elseif (char == "h" or char == "w") and not style.link
            and not isAlphanumeric(text:sub(index - 1, index - 1)) then
            -- A URL written on its own becomes a link, so pasting one in is
            -- enough. Skipped inside a [label](url) -- the label's own text
            -- already has a destination, and the inner one would silently win.
            local shown, url = matchBareUrl(text, index)
            if shown then
                flush()
                emit(out, shown, withStyle(style, "link", url))
                index = index + #shown
            else
                literal(1)
            end

        elseif char == "<" then
            local inner = text:match("^<([^<>%s]+)>", index)
            if inner and isUrlLike(inner) then
                flush()
                local url = inner
                if inner:find("@", 1, true) and not inner:match("^mailto:") then
                    url = "mailto:" .. inner
                end
                emit(out, inner, withStyle(style, "link", url))
                index = index + #inner + 2
            else
                literal(1)
            end

        else
            literal(1)
        end
    end

    flush()
    return out
end

Markdown.parseInline = parseInline

-- ── Blocks ───────────────────────────────────────────────────────────────

local parseBlocks

-- True if this line would open a block of its own, which is where a paragraph has
-- to stop. Kept as one predicate so the paragraph collector and the list-item
-- collector can't drift on what counts as an interruption.
local function opensBlock(line, next)
    return matchRule(line)
        or matchHeading(line) ~= nil
        or matchFence(line) ~= nil
        or matchQuote(line) ~= nil
        or matchListItem(line) ~= nil
        or (next ~= nil and line:find("|", 1, true) ~= nil and matchDelimiterRow(next) ~= nil)
end

-- Every line break in a paragraph is a line break in the output (see the header):
-- typing Enter is how someone says "new line", and requiring two invisible trailing
-- spaces to mean it is a rule that can only be learned by being surprised by it.
--
-- The standard hard-break spellings still parse -- a trailing backslash is stripped
-- so it doesn't show, and trailing spaces are trimmed like any other -- they just
-- no longer change anything, because the break was already going to happen.
local function joinParagraph(lines)
    local parts = {}
    for index, line in ipairs(lines) do
        parts[#parts + 1] = (trim(line):gsub("\\$", ""))
        if index < #lines then
            parts[#parts + 1] = "\n"
        end
    end
    return table.concat(parts)
end

parseBlocks = function(lines)
    local blocks = {}
    local index, count = 1, #lines

    while index <= count do
        local line = lines[index]

        -- Every opener is matched once, up front. A chain that re-ran its matcher
        -- inside the branch it guarded would do the work twice, and -- the reason
        -- that actually matters -- leaves two copies of the test that can drift.
        local fenceIndent, fence, fenceLang = matchFence(line)
        local headingLevel, headingText = matchHeading(line)
        local quoted = matchQuote(line)
        -- Only whether this opens a list, and of which kind, is needed here; the
        -- item loop below re-reads each item's own marker as it walks them.
        local listIndent, _, _, listOrdered, listStart = matchListItem(line)
        local tableAlign = (line:find("|", 1, true) and index < count)
            and matchDelimiterRow(lines[index + 1]) or nil

        if isBlank(line) then
            index = index + 1

        elseif matchRule(line) then
            blocks[#blocks + 1] = { kind = "rule" }
            index = index + 1

        elseif fence then
            local indent, lang = fenceIndent, fenceLang
            local body = {}
            index = index + 1
            while index <= count do
                -- A closing fence is the same character, at least as long, and
                -- carries no info string of its own.
                local _, closingRun, closingRest = matchFence(lines[index])
                if closingRun and closingRun:sub(1, 1) == fence:sub(1, 1)
                    and #closingRun >= #fence and closingRest == "" then
                    index = index + 1
                    break
                end
                body[#body + 1] = dedent(lines[index], indent)
                index = index + 1
            end
            blocks[#blocks + 1] = { kind = "code", lang = lang ~= "" and lang or nil, lines = body }

        elseif headingLevel then
            blocks[#blocks + 1] = {
                kind = "heading",
                level = headingLevel,
                inlines = parseInline(headingText),
            }
            index = index + 1

        elseif quoted then
            -- Consecutive quoted lines only: a lazy continuation (an unmarked line
            -- under a quoted one) is treated as a new paragraph, which is the
            -- reading that never swallows text the author didn't mark.
            local inner = {}
            while index <= count do
                local content = matchQuote(lines[index])
                if not content then
                    break
                end
                inner[#inner + 1] = content
                index = index + 1
            end
            blocks[#blocks + 1] = { kind = "quote", blocks = parseBlocks(inner) }

        elseif listIndent then
            local ordered = listOrdered
            local list = { kind = "list", ordered = ordered, start = listStart or 1, items = {} }

            while index <= count do
                local itemIndent, markerWidth, first, itemOrdered = matchListItem(lines[index])
                -- A different marker kind, or one indented back out past this
                -- list's own level, is a different list.
                if not itemIndent or itemOrdered ~= ordered then
                    break
                end

                local contentIndent = itemIndent + markerWidth
                local itemLines = { first }
                index = index + 1

                -- Continuation: anything indented into the item's content column,
                -- and blank lines held back until something indented follows them
                -- (so a trailing blank between items doesn't join them).
                local pendingBlanks = 0
                while index <= count do
                    local candidate = lines[index]
                    if isBlank(candidate) then
                        pendingBlanks = pendingBlanks + 1
                        index = index + 1
                    elseif indentOf(candidate) >= contentIndent then
                        for _ = 1, pendingBlanks do
                            itemLines[#itemLines + 1] = ""
                        end
                        pendingBlanks = 0
                        itemLines[#itemLines + 1] = dedent(candidate, contentIndent)
                        index = index + 1
                    elseif pendingBlanks == 0 and not opensBlock(candidate, lines[index + 1]) then
                        -- Lazy continuation of the item's own paragraph.
                        itemLines[#itemLines + 1] = trim(candidate)
                        index = index + 1
                    else
                        break
                    end
                end

                -- Task list marker, extended syntax: it belongs to the item rather
                -- than to the text, so it comes off before the content is parsed.
                local checked
                local mark, rest = itemLines[1]:match("^%[([ xX])%]%s+(.*)$")
                if mark then
                    checked = mark ~= " "
                    itemLines[1] = rest
                end

                list.items[#list.items + 1] = { blocks = parseBlocks(itemLines), checked = checked }

                -- Blank lines that ended an item are consumed only if the list
                -- continues past them; otherwise the outer loop sees them.
                if pendingBlanks > 0 and not (index <= count and matchListItem(lines[index])) then
                    break
                end
            end

            blocks[#blocks + 1] = list

        elseif tableAlign then
            local align = tableAlign
            local header = {}
            for _, cell in ipairs(splitRow(line)) do
                header[#header + 1] = parseInline(cell)
            end

            local rows = {}
            index = index + 2
            while index <= count and not isBlank(lines[index]) and lines[index]:find("|", 1, true) do
                local row = {}
                for _, cell in ipairs(splitRow(lines[index])) do
                    row[#row + 1] = parseInline(cell)
                end
                -- Ragged rows are padded/truncated to the header's width rather
                -- than refused: a table with a missing cell should still draw.
                for column = #row + 1, #header do
                    row[column] = {}
                end
                rows[#rows + 1] = row
                index = index + 1
            end

            blocks[#blocks + 1] = { kind = "table", align = align, header = header, rows = rows }

        else
            local paragraph = { line }
            index = index + 1
            while index <= count and not isBlank(lines[index])
                and not opensBlock(lines[index], lines[index + 1]) do
                paragraph[#paragraph + 1] = lines[index]
                index = index + 1
            end
            blocks[#blocks + 1] = { kind = "paragraph", inlines = parseInline(joinParagraph(paragraph)) }
        end
    end

    return blocks
end

function Markdown.parse(source)
    return parseBlocks(splitLines(source or ""))
end

return Markdown
