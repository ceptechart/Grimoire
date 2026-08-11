# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Grimoire is a lightweight, local-first bulletin board / planning app for game projects — think a stripped-down Trello/Miro/Twine that runs as a desktop app (via LÖVE) and saves its board data in a git-friendly format alongside the rest of a project. It's Lua, built on LÖVE 12.0 (pre-release — `love.window.showFileDialog` and other 12.0-only APIs are used deliberately).

## Roadmap

`TODO.md` in the repo root is the working plan: what's missing, in rough dependency order,
with the open design questions that aren't settled yet. Read it before starting a feature —
it records why some obvious-looking gaps are still gaps. Keep it current: check items off as
they land, and if a change alters an architectural rule described below, update both files
in the same change.

## Commands

There is no build step; LÖVE runs the source tree directly.

- **Run**: `love .` (or `lovec .` for a console window that shows `print()` output) from the repo root.
- **Debug**: `love . debug` — the second arg triggers `lldebugger` in `main.lua`. VS Code's `.vscode/launch.json` has "Debug" and "Release" configs wired to this (requires the `lua-local` extension and a `love` command on PATH).
- **No test suite, linter, or formatter is configured.** There's no `package.json`/`rockspec`/CI. Verify changes by running the app and exercising the feature — see "Testing changes" below.

## Testing changes

There's no automated test harness. The working pattern used throughout this project's history is a **scripted smoke test**: temporarily add assertions inside `love.update` in `main.lua` that call `InputManager:dispatch(...)` to simulate input (mouse/keyboard events go through `InputManager`, not directly through `love.mousepressed` etc.), print `PASS`/`FAIL` lines, optionally call `love.graphics.captureScreenshot("name.png")` on a specific frame, then `love.event.quit()`. Run with `lovec .` piped to a log, inspect the screenshot (written to the LÖVE save directory — call `love.filesystem.setIdentity(...)` first to control where), then **revert the scaffolding from `main.lua` before finishing** — it should never be committed.

## Architecture

### Startup and the frame loop

`main.lua` is a thin LÖVE callback shim: every `love.*` callback forwards to either `ApplicationManager` (lifecycle: load/update/draw/resize/quit) or `InputManager:dispatch(event, ...)` (all input). `ApplicationManager` (`application/ApplicationManager.lua`) loads the theme first, then `Canvas`, `Board`, `UI`, `TextEditSession`, `DialogManager`, `BoardFile` in that order — order matters because widgets/elements resolve theme tokens at draw time and expect a theme to already be loaded, and `BoardFile` reads the board's state for the window title (and can itself open a dialog, so `DialogManager` has to exist first too). `DialogManager:draw()` runs last, over everything else including toasts, since a modal has to sit above the whole app.

### Input: priority + consumption, not direct callbacks

`InputManager` (`application/InputManager.lua`) is the only thing that receives raw LÖVE input events. Everything else — UI widgets, the canvas, the board — subscribes via `InputManager:subscribe(event, handler, priority)` or `:subscribeAll(InputManager.MOUSE_EVENTS, handler, priority)`. Handlers are called in descending priority order; returning `true` from a handler **consumes** the event and stops propagation (except `mousemoved`, which is deliberately broadcast to everyone regardless of consumption, so widgets can clear hover state when the pointer leaves them).

