# TODO

Working plan for Grimoire. Sections are roughly in dependency order — §0 and §1 unblock
most of what follows. Within a section, items are ordered so the earlier ones make the
later ones cheap.

See [CLAUDE.md](CLAUDE.md) for the architecture this plan assumes. Anything here that
changes an architectural rule should update CLAUDE.md in the same change.

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
- [ ] **Atomic writes.** `saveTo` opens the target directly, so a write that dies partway
      truncates the user's only copy. Write to a temporary file and swap. Note that
      `os.rename` won't overwrite an existing file on Windows, so this needs care to not
      end up worse than what it replaces.
- [ ] The open/save-as dialogs are only smoke-tested as far as "the dialog opens without
      an argument error"; the callback paths were exercised with the dialog stubbed. Walk
      them once by hand with real clicks.
- [ ] Recent files list, persisted to the save directory.
- [ ] Autosave / crash recovery (defer until the format is stable).

---

## 2. Element authoring — there is currently no way to create or delete anything

`AddElement` exists as a command but is only ever called from `seed()`. Nothing deletes.
This is the shortest path from "demo" to "usable".

- [ ] Create: double-click empty canvas, and/or a right-click context menu (§4), and/or a
      toolbar palette. Route through `Document:execute(AddElement.new(...))` so it undoes.
- [ ] `commands/RemoveElements.lua` — takes an id list, stores each removed element *and
      its index* so revert restores exact z-order (`Document:remove` already returns both).
      Wire to Delete/Backspace in `Board:keypressed` and to `Edit > Delete`.
- [ ] Duplicate (Ctrl+D) — offset copy, new ids, selection follows the copies.
- [ ] Copy/cut/paste (Ctrl+C/X/V) with an in-app clipboard; paste at pointer. Cross-process
      paste via `love.system.setClipboardText` using the §1 serializer is a nice follow-on.
- [ ] `Edit` menu items currently `print()` — wire them to the same actions so menu and
      keyboard share one code path.
- [ ] Z-order commands: bring to front / send to back / forward / backward. `ReorderElement`
      already covers the mechanics; this is a command wrapper plus menu items.

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
      the predicate already exists), shortcut hints in the right margin, hover-to-switch
      between open top-level menus, click-outside-to-close, keyboard navigation.
