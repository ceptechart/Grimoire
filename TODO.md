# TODO

Working plan for Grimoire. Sections are roughly in dependency order — §1 unblocks most of
what follows. Within a section, items are ordered so the earlier ones make the later ones
cheap.

See [CLAUDE.md](CLAUDE.md) for the architecture this plan assumes. Anything here that
changes an architectural rule should update CLAUDE.md in the same change.

## 0. Bugs / QoL Features ... Non Urgent

A collection of nonurgent bugs or features that should be resolved eventually.
- [ ] Max panel title length
- [ ] Panel title should be appended by elipses "..." if it is too long for title bar.

## 1. Persistence — mostly landed

The format is settled and the core is in: a board is one JSON file with a `.grimoire`
extension, written deterministically so an unchanged board re-saves byte-identical.
See CLAUDE.md's "Persistence" section for the reasoning and the file shape.

- [x] **Pick the format.** JSON, one file, `.grimoire`. Decision and rationale in CLAUDE.md.
- [x] Add a `.gitignore` entry for whatever save/scratch files §1 introduces.
- [x] `lib/util/Serialize.lua`: deterministic encode (sorted keys, numbers rounded to 4
      decimals, one value per line), decode via the vendored `lib/external/json.lua`.
- [x] `Document:toData()` / `Document.fromData(data)`, with a `version` field.
      `Element:toData()` / `Element.fromData()` alongside (this is what the unused
      `Element.restore` became).
- [x] Unknown-element-type handling on load: `elements/UnknownElement.lua` is attached
      via `ElementRegistry:setFallback`. Unrecognised elements keep their real `type`
      and `props`, draw as a labelled placeholder, can be moved out of the way but not
      resized, and save back verbatim. A no-timeout warning toast names the type.
- [x] `application/BoardFile.lua`: owns the current file path, new/open/save/save-as via
      `love.window.showFileDialog`, and the window title.
- [x] Dirty tracking — via `History:getStateToken()` (the command on top of the undo
      stack) rather than the counter this list originally proposed: a counter can't tell
      that undoing back to the last-saved state has made the board clean again. Shown as
      a trailing `*` in the window title and the status bar.
- [x] Unsaved-changes prompt on New / Open / quit. Originally the blocking native
      `love.window.showMessageBox`; now `DialogManager:confirm` (§4's in-app modal),
      swapped in inside `BoardFile:guardUnsaved` without needing to restructure it —
      `continue` was already a continuation, not a return value.
- [x] Error paths: unreadable file, malformed data, refused schema, failed write → error
      toast with no timeout, not a crash.
- [x] **Atomic writes.** `writeFileAtomic` writes a `.tmp` alongside the target and swaps
      it in. `os.rename` won't overwrite on Windows, so the target moves aside to a
      `.bak` first and is renamed back if the swap fails — the failure mode this was
      warned against. Covered in `tests/smoke.lua`, including the overwrite-in-place case
      and asserting neither temporary is left behind.
- [ ] The open/save-as dialogs are only smoke-tested as far as "the dialog opens without
      an argument error"; the callback paths were exercised with the dialog stubbed. Walk
      them once by hand with real clicks.
- [ ] Recent files list, persisted to the save directory.
- [ ] Autosave / crash recovery (defer until the format is stable).

---

## 2. Element authoring

Create and delete both work. What's left is the copy/duplicate/z-order family.

- [x] Create: a tool palette down the left edge (§4). Picking the Panel tool turns a
      left-drag on the canvas into a new element sized by the drag, routed through
      `Document:execute(AddElement.new(...))`, so it undoes. The pending element is drawn
      faded (via `Theme:pushOpacity`) and tracks the pointer and nothing else; both size
      rules land at release, where a rect under 10 screen px counts as a click and makes a
      default-sized element, and anything larger is clamped up to the type's `minSize`. Which tool is active lives in
      `application/Canvas/Tools.lua`; a tool with a `createType` drags out that element
      type, so a tool for a new type is one entry in that list. See CLAUDE.md's "Tools"
      section.
- [ ] Other create routes onto the same `beginCreate` gesture: double-click empty canvas,
      and a right-click context menu (§4).
- [x] `commands/RemoveElements.lua` — takes an id list, stores each removed element *and
      its index* so revert restores exact z-order (`Document:remove` already returns both).
      Wire to Delete/Backspace in `Board:keypressed` and to `Edit > Delete`.
- [ ] Duplicate (Ctrl+D) — offset copy, new ids, selection follows the copies.
- [ ] Copy/cut/paste (Ctrl+C/X/V) with an in-app clipboard; paste at pointer. Cross-process
      paste via `love.system.setClipboardText` using the §1 serializer is a nice follow-on.
      Removed from the Edit menu until they exist — an item that silently does nothing is
      worse than one that isn't offered. Add them back alongside the implementation.
- [x] `Edit` menu items no longer `print()`: Undo / Redo / Select All / Delete all go
      through `application/Actions.lua`, which is also what `Board:keypressed` calls, so
      menu and keyboard are two doors onto one implementation. New verbs go there.
- [ ] Z-order commands: bring to front / send to back / forward / backward. `ReorderElement`
      already covers the mechanics; this is a command wrapper plus menu items. Note the
      ordering rule in §7 — the ids have to arrive in document order.

---

## 3. Text input and inline editing — mostly landed

Single-line inline editing works: double-click a panel's header (or F2 with one element
selected) to rename it. See CLAUDE.md's "Text editing" section for the split between the
buffer, the session, and the field descriptors element types publish.

