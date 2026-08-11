# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Loveboard is a lightweight, local-first bulletin board / planning app for game projects — think a stripped-down Trello/Miro/Twine that runs as a desktop app (via LÖVE) and saves its board data in a git-friendly format alongside the rest of a project. It's Lua, built on LÖVE 12.0 (pre-release — `love.window.showFileDialog` and other 12.0-only APIs are used deliberately).

## Commands

There is no build step; LÖVE runs the source tree directly.

- **Run**: `love .` (or `lovec .` for a console window that shows `print()` output) from the repo root.
- **Debug**: `love . debug` — the second arg triggers `lldebugger` in `main.lua`. VS Code's `.vscode/launch.json` has "Debug" and "Release" configs wired to this (requires the `lua-local` extension and a `love` command on PATH).
- **No test suite, linter, or formatter is configured.** There's no `package.json`/`rockspec`/CI. Verify changes by running the app and exercising the feature — see "Testing changes" below.

## Testing changes

There's no automated test harness. The working pattern used throughout this project's history is a **scripted smoke test**: temporarily add assertions inside `love.update` in `main.lua` that call `InputManager:dispatch(...)` to simulate input (mouse/keyboard events go through `InputManager`, not directly through `love.mousepressed` etc.), print `PASS`/`FAIL` lines, optionally call `love.graphics.captureScreenshot("name.png")` on a specific frame, then `love.event.quit()`. Run with `lovec .` piped to a log, inspect the screenshot (written to the LÖVE save directory — call `love.filesystem.setIdentity(...)` first to control where), then **revert the scaffolding from `main.lua` before finishing** — it should never be committed.

## Architecture

### Startup and the frame loop

`main.lua` is a thin LÖVE callback shim: every `love.*` callback forwards to either `ApplicationManager` (lifecycle: load/update/draw/resize/quit) or `InputManager:dispatch(event, ...)` (all input). `ApplicationManager` (`application/ApplicationManager.lua`) loads the theme first, then `Canvas`, `Board`, `UI` in that order — order matters because widgets/elements resolve theme tokens at draw time and expect a theme to already be loaded.

### Input: priority + consumption, not direct callbacks

`InputManager` (`application/InputManager.lua`) is the only thing that receives raw LÖVE input events. Everything else — UI widgets, the canvas, the board — subscribes via `InputManager:subscribe(event, handler, priority)` or `:subscribeAll(InputManager.MOUSE_EVENTS, handler, priority)`. Handlers are called in descending priority order; returning `true` from a handler **consumes** the event and stops propagation (except `mousemoved`, which is deliberately broadcast to everyone regardless of consumption, so widgets can clear hover state when the pointer leaves them).

Priority tiers (`InputManager.PRIORITY`): `MODAL(400) > POPUP(300) > CHROME(200) > ELEMENT(100) > CANVAS(0)`. This is how clicking a menu doesn't also pan the canvas underneath it — there's no manual "is this point over the UI" hit-testing for click routing. (There *is* one narrow exception: `UI:isPointOverUI(x, y)` exists solely so `Board`'s idle-hover cursor logic can tell the pointer is over chrome, since `mousemoved`'s broadcast nature means consumption can't answer that question. It is not used for click routing.)

### Styling: token-based theming

Widgets and canvas elements never store resolved colors/fonts — they store string tokens (`"surface"`, `"accent"`, `"small"`) and resolve them at draw time via `Theme` (`application/Style/Theme.lua`), which caches against whichever theme table is currently loaded (`application/Style/themes/Dark.lua` — pure data, no `love` calls). Swapping themes is a `Theme:load(newTheme)` call plus a cache clear; nothing needs to be rebuilt. `Theme:resolveColor`/`resolveMetric` accept either a token string or a literal value, so one-off overrides don't require inventing a theme entry.

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

- **`Element`** (`Element.lua`) is deliberately plain, serializable data: `id` (UUID via `lib/util/Id.lua`), `type`, a world-space rect (`x/y/width/height`), and a free-form `props` table. It has no behavior beyond trivial geometry helpers. This is intentional: the in-memory model doubles as the eventual save format.
- **`ElementRegistry`** (`ElementRegistry.lua`) maps `element.type` to a type-definition module (see `elements/PanelElement.lua` for the only one so far) exposing `defaultSize()`, `defaultProps()`, `draw(element, context)`, and optionally `hitTest`, `hitTestHandle(element, x, y, zoom)`, `minSize()`. **Adding a new element type is a new file in `elements/` plus one `ElementRegistry:register(...)` call in `Board.lua`** — `Document` and `Board` never need to know concrete types exist.
- **`Document`** (`Document.lua`) holds the ordered element list — array order *is* z-order (back to front), there's no separate z field — plus a `History`. Raw mutation methods (`insert`/`remove`/`raiseToFront`/`raiseAllToFront`) are used by commands; anything that should be undoable goes through `Document:execute`/`:pushApplied`.
- **`RectResize`** (`RectResize.lua`) is shared edge/corner hit-testing and clamped resize math, used by any rectangular element type (currently just `PanelElement`) so resize behavior doesn't get reimplemented per type.
- **`Selection`** (`Selection.lua`) is intentionally *not* part of `Document` — it's view state (what's currently selected), not board content, so it isn't serialized and isn't on the undo stack.

### Commands and undo/redo (`application/Canvas/commands/`, `History.lua`)

Every command implements `apply(document)` / `revert(document)` and must be an exact, idempotent inverse. Commands store **deltas and element ids**, never absolute state or object references, so they stay valid across an undo/redo cycle that removed and re-inserted an element.

Two ways to record a command, because interactive drags and one-shot edits differ:
- `Document:execute(command)` — applies then records. For actions where the change hasn't happened yet (menu items, etc.).
- `Document:pushApplied(command)` — records a change that's *already* in the document. Used after a drag/resize gesture, where the element was mutated live every frame so it visually follows the pointer; re-applying the finished command would double the effect.

`Composite` (`commands/Composite.lua`) bundles several commands into one undo step (applies forward, reverts backward) — e.g. a drag that both raises an element's z-order and moves it is one `Composite` so a single Ctrl+Z undoes both together. Existing commands (`MoveElements`, `ReorderElement`) are written generically enough (they take id *lists*) that multi-select group-move reuses them as-is rather than needing new "multi" variants.

Keyboard shortcuts: Ctrl+Z undo, Ctrl+Shift+Z or Ctrl+Y redo, wired in `Board:keypressed`.
