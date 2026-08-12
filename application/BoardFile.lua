local InputManager = require "application.InputManager"
local Serialize = require "lib.util.Serialize"
local Document = require "application.Canvas.Document"
local DialogManager = require "application.UI.DialogManager"

-- Resolved in load() rather than at require time: Board requires UI, so requiring
-- either from here at load time would close the require cycle. Same trick UI uses to
-- reach Board.
local Board
local UI

-- Owns the board's relationship with the filesystem: which file is open, whether
-- what's on screen differs from what's on disk, and the new/open/save/save-as
-- actions behind the File menu and Ctrl+N/O/S.
--
-- Two things shape the code here more than anything else:
--
--   * File dialogs are asynchronous. love.window.showFileDialog returns immediately
--     and calls back later, so anything that has to happen *after* a save takes a
--     continuation rather than reading a return value.
--   * Board files live outside the LOVE save directory, so love.filesystem can't
--     touch them (it only writes inside the identity folder). Plain io.* is used
--     instead, which LOVE leaves unsandboxed.
local BoardFile = {}

local EXTENSION = "grimoire"
local UNTITLED = "Untitled"
local APP_NAME = "Grimoire"

-- name -> pattern, the shape love.window.showFileDialog wants.
local FILTERS = { ["Grimoire board"] = EXTENSION }

local function isCtrlDown()
    return love.keyboard.isDown("lctrl", "rctrl") or love.keyboard.isDown("lgui", "rgui")
end

local function isShiftDown()
    return love.keyboard.isDown("lshift", "rshift")
end

local function baseName(path)
    return path:match("[^/\\]+$") or path
end