- [x] Added `textinput` and `textedited` to `EVENTS` in
      [InputManager.lua](application/InputManager.lua) and forwarded them from
      [main.lua](main.lua), same shape as the other callbacks.
- [x] Key-repeat: `love.keyboard.setKeyRepeat(true)` in `ApplicationManager:load`. The
      only thing that minded was `BoardFile:keypressed`, which now ignores repeats so a
      held Ctrl+S doesn't re-save per repeat; Board's undo wants them.
- [x] `application/Text/TextEditor.lua` — caret, selection, insert/delete, clipboard,
      arrow/Home/End, word motions. Free of draw and input-subscription concerns, and
      UTF-8 aware (positions are character offsets, not byte offsets).
- [x] `application/Text/TextEditSession.lua` — the one open field, at `MODAL` priority so
      it swallows shortcuts. Enter or a click away commits, Escape discards. Works in
      world *and* screen space via the `space` adapter it's handed.
- [x] `commands/SetProps.lua` — generic "change these props", recording old and new
      values, with a sentinel for "wasn't set" so adding a prop is undoable too.
- [x] **Watch out:** `InputManager:dispatch` walks the handler list in place. The session
      subscribes once in `load()` and no-ops while inactive, rather than subscribing from
      inside the click that opens it.
- [ ] A UI text field widget on top of the same session — the screen-space path is
      written and drawn from `ApplicationManager:draw`, but nothing uses it yet, so it's
      unexercised.
