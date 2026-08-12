-- Minimal filesystem path helpers, string-only (no io/love calls) so this is safe to
-- require from anywhere and easy to reason about directly.
--
-- The one thing that needs it: ImageElement stores the path to its image relative to
-- the board's own .grimoire file, so the pair can be moved, cloned or shared as a
-- unit without the reference breaking. That needs turning an absolute path chosen
-- through a file dialog into one relative to the board's directory (on save/pick),
-- and back into an absolute one to load the image (on draw).
local Path = {}

-- Both slash styles turn up in showFileDialog results on Windows; a saved path always
-- uses "/", which is what a git-friendly file should have either way.
local function normalize(path)
    return (path:gsub("\\", "/"))
end

function Path.dirname(path)
    path = normalize(path)
    return path:match("^(.*)/[^/]*$") or ""
end

-- Splits a normalized path into its non-empty segments, resolving "." and ".." as it
-- goes rather than leaving them in for the caller to deal with.
local function segments(path)
    local parts = {}
    for segment in path:gmatch("[^/]+") do
        if segment == ".." and #parts > 0 and parts[#parts] ~= ".." then
            table.remove(parts)
        elseif segment ~= "." then
            table.insert(parts, segment)
        end
    end
    return parts
end

-- The path from `basePath` (a directory) to `targetPath`, both absolute, as a
-- relative path using "/" and "../" -- what gets stored in the board file so it
-- survives the whole project moving or being cloned somewhere else.
--
-- Segments are compared case-insensitively, since a Windows drive letter's case isn't
-- meaningful and shouldn't be the reason two paths fail to share a prefix.
function Path.relative(basePath, targetPath)
    local base = segments(normalize(basePath))
    local target = segments(normalize(targetPath))

    local common = 0
    while common < #base and common < #target
        and base[common + 1]:lower() == target[common + 1]:lower() do
        common = common + 1
    end

    local parts = {}
    for _ = common + 1, #base do
        table.insert(parts, "..")
    end
    for index = common + 1, #target do
        table.insert(parts, target[index])
    end

    if #parts == 0 then
        return "."
    end
    return table.concat(parts, "/")
end

-- Joins a base directory and a relative path, collapsing "." / ".." along the way.
-- A `relativePath` that's already absolute (a drive letter, or a leading slash) is
-- returned as-is -- normalize()'d for a hand-edited file that used backslashes -- so
-- a stray absolute path in a hand-edited board file still resolves rather than
-- getting mangled into a bogus relative one.
function Path.join(basePath, relativePath)
    if relativePath:match("^%a:[/\\]") or relativePath:sub(1, 1) == "/"
        or relativePath:sub(1, 1) == "\\" then
        return normalize(relativePath)
    end

    local parts = segments(normalize(basePath))
    for _, segment in ipairs(segments(normalize(relativePath))) do
        if segment == ".." and #parts > 0 then
            table.remove(parts)
        else
            table.insert(parts, segment)
        end
    end
    return table.concat(parts, "/")
end

return Path