local function withExtension(path)
    if path:lower():sub(-(#EXTENSION + 1)) == "." .. EXTENSION then
        return path
    end
    return path .. "." .. EXTENSION
end

local function readFile(path)
    local file, err = io.open(path, "rb")
    if not file then
        return nil, err or "could not be opened"
    end

    local text = file:read("*a")
    file:close()

    if not text then
        return nil, "could not be read"
    end
    return text
end

local function writeFile(path, text)
    local file, err = io.open(path, "wb")
    if not file then
        return false, err or "could not be opened for writing"
    end

    local ok, writeErr = file:write(text)
    file:close()

    if not ok then
        return false, writeErr or "could not be written"
    end
    return true
end

local function fileExists(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

-- Writes `text` to `path` without ever leaving the user's only copy half-written.
--
-- Opening the destination directly and writing into it is the failure this exists to
-- avoid: a crash, a full disk or a lost network share partway through truncates the
-- board to whatever made it out. So the new content goes to a temporary file first
-- and only replaces the old one once it's completely on disk.
--
-- The swap is three renames rather than one because os.rename won't overwrite an
-- existing file on Windows -- the destination has to be moved aside first. That
-- introduces the one moment when nothing is at `path`, so the displaced original is
-- kept as a backup and put back if the swap fails, rather than deleted up front.
local function writeFileAtomic(path, text)
    local tempPath = path .. ".tmp"
    local backupPath = path .. ".bak"

    local written, writeErr = writeFile(tempPath, text)
    if not written then
        os.remove(tempPath)
        return false, writeErr
    end

    local hadOriginal = fileExists(path)
    if hadOriginal then
        os.remove(backupPath)
        local movedAside, moveErr = os.rename(path, backupPath)
        if not movedAside then
            os.remove(tempPath)
            return false, moveErr or "the existing file could not be replaced"
        end
    end

    local renamed, renameErr = os.rename(tempPath, path)
    if not renamed then
        -- The board is still intact in the backup; put it back so the failed save
        -- leaves the file exactly as it was.
        if hadOriginal then
            os.rename(backupPath, path)
        end
        os.remove(tempPath)
        return false, renameErr or "could not be written"
    end

    os.remove(backupPath)
    return true
end

function BoardFile:load()
    Board = require "application.Canvas.Board"
    UI = require "application.UI.UI"

    self.path = nil
    self.title = nil
    self.dialogOpen = false
    self.quitConfirmed = false
    self:markClean()

    -- CHROME, above Board's ELEMENT: Ctrl+S is a file action wherever the pointer
    -- happens to be, and Board must not get a look at it first.
    InputManager:subscribe("keypressed", self, InputManager.PRIORITY.CHROME)
end

-- ── State ────────────────────────────────────────────────────────────────

function BoardFile:getPath()
    return self.path
end

function BoardFile:getDisplayName()
    return self.path and baseName(self.path) or UNTITLED
end

-- Records the document state the file on disk now matches. Everything downstream
-- (the title's asterisk, the quit prompt) is a comparison against this.
function BoardFile:markClean()
    self.savedToken = Board:getDocument():getStateToken()
end

function BoardFile:isDirty()
    return Board:getDocument():getStateToken() ~= self.savedToken
end

-- What the status bar shows: the file name, with the usual trailing asterisk while
-- there are unsaved edits.
function BoardFile:getStatusText()
    return self:getDisplayName() .. (self:isDirty() and "*" or "")
end

-- Dirty state changes on any edit, so the title is recomputed every frame -- but only
-- pushed to the OS when the text actually changes.
function BoardFile:update(dt)
    local title = ("%s - %s"):format(self:getStatusText(), APP_NAME)
    if title ~= self.title then
        self.title = title
        love.window.setTitle(title)
    end
end

local function fail(message)
    UI:showToast("error", message, { timeout = false })
end

-- ── Actions ──────────────────────────────────────────────────────────────

function BoardFile:new()
    self:guardUnsaved("start a new board", function()
        Board:setDocument(Document.new())
        self.path = nil
        self:markClean()
    end)
end

function BoardFile:open()
    self:guardUnsaved("open another board", function()
        self:showDialog("openfile", { title = "Open board" }, function(path)
            self:openPath(path)
        end)
    end)
end

-- onDone(saved) fires either way, so callers that were waiting on the save (the quit
-- prompt) can tell a completed save from a cancelled dialog.
function BoardFile:save(onDone)
    if self.path then
        self:saveTo(self.path, onDone)
    else
        self:saveAs(onDone)
    end
end

function BoardFile:saveAs(onDone)
    local settings = {
        title = "Save board as",
        acceptlabel = "Save",
        defaultname = self.path and baseName(self.path) or (UNTITLED .. "." .. EXTENSION),
    }

    self:showDialog("savefile", settings, function(path)
        -- The dialog doesn't enforce the filter on a typed-in name.
        self:saveTo(withExtension(path), onDone)
    end, onDone)
end

function BoardFile:openPath(path)
    local text, readErr = readFile(path)
    if not text then
        fail(("Could not open %s: %s"):format(baseName(path), readErr))
        return false
    end

    local data, decodeErr = Serialize.decode(text)
    if not data then
        fail(("%s is not a valid board file: %s"):format(baseName(path), decodeErr))
        return false
    end

    local document, warningsOrError = Document.fromData(data)
    if not document then
        fail(("Could not read %s: %s"):format(baseName(path), warningsOrError))
        return false
    end

    Board:setDocument(document)
    self.path = path
    self:markClean()

    -- No timeout: an unknown type means content this build can't render, which is
    -- worth making the user dismiss rather than letting it scroll past.
    for _, warning in ipairs(warningsOrError) do
        UI:showToast("warn", warning, { timeout = false })
    end

    local count = document:count()
    UI:showToast("success",
        ("Opened %s (%d element%s)"):format(baseName(path), count, count == 1 and "" or "s"),
        { timeout = 2 })
    return true
end

function BoardFile:saveTo(path, onDone)
    -- Encoding raises on anything JSON can't hold -- a stray function in a props
    -- table, say. That's a bug in an element type rather than a file problem, but
    -- it's still no reason to take the app down with the user's board in it.
    local encoded, text = pcall(Serialize.encode, Board:getDocument():toData())
    if not encoded then
        fail("Could not save: " .. tostring(text))
        if onDone then onDone(false) end
        return false
    end

    -- Trailing newline: it's a text file, and git prefers one.
    local written, writeErr = writeFileAtomic(path, text .. "\n")
    if not written then
        fail(("Could not save %s: %s"):format(baseName(path), writeErr))
        if onDone then onDone(false) end
        return false
    end

    self.path = path
    self:markClean()
    UI:showToast("success", "Saved " .. baseName(path), { timeout = 2 })

    if onDone then onDone(true) end
    return true
end

-- ── Dialogs ──────────────────────────────────────────────────────────────

-- Wraps love.window.showFileDialog: adds the board filter, keeps a second dialog from
-- being opened over the first, and reduces the callback's (files, filtername, error)
-- to onPath(path) for a choice and onCancelled(false) for anything else.
function BoardFile:showDialog(dialogType, settings, onPath, onCancelled)
    if self.dialogOpen then
        if onCancelled then onCancelled(false) end
        return
    end

    settings.filters = FILTERS
    settings.attachtowindow = true

    self.dialogOpen = true
    love.window.showFileDialog(dialogType, function(files, filtername, err)
        self.dialogOpen = false

        if err then
            fail("File dialog failed: " .. tostring(err))
            if onCancelled then onCancelled(false) end
            return
        end

        local path = files and files[1]
        if not path then -- cancelled
            if onCancelled then onCancelled(false) end
            return
        end

        onPath(path)
    end, settings)
end

-- Runs `continue` once it's safe to throw the current board away: straight away when
-- nothing is unsaved, after a successful save if the user asks for one, and not at
-- all if they cancel or dismiss the dialog.
--
-- Every path here is now asynchronous -- DialogManager doesn't block like the native
-- message box this used to call did -- which is exactly what this was already
-- written to handle: `continue` was always a continuation rather than a return
-- value, because Save could already lead to an async file dialog underneath it.
function BoardFile:guardUnsaved(action, continue)
    if not self:isDirty() then
        continue()
        return
    end

    DialogManager:confirm({
        title = "Unsaved changes",
        message = ("%s has unsaved changes.\n\nSave before you %s?"):format(self:getDisplayName(), action),
        buttons = {
            { label = "Save", style = "primary", default = true, onPress = function()
                self:save(function(saved)
                    if saved then continue() end
                end)
            end },
            { label = "Discard", style = "danger", onPress = continue },
            { label = "Cancel", style = "secondary", cancel = true },
        },
    })
end

-- love.quit wants `true` to abort the quit. The dialog is never blocking now (it's
-- just another frame of the game loop, not an OS call that pumps its own modal loop)
-- so every dirty quit takes the deferred path below: this quit is abandoned, and
-- whichever button the user ends up pressing re-issues one from its callback.
function BoardFile:shouldBlockQuit()
    if self.quitConfirmed then
        return false
    end

    local returned = false
    local proceed = false

    self:guardUnsaved("quit", function()
        self.quitConfirmed = true
        proceed = true
        if returned then
            love.event.quit()
        end
    end)

    returned = true
    return not proceed
end

-- ── Keyboard ─────────────────────────────────────────────────────────────

function BoardFile:keypressed(key, scancode, isrepeat)
    -- Key repeat is on for text editing (see ApplicationManager), and a held Ctrl+S
    -- would otherwise re-save once per repeat. Not consumed, so Board still gets the
    -- repeats it does want.
    if isrepeat or not isCtrlDown() then
        return false
    end

    if key == "s" then
        if isShiftDown() then
            self:saveAs()
        else
            self:save()
        end
    elseif key == "o" then
        self:open()
    elseif key == "n" then
        self:new()
    else
        return false
    end

    return true
end

return BoardFile