- [ ] `View` menu is stubbed: Zoom In / Zoom Out / Reset Zoom need real `Canvas` calls (§6).
- [ ] `Help > About` / `Documentation` — an about dialog once §4's modal exists.
- [ ] The status bar refresh button prints and does nothing — give it a job or remove it.
- [ ] Status bar reads `("X: %.2f, Y: %.2f"):format(worldX/100, worldY/100)`
      ([UI.lua:187](application/UI/UI.lua#L187)). The `/100` is an unexplained unit
      conversion with no unit shown. Name the unit or drop the divisor.
- [ ] Toolbar / element palette down one side, once there's more than one element type.

---

## 5. More element types

Adding a type is a file in `application/Canvas/elements/` plus one `ElementRegistry:register`
call in [Board.lua:28](application/Canvas/Board.lua#L28). `PanelElement` is the template;
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

- [ ] Keyboard zoom: Ctrl+`+` / Ctrl+`-` / Ctrl+0 reset — shared with the `View` menu.
- [ ] Zoom to fit / zoom to selection — compute the content bounding box
      (`lib/util/math/BoundingBox.lua` exists and looks unused for this).
- [ ] Space+drag pan, and trackpad two-finger pan (`wheelmoved` with an x delta is
      currently ignored — [Canvas.lua:141](application/Canvas/Canvas.lua#L141) bails on
      `y == 0`).
- [ ] Snap-to-grid on move/resize, with a modifier to bypass, plus alignment guides against
      neighbouring elements.
- [ ] Minimap / overview, once boards get large enough to get lost in.
- [ ] Persist pan/zoom per board — but as view state in a sidecar/preferences file, not in
      the board file (same reasoning that keeps `Selection` out of `Document`).

---

## 7. Selection and arrangement

- [ ] Select all (Ctrl+A), deselect (Escape), invert.
- [ ] Arrow-key nudge, Shift+arrow for a coarse step — reuses `MoveElements` as-is.
- [ ] Group resize: `Board:mousepressed` deliberately narrows a resize gesture to a single
      element ([Board.lua:225](application/Canvas/Board.lua#L225)). Multi-resize needs a
      selection bounding box with its own handles and proportional per-element scaling.
- [ ] Align / distribute (left, center, right, top, middle, bottom, spacing) — a `Composite`
      of `MoveElements`.
- [ ] `Selection:list()` returns ids in unspecified (hash) order. Fine for move/raise today;
      anything order-sensitive (copy/paste ordering, align, serialization of a selection)
      must sort by document index rather than assume.
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
- [ ] The selection outline pulses off `os.clock()`
      ([Board.lua:113](application/Canvas/Board.lua#L113)) — wall-clock, and it allocates a
      lerped `Color` per frame. Move to accumulated `dt` and hoist the allocation.
- [ ] Hover affordance on elements (subtle outline before selection).

---

## 9. Performance (not urgent — revisit when boards get big)

- [ ] Cull elements outside the viewport in `Board:draw`.
- [ ] `Document:indexOf` and `Document:remove` are O(n) linear scans, and `raiseAllToFront`
      calls them in a loop — O(n²) on a large multi-select drag. Fine at three elements;
      measure before optimizing.
- [ ] Spatial index for hit testing if `handleAt`'s front-to-back scan shows up in a profile.
- [ ] `Selection:count()` iterates the whole set every frame from `updateStatusBar`. Cache it.

---

## 10. Testing and tooling

CLAUDE.md documents the scripted-smoke-test workflow: temporarily edit `love.update` in
`main.lua`, dispatch synthetic input, print PASS/FAIL, then revert. It works, but the
"then revert" step is exactly the failure mode §0 is cleaning up.

- [ ] A dedicated test entry point — `love . test <name>` loading `tests/<name>.lua` — so
      test scaffolding lives in tracked files instead of being pasted into and scrubbed
      from `main.lua`.
- [ ] Headless-ish unit tests for the pure modules that need no `love`: `History`,
      `Document`, `Selection`, the commands, the §1 serializer. These are plain Lua and
      testable without a window.
- [ ] Round-trip property test for §1: random board → save → load → identical. §1 was
      verified with the throwaway `main.lua` scaffolding this section is trying to
      abolish, so those ~47 assertions no longer exist anywhere — they're the obvious
      first thing to land in `tests/`.
- [ ] Undo/redo fuzz: random command sequence, undo everything, assert the document matches
      its starting state exactly. This is the invariant the whole command design rests on.
- [ ] GitHub Actions running whatever of the above runs headless.

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

- [ ] `ApplicationManager:update` updates `UI`, `TextEditSession` and `BoardFile`;
      `Canvas` and `Board` get no `dt`, so nothing on the board can animate. Add the calls
      when something needs them.
- [ ] `Canvas:mousemoved` returns nothing while panning — it doesn't consume, which is
      currently harmless because `mousemoved` is broadcast anyway, but it's inconsistent
      with every other handler.
- [ ] `Board:mousepressed` consumes button 1 unconditionally, including clicks that only
      started a marquee on empty canvas. Correct today; worth remembering if another
      subscriber ever wants a look at background clicks.
- [x] `Element.restore` is written but never called — it's waiting on §1. (Became
      `Element.fromData`, which validates rather than trusting the table.)
- [x] `Board.marqueeBase` is set in `beginMarquee` but not initialized in `Board:load`
      alongside `drag`/`resize`/`marquee`. (Both now happen in `Board:setDocument`.)
- [ ] `History` silently drops the oldest command past its 200-entry limit, which makes a
      Composite's partner commands unreachable but not incorrect. Fine — noted so it isn't
      re-discovered as a bug. Note that `getStateToken` inherits the same limit: undoing
      past the point where the saved command was trimmed can't report clean again.
- [ ] Drop `seed()` in [Board.lua](application/Canvas/Board.lua). It hardcodes three demo
      panels. It was going to go once §1 could open a real board, but §2 is the real
      blocker: with no way to create an element, dropping it leaves an empty app. `File >
      New` already opens a genuinely empty board, so this only affects startup.
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
4. **Coordinate units**: the status bar divides world coordinates by 100, implying a unit
   that isn't defined anywhere. Define it, or work in pixels and say so.