The event set is keyboard (`keypressed`/`keyreleased`), text (`textinput` for a typed character, already mapped through the OS layout; `textedited` for an in-progress IME composition, which isn't text yet), and pointer (`InputManager.MOUSE_EVENTS`).

Priority tiers (`InputManager.PRIORITY`): `MODAL(400) > POPUP(300) > CHROME(200) > ELEMENT(100) > CANVAS(0)`. This is how clicking a menu doesn't also pan the canvas underneath it — there's no manual "is this point over the UI" hit-testing for click routing. (There *is* one narrow exception: `UI:isPointOverUI(x, y)` exists solely so `Board`'s idle-hover cursor logic can tell the pointer is over chrome, since `mousemoved`'s broadcast nature means consumption can't answer that question. It is not used for click routing.)

### Styling: token-based theming

Widgets and canvas elements never store resolved colors/fonts — they store string tokens (`"surface"`, `"accent"`, `"small"`) and resolve them at draw time via `Theme` (`application/Style/Theme.lua`), which caches against whichever theme table is currently loaded (`application/Style/themes/Dark.lua` — pure data, no `love` calls). Swapping themes is a `Theme:load(newTheme)` call plus a cache clear; nothing needs to be rebuilt. `Theme:resolveColor`/`resolveMetric` accept either a token string or a literal value, so one-off overrides don't require inventing a theme entry.

`application/Style/Clip.lua` is transform-aware scissor clipping: `love.graphics.setScissor` takes window pixels and ignores the transform stack, so world-space code can't hand it a world rect. `Clip.push/pop` converts through the live transform, intersects rather than replaces (so nesting narrows), and restores the previous scissor on pop.

`application/Style/Panel.lua` is a reusable background style (fill/border/corner-radius/shadow) shared across many widget instances — it holds no position, just draws into a rect it's given. `application/Style/Shadow.lua` renders drop shadows into a small cached canvas per distinct size (not the whole screen) using a two-pass separable blur (`lib/shaders/blur.glsl`), and resets the transform stack internally so it's safe to call from inside a scaled/translated draw (e.g. canvas elements).

### UI widget tree (`application/UI/`)

`Widget` (`Elements/Widget.lua`) is the base for anything with a position/size; `Container` (`Elements/Container.lua`) extends it for anything with children (`MenuBar`, `VerticalMenu`) and handles layout + input forwarding generically. Widgets are built with a fluent `:withX(...)` chain and use `Class.extend()` (`lib/util/Class.lua`) for prototype inheritance — constructors are `.new()`, not `:new()`, and every field is assigned per-instance in `init`/`new` rather than defaulted on the class table (a past bug class: a default parked on the class table is one shared object every instance that never overrides it mutates together).

Widgets distinguish `getDefaultWidth()` (subclasses override this) from `getWidth()` (applies `minWidth` on top, defined once on `Widget`) so `minWidth` behaves uniformly without every subclass re-implementing the clamp.

`application/UI/UI.lua` builds the actual chrome (menu bar, status bar, File menu) in `UI:load()`, not at module/require time — this guarantees the theme is loaded first and makes the chrome rebuildable later without restarting.

### Canvas and Board: pan/zoom vs. content

These are two separate systems, both drawn by `ApplicationManager`:

- **`Canvas`** (`application/Canvas/Canvas.lua`) owns pan/zoom state and the background grid only. `worldToScreen*`/`screenToWorld*` convert between spaces. Panning is middle-mouse-drag (uses `love.mouse.setRelativeMode` while panning); zoom is mouse-wheel, keeping the world point under the cursor fixed.
- **`Board`** (`application/Canvas/Board.lua`) owns the document's content and all element-level interaction (select/move/resize/marquee), drawn inside a `love.graphics.push()/translate(Canvas.offset)/scale(Canvas.zoom)/pop()` block so element code always works in world coordinates.

### The element model (`application/Canvas/`)

This is the part designed for extensibility — read this before adding a new canvas element type.

- **`Element`** (`Element.lua`) is deliberately plain, serializable data: `id` (UUID via `lib/util/Id.lua`), `type`, a world-space rect (`x/y/width/height`), and a free-form `props` table. It has no behavior beyond trivial geometry helpers and its own `toData()`/`fromData()`. This is intentional: the in-memory model *is* the save format.
- **`ElementRegistry`** (`ElementRegistry.lua`) maps `element.type` to a type-definition module (see `elements/PanelElement.lua` for the only real one so far) exposing `defaultSize()`, `defaultProps()`, `draw(element, context)`, and optionally `hitTest`, `hitTestHandle(element, x, y, zoom)`, `minSize()`, `textFields(element)` (see "Text editing"). **Adding a new element type is a new file in `elements/` plus one `ElementRegistry:register(...)` call in `Board.lua`** — `Document` and `Board` never need to know concrete types exist.
  - Two lookups, deliberately: `get(type)` errors on an unregistered type and is used where that's a bug (`create`), while `resolve(type)` falls back to `elements/UnknownElement.lua` and is used everywhere an element might have come out of a file (draw, hit testing). An unrecognized type keeps its real `type` and `props` and saves back byte-for-byte, so opening a board from a newer build and re-saving it doesn't destroy content.
- **`Document`** (`Document.lua`) holds the ordered element list — array order *is* z-order (back to front), there's no separate z field — plus a `History`. Raw mutation methods (`insert`/`remove`/`raiseToFront`/`raiseAllToFront`) are used by commands; anything that should be undoable goes through `Document:execute`/`:pushApplied`.
- **`RectResize`** (`RectResize.lua`) is shared edge/corner hit-testing and clamped resize math, used by any rectangular element type (currently just `PanelElement`) so resize behavior doesn't get reimplemented per type.
- **`Selection`** (`Selection.lua`) is intentionally *not* part of `Document` — it's view state (what's currently selected), not board content, so it isn't serialized and isn't on the undo stack.

### Commands and undo/redo (`application/Canvas/commands/`, `History.lua`)

Every command implements `apply(document)` / `revert(document)` and must be an exact, idempotent inverse. Commands store **deltas and element ids**, never absolute state or object references, so they stay valid across an undo/redo cycle that removed and re-inserted an element.

Two ways to record a command, because interactive drags and one-shot edits differ:
- `Document:execute(command)` — applies then records. For actions where the change hasn't happened yet (menu items, etc.).
- `Document:pushApplied(command)` — records a change that's *already* in the document. Used after a drag/resize gesture, where the element was mutated live every frame so it visually follows the pointer; re-applying the finished command would double the effect.

`Composite` (`commands/Composite.lua`) bundles several commands into one undo step (applies forward, reverts backward) — e.g. a drag that both raises an element's z-order and moves it is one `Composite` so a single Ctrl+Z undoes both together. Existing commands (`MoveElements`, `ReorderElement`) are written generically enough (they take id *lists*) that multi-select group-move reuses them as-is rather than needing new "multi" variants.

`SetProps` (`commands/SetProps.lua`) is the generic prop editor — a title rename, a note body, a color override. Props are arbitrary values rather than numbers, so unlike `MoveElements` there's no delta: it stores old and new values, both captured up front (`SetProps.capture(element, newValues)` reads the old ones off the element). `SetProps.NONE` is the sentinel for "this prop wasn't set", since a Lua table can't store `nil` — which is what makes *adding* a prop undoable.

Keyboard shortcuts: Ctrl+Z undo, Ctrl+Shift+Z or Ctrl+Y redo, wired in `Board:keypressed`.

### Text editing (`application/Text/`)

Three pieces, deliberately separate, because the same editor has to serve a canvas element under the canvas transform and (eventually) a UI field in screen space:

- **`TextEditor`** (`Text/TextEditor.lua`) is the buffer: text, caret, selection, and the operations over them (insert/delete, word motions, clipboard). No drawing, no input subscriptions, no `love.keyboard` — modifier state is passed *in* to `keypressed(key, ctrl, shift)`, so it's drivable from a test. Positions are **character** offsets, not byte offsets: the text is held split into UTF-8 characters, so a multi-byte character is one caret step and one backspace. Enter and Escape are deliberately not handled here — whether they commit or insert a newline is policy, not buffer behavior. Control characters are stripped on the way in, which is also what keeps a pasted newline out of a single-line field.
- **`TextEditSession`** (`Text/TextEditSession.lua`) is the singleton "field currently being edited": input routing, drawing, click-to-caret and drag-select. At most one is open — `begin()` commits any previous one. It sits at `PRIORITY.MODAL` and consumes *every* key while open, so Ctrl+S doesn't fire when you type an S. It subscribes **once, in `load()`, and no-ops while inactive**: a session normally opens from inside a `mousepressed` callback, and `InputManager:dispatch` walks its handler list in place, so subscribing there would mutate a list mid-dispatch.
- The **space adapter** (`TextEditSession.SCREEN`, and `WORLD_SPACE` in `Board.lua`) is what makes one session work in both coordinate systems: `toLocal` maps a screen point into the field's space, `scale` reports pixels per unit so hairlines stay one pixel wide at any zoom, and `name` selects which draw pass renders it (`Board:draw` calls `drawIn("world")` inside its transform; `ApplicationManager:draw` calls `drawIn("screen")` over the chrome).

Commit rules are fixed, and match every rename field anywhere: **Enter or a click away keeps the edit, Escape discards it.** A click that lands outside the field commits but is deliberately *not* consumed, so it still does whatever it would have done.

The session never touches the element — unlike a drag, which mutates live and calls `pushApplied`. The text lives in the `TextEditor` until commit, which then goes through `Document:execute(SetProps...)`. A rename that changed nothing records nothing, so it doesn't mark the board dirty.

Element types publish their editable text through `textFields(element)`, returning descriptors of `{ prop, x, y, width, height, font, color, hit? }` — the *text* rect in world coordinates, plus an optional larger `hit` region (a panel's whole header, not just the pixels the title covers). They're rebuilt from the element's live geometry on every call, which is how an open field tracks a panel that's being panned or zoomed under it; the session re-reads its rect every frame through `getRect`. Only ids cross into the session's callbacks, for the same reason commands store ids.

While a field is open the element must not draw that label itself, or the old value shows under the new one: `Board:draw` puts `editingId`/`editingProp` on the draw context (read from the session, so a commit from a click anywhere can't leave it stale) and the type skips that one label. Entry points are double-click on a text field and F2 with exactly one element selected, both in `Board`.

`love.keyboard.setKeyRepeat(true)` is on globally (`ApplicationManager:load`) for held Backspace and arrows; `BoardFile:keypressed` ignores repeats so a held Ctrl+S doesn't re-save per repeat.

**LÖVE 12 is on SDL3, which starts with text input off** — `love.textinput` never fires until something calls `love.keyboard.setTextInput(true)`, while `keypressed` works throughout. The symptom is a field you can backspace in but not type into, and it can't be caught by dispatching synthetic `textinput` events. `TextEditSession:updateTextInput` turns it on for the life of a session and off again after, and passes the field's rect in *screen* pixels (the one thing the space adapter's `toScreen` exists for) so an IME knows where the text is; the rect is re-pushed only when it moves.

### Modal dialogs (`application/UI/DialogManager.lua`, `application/UI/Elements/Dialog.lua`)

`DialogManager:confirm({ title, message, buttons = { { label, style, default, cancel, onPress }, ... } })` is the app's own replacement for `love.window.showMessageBox` — built from the same `Widget`/`Label`/`Button`/`Panel` pieces as the rest of the UI, so it matches the theme instead of the OS's. `style` is `"primary"` (the recommended action), `"danger"` (a destructive one — discarding unsaved work), or `"secondary"` (the default); `default`/`cancel` mark which button Enter/Escape trigger, the same vocabulary `showMessageBox`'s `enterbutton`/`escapebutton` used.

At most one dialog at a time, the same invariant `TextEditSession` keeps for text fields and for the same reason: `PRIORITY.MODAL` exists to give one thing an unambiguous turn at demanding an answer, and `DialogManager` sits there too, consuming every event unconditionally while a dialog is open (mouse *and* keyboard) — that's what "blocks input beneath, dims the canvas" means for something modal. `confirm()` calls `TextEditSession:commit()` before opening, so the two MODAL residents never actually overlap: a dialog always finds any open field already closed rather than fighting it for the tier.

**Every dialog is asynchronous** — `love.window.showMessageBox` blocked until answered, but a dialog built from the widget tree can only be answered on some later frame's input dispatch. Each button's `onPress` in the options table is wrapped to call `close()` first, so callers never have to remember to; `BoardFile:guardUnsaved`'s `continue` continuation already assumed a callback could be delayed (Save could already lead to an async `showFileDialog`), so switching it over to `DialogManager:confirm` needed no restructuring — see "Persistence" below.

`Dialog` itself is a bespoke `Widget`, not a `Container` of stacked children: title above a wrapped message above a right-aligned button row is a one-off shape, sized to its content and recentred every `layout()` call (so a live resize doesn't leave it off-center). It has no `InputManager` subscription of its own — `DialogManager` owns that and forwards into the dialog's buttons, the same split `ToastManager`/`Toast` use.

### Persistence: the `.grimoire` save format (`application/BoardFile.lua`, `lib/util/Serialize.lua`)

**A board is one JSON file with a `.grimoire` extension.** This is a one-way door, so the reasoning: JSON is readable and hand-editable, every language has a parser (a board is data other tools may want to read), and it needs no `love` runtime to load — unlike a Lua-table format read back through `love.filesystem.load`, which would also be an arbitrary-code-execution hole in a file people share. One file rather than a directory of per-element files: worse for merge conflicts, much better for everything else, and revisitable if boards get big.

Being git-friendly is a property of the *writer*, not of JSON:

- `lib/util/Serialize.lua` owns encoding. Object keys are **sorted**, numbers are **rounded to 4 decimals** (world coordinates come out of pointer math with float noise on the end), integers print without a decimal point, `-0` collapses to `0`, and values are indented one per line. Together those mean an unchanged board re-saves **byte-identical**, and a diff points at the element that actually changed.
- `lib/external/json.lua` (rxi's, vendored) is used for **decoding only** — its encoder walks tables with `pairs()`, writes `%.14g` numbers, and emits one line, all of which produce diffs that correspond to no edit. Don't reach for `json.encode` for anything that lands on disk.
- Empty Lua tables are ambiguous (`{}` could be `[]` or `{}`), so `Serialize.array(t)` marks tables that must write as JSON arrays even when empty.

The shape of the file is `{ "version": <int>, "elements": [ ... ] }`, one object per element with exactly the `Element` fields. `Document.SCHEMA_VERSION` is written from day one; a file claiming a *newer* schema is refused rather than half-read. `Selection` and `History` are view state and are not in the file, so an opened board starts with nothing selected and an empty undo stack.

`Document:toData()` / `Document.fromData(data)` are the boundary. `fromData` returns `document, warnings` or `nil, message`, and the split is the policy: an unknown element type is a **warning** (content survives, see `ElementRegistry:resolve`), while a duplicate id or non-numeric coordinate is a **refusal**, because guessing would silently lose content.

`application/BoardFile.lua` owns the rest: the current path, new/open/save/save-as, and the window title. Two constraints shape it —

- **Board files live outside the LÖVE save directory**, so `love.filesystem` can't touch them (it only writes inside the identity folder). Plain `io.*` is used instead, which LÖVE leaves unsandboxed.
- **`love.window.showFileDialog` is asynchronous** — it returns immediately and calls back with `(files, filtername, errorstring)` later. Anything that must happen *after* a save takes a continuation, which is why `save`/`saveAs` take an `onDone(saved)` and `guardUnsaved(action, continue)` doesn't return a boolean.

Dirty tracking compares `History:getStateToken()` — the command on top of the undo stack, which identifies the whole edit sequence — against the token taken at save time. That's deliberately not a monotonic counter or a manual flag: it means undoing back to the state that was written reports clean again. Shown as a trailing `*` in the window title and the status bar.

Unsaved-changes prompts (New, Open, quit) go through `DialogManager:confirm` (see "Modal dialogs" below) rather than a return value, so `guardUnsaved(action, continue)` takes a continuation and never returns one itself. Quit is the awkward case: `love.quit` wants a synchronous `true` to abort, and the dialog is *never* synchronous (unlike the native message box it replaced, which blocked until answered) — so a dirty quit always **abandons that quit and re-issues one** once a button is actually pressed, via `shouldBlockQuit`'s `returned` flag.

Errors on every path (unreadable file, malformed JSON, refused schema, failed write) surface as an error toast with no timeout, never as a crash.