- [ ] Multi-line editing, for §5's note/sticky: `TextEditor` strips control characters
      (so a pasted newline can't get in) and the session treats Enter as commit. Wrapping,
      up/down between lines, and a per-field "Enter inserts a newline" rule are the work.
- [ ] IME composition is stored and drawn underlined at the caret, but only tested by
      reading the code — try it with a real input method. The session hands SDL the
      field's screen rect via `setTextInput`, which is what positions the candidate
      window, so that's the part to watch.
- [ ] Double-click currently only opens the *first* field under the pointer and there's no
      Tab between fields; both matter once an element type has more than one.

---

## 4. UI chrome: dialogs, context menus, real menu behaviour

- [x] **Modal dialog system** at `PRIORITY.MODAL` — `DialogManager`/`Dialog` in
      `application/UI/`. Blocks input beneath, dims the canvas, Enter/Escape go to
      whichever button was declared `default`/`cancel`. Replaced the native
      `love.window.showMessageBox` inside `BoardFile:guardUnsaved` (§1). Closes any
      open `TextEditSession` field first (`commit`, not `cancel`) so the two MODAL
      residents never actually overlap. See CLAUDE.md's "Modal dialogs" section.
      Only a confirm-with-buttons shape exists — no plain alert/OK, no text-prompt
      variant; add one if something other than a yes/no/cancel choice shows up.
- [ ] **Context menu** on right-click — `VerticalMenu` at `PRIORITY.POPUP` positioned at
      the pointer, with different items for empty canvas vs. a selection.
- [ ] Menu polish: disabled items (grey out Undo when `History:canUndo()` is false —
      `Actions.canUndo`/`canRedo` are already there for exactly this), shortcut hints in
      the right margin, hover-to-switch between open top-level menus,
      click-outside-to-close, keyboard navigation.
- [x] `View` menu wired to real `Canvas` calls — `zoomIn` / `zoomOut` / `resetZoom`,
      anchored to the middle of the window since there's no pointer to anchor to, and
      shared with the Ctrl+`=`/`-`/`0` shortcuts via `Actions`.
- [x] `Help > About` — a one-button dialog through `DialogManager:confirm`. `Documentation`
      dropped until there's something to point it at.
- [x] The status bar refresh button did nothing; removed. Its slot now holds a zoom
      percentage readout, which keyboard/menu zoom needed somewhere to land.
- [x] The status bar's unexplained `/100` divisor is gone; it reads plain world
      coordinates. §6's "coordinate units" question is still open, but nothing is
      claiming a unit it can't name any more.
- [x] Toolbar / element palette down one side — `Elements/ToolBar.lua`, built in `UI:load`
      from `Tools:list()`: circular icon buttons that collapse sideways off the screen
      edge behind a toggle. Tooltips are the obvious next thing (the `label` field on each
      tool definition is already there and unused).

---

## 5. More element types

Adding a type is a file in `application/Canvas/elements/` plus one `ElementRegistry:register`
call in [Board.lua](application/Canvas/Board.lua), and — to make it reachable — one entry
with a `createType` in [Tools.lua](application/Canvas/Tools.lua), which puts a button in the
palette and gives it `CreateGesture` for free. `PanelElement` is the template;
`RectResize` is already shared for anything rectangular.

- [ ] **Note / sticky** — body text, wraps, no header. Needs §3's remaining multi-line
      work; the single-line editor and `textFields` hook are in.
- [ ] **Card** — title + tags + optional checkbox list; the Trello-ish unit.
- [ ] **Text label** — no background, size follows the text.
- [ ] **Image** — needs a decision on whether the file is referenced by relative path
      (git-friendly, matches the local-first goal) or embedded.
- [ ] **Connector / link** — the Twine-ish piece, and the one that stresses the model:
      it's anchored to two elements rather than being a free rect, so it needs endpoint
      references, re-routing when an endpoint moves, non-rect hit testing, and a rule for
      what happens when an endpoint element is deleted. Design it before building it.
- [ ] **Group / frame** — a rect that owns children and moves them together.
- [ ] Per-element color/style overrides via `props` (`Theme:resolveColor` already accepts a
      literal value, so this needs no new theme entries).

---

## 6. Canvas and navigation

- [x] Keyboard zoom: Ctrl+`=` / Ctrl+`-` / Ctrl+0 reset, shared with the `View` menu via
      `Actions`. Anchored to the middle of the window (no pointer to anchor to) and at a
      much larger step than a wheel notch. There's a zoom percentage in the status bar now.
- [ ] Zoom to fit / zoom to selection — compute the content bounding box
      (`lib/util/math/BoundingBox.lua` exists and looks unused for this).
- [ ] Space+drag pan, and trackpad two-finger pan (`wheelmoved` with an x delta is
      still ignored — `Canvas:wheelmoved` bails on `y == 0`). Left alone deliberately:
      trackpad wheel semantics need a trackpad to verify against, and guessing them is
      worse than the gap.
- [ ] Snap-to-grid on move/resize, with a modifier to bypass, plus alignment guides against
      neighbouring elements.
- [ ] Minimap / overview, once boards get large enough to get lost in.
- [ ] Persist pan/zoom per board — but as view state in a sidecar/preferences file, not in
      the board file (same reasoning that keeps `Selection` out of `Document`).

---

## 7. Selection and arrangement

- [x] Select all (Ctrl+A) and deselect (Escape), both through `Actions`. Escape now backs
      out one step at a time — the active tool first, then the selection — and is still
      only consumed when it did something. Invert is still open.
- [ ] Arrow-key nudge, Shift+arrow for a coarse step — reuses `MoveElements` as-is.
- [ ] Group resize: `Board:mousepressed` deliberately narrows a `ResizeGesture` to a single
      element. Multi-resize needs a selection bounding box with its own handles and
      proportional per-element scaling — which is a new gesture in
      `application/Canvas/gestures/`, not a change to `ResizeGesture`.
- [ ] Align / distribute (left, center, right, top, middle, bottom, spacing) — a `Composite`
      of `MoveElements`.
- [x] **Selection ordering is settled.** `Selection` is now a membership set that can't be
      iterated in any meaningful order at all; `Document:selectedIds(selection)` returns
      document order and is the only way out. This wasn't hypothetical — the hash order
      was corrupting `RemoveElements`' undo (see "Known rough edges"). Anything
      order-sensitive must go through `selectedIds`.
- [ ] Marquee currently selects on *any* overlap. Consider a modifier for
      fully-contained-only, which is what most editors do on a right-to-left drag.

---

## 8. Theming and visual polish

- [ ] A Light theme in `application/Style/themes/`, plus a `View > Theme` switcher.
      `Theme:load` + cache clear is supposed to be all that's needed — this is the test of
      whether that's actually true.
- [ ] Persist the theme choice with the other preferences.
- [ ] Text sharpness at zoom: `PanelElement.draw` rasterizes at the theme size and lets the
      canvas transform scale it, and the code comment already flags per-zoom font sizes as
      the fix ([PanelElement.lua:77](application/Canvas/elements/PanelElement.lua#L77)).
      Needs a font cache keyed by (token, zoom bucket).
- [ ] DPI / `love.window.getDPIScale` handling for high-DPI displays.
- [x] The selection outline pulsed off `os.clock()`, which on Windows is *CPU* time, not
      wall clock — so the pulse rate tracked process load. Now accumulated `dt` via
      `Board:update`. The per-frame `Color` allocation is gone too: `Color:mix` blends in
      RGB into a reusable instance instead of round-tripping through HSL.
- [ ] Hover affordance on elements (subtle outline before selection).

---

## 9. Performance (not urgent — revisit when boards get big)

- [ ] Cull elements outside the viewport in `Board:draw`.
- [ ] `Document:indexOf` and `Document:remove` are O(n) linear scans, and `raiseAllToFront`
      calls them in a loop — O(n²) on a large multi-select drag. Fine at three elements;
      measure before optimizing.
- [ ] Spatial index for hit testing if `handleAt`'s front-to-back scan shows up in a profile.
- [x] `Selection:count()` is tracked as ids go in and out rather than counted on demand,
      since `updateStatusBar` asks every frame.

---

## 10. Testing and tooling

`love . test [name]` runs `tests/<name>.lua` (default `smoke`) against the real app,
driven by `tests/runner.lua`. Assertions live in tracked files now instead of being pasted
into `main.lua` and scrubbed out again — that scrubbing step is what kept losing them.
See CLAUDE.md's "Testing changes".

- [x] A dedicated test entry point — `love . test <name>` loading `tests/<name>.lua`.
      Steps run one per frame, so a test can hold a gesture open across frames and see
      what a user would. Exits non-zero on failure.
- [x] `tests/smoke.lua` — 57 assertions covering every gesture and its undo (position
      *and* z-order), delete/undo, the `Actions` verbs, `Selection`'s tracked count, and
      a save → load → re-encode round trip through the atomic writer. Plus three
      screenshot passes for the things only a human can check.
- [ ] Headless unit tests for the pure modules (`History`, `Document`, `Selection`, the
      commands, the serializer). They don't need a window — but they do need a Lua
      interpreter on PATH, which the current setup doesn't have, so for now they run
      inside the same LÖVE process as everything else. Worth splitting when CI lands.
- [ ] Round-trip *property* test for §1: random board → save → load → identical. The
      fixed-board version of this is in `tests/smoke.lua`; the generator isn't.
- [ ] Undo/redo fuzz: random command sequence, undo everything, assert the document matches
      its starting state exactly. This is the invariant the whole command design rests on,
      and it's the test that would have caught the `RemoveElements` ordering bug on its
      own rather than by inspection.
- [ ] GitHub Actions: needs a LÖVE 12 binary and a headless GL context (xvfb) in the
      runner. `love . test` already exits non-zero, so the workflow is the only missing
      piece.

---

## 11. Documentation

- [ ] README: what it is, screenshot, how to run, current status.
- [ ] Keybinding reference (currently only discoverable by reading `Board:keypressed` and
      `BoardFile:keypressed`). Also missing from the menus, which show no shortcut hints.
- [ ] Document the `.grimoire` format for outside readers — it's a file format other tools may
      read. CLAUDE.md covers the internals; this wants a short public spec.
- [ ] A short "adding a new element type" walkthrough pointing at `PanelElement` as the
      worked example.

---

## Known rough edges

Small, concrete, independently fixable. Pick these up when nearby.

- [x] `Board:update(dt)` is wired into `ApplicationManager:update`, ahead of `UI:update` so
      the status bar reads a selection that's already been pruned this frame. `Canvas`
      still gets no `dt` — nothing about pan/zoom animates, so an empty `update` would be
      dead code. Add it when something needs it.
- [ ] `Canvas:mousemoved` returns nothing while panning — it doesn't consume, which is
      currently harmless because `mousemoved` is broadcast anyway, but it's inconsistent
      with every other handler.
- [ ] `Board:mousepressed` consumes button 1 unconditionally, including clicks that only
      started a marquee on empty canvas. Correct today; worth remembering if another
      subscriber ever wants a look at background clicks.
- [ ] Middle-drag panning turns on `love.mouse.setRelativeMode`, which freezes the reported
      `x, y` while leaving `dx, dy` correct. Nothing minds today (`Canvas` only reads the
      deltas, and `Board` only uses `x, y` for hover), but a left-drag gesture still in
      flight when a middle-drag starts would track a stale pointer. Not reachable through
      the UI; noted so it isn't rediscovered as a mystery.
- [x] **`RemoveElements:revert` reinserted in removal order rather than reverse.** Each
      index was recorded against the array as it stood at that moment, so replaying
      forwards put elements back at the wrong depth — and when the id list happened to
      remove a high index first, `table.insert` wrote past the end of a now-shorter array
      and left a hole in it. Deleting two or more elements and pressing Ctrl+Z was enough
      to hit it. Reverting backwards is the only order that's a true inverse; regression
      test in `tests/smoke.lua`.
- [x] Undoing a create left the new element's id in the `Selection` after the element was
      gone, which inflated the status bar's count. `Board:pruneSelection` drops dead ids
      every frame. (Gating that on `History:getStateToken()` looks tempting and is wrong —
      undo deliberately returns a token the document has already had.)
- [x] `Element.restore` is written but never called — it's waiting on §1. (Became
      `Element.fromData`, which validates rather than trusting the table.)
- [x] `Board.marqueeBase` is set in `beginMarquee` but not initialized in `Board:load`
      alongside `drag`/`resize`/`marquee`. (Both now happen in `Board:setDocument`.)
- [ ] `History` silently drops the oldest command past its 200-entry limit, which makes a
      Composite's partner commands unreachable but not incorrect. Fine — noted so it isn't
      re-discovered as a bug. Note that `getStateToken` inherits the same limit: undoing
      past the point where the saved command was trimmed can't report clean again.
- [ ] Drop `seed()` in [Board.lua](application/Canvas/Board.lua). It hardcodes three demo
      panels. Now unblocked: §2's Panel tool means an empty startup board is no longer a
      dead end, and `File > New` already opens one. Left in for now because it's still the
      quickest way to have something on screen to test against.
---

## Open design questions

Worth settling before the code that depends on them gets written.

1. ~~**Save format**~~ — settled: JSON, one `.grimoire` file per board, written with sorted
   keys and rounded numbers. Per-element files would merge better in git, but they're
   worse to hand-edit and slower to load; revisit only if merge pain shows up in
   practice. Rationale is in CLAUDE.md.
2. **Connectors**: are they elements in the same list (needing endpoint references and a
   deletion rule), or a separate relation table in the document?
3. **Scope of "board"**: one file per board, or one file holding multiple named boards/tabs?
   This decides whether `Board` stays a singleton.
4. **Coordinate units**: the status bar's unexplained `/100` divisor is gone, so nothing
   claims a unit it can't name any more — but nothing declares one either. World units are
   de facto pixels-at-zoom-1 (element default sizes, `RectResize`'s grab margin and the
   grid spacing are all written as if they were). Say so somewhere, or pick a real unit.
