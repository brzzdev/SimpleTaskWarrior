---
name: run-simpletaskwarrior
description: Run, drive, and screenshot the SimpleTaskwarrior macOS app with a scratch Replica and Taskrc. Use to launch the app, check a change in the running app, work a manual test plan, or reproduce a UI or window-restoration bug.
---

# Run SimpleTaskwarrior

The app is native AppKit, driven from the shell by `driver.sh`: System Events for menus and keys, a
compiled CGEvent helper (`mouse.swift`) for clicks, right-clicks and drags, `screencapture` for
evidence. Paths are relative to the repo root; run everything from there.

```bash
D=.claude/skills/run-simpletaskwarrior/driver.sh
$D help
```

## Prerequisites

- `task` 3.5.0 on PATH (`brew install task`), for the fixture.
- The terminal running the agent has Accessibility access (System Settings > Privacy & Security),
  or every `osascript` call fails.

## Run (agent path)

```bash
F="$TMPDIR/stw"                    # any scratch directory
$D fixture "$F"                    # Replica + Taskrc with `size` (S,M,L) and `estimate` UDAs
$D launch                          # `just run`: builds, quits the old dev copy, opens the app
$D open "$F/replica"               # opens the Replica, no panel
$D frame                           # front window to (100,100), 1500×700
$D taskrc "$F/taskrc"              # File > Choose Taskrc… via Go to Folder
$D header Priority                 # toggles a column in the header's context menu
$D click 1100 166                  # left-click in global points; the header row is y=166
$D shot "$F/table.png"             # capture the framed window, then Read the PNG
$D layout "$F/replica"             # the table's autosaved columns and sort
$D relaunch                        # ⌘Q, then launch with no file: restoration only
```

**Look at every screenshot.** The fixture gives 7 Pending rows plus 2 Recurrence instances: an
active task (3), a blocked one (7), one with 2 annotations (4), one `scheduled` 4 minutes out (9),
and one waiting.

**Screenshot pixels to click points:** `shot` captures a region in points, and the PNG holds the
display's pixels for it: the scale is the PNG's width over the capture width (2 on a Retina display,
where the default 1500pt capture is 3000px). With the default frame, a point is
`100 + pixel / scale` on each axis. The Read tool shows a downscaled image and states the original
size; convert through that.

## Gotchas

- **Keystrokes need the app frontmost.** `osascript -e 'tell application "System Events" to
  keystroke …'` goes to the terminal, which is how a Choose Taskrc… panel silently gets nothing.
  The driver's `se` sets `frontmost` inside the `tell process` block every call.
- **The table has no AX columns.** System Events returns nothing for `AXColumn`s, and its `click`
  can't right-click or drag, hence `mouse.swift`. Read the table from screenshots and from `layout`.
- **Menus are driven by type-select**: right-click, type the item's title, Return. Positions of
  context-menu items move with the click point, so don't click them by coordinate. Chained straight
  after `taskrc`, `header` once missed a UDA column; screenshot to confirm, and rerun if it did.
- **`mouse.swift` is linted by the app build.** The SwiftLint build phase covers the whole tree,
  `.claude/` included, strict: a violation there (e.g. `60000` for `60_000`) fails `just run` with
  exit 65 and no error printed. Find it with `just build > log 2>&1; grep ❌ log`.
- **The previous session's Replica windows come back** on launch through window restoration.
  Harmless; `se` acts on the frontmost window, which is the one `open` just brought forward.
- **Autosave is keyed by the standardized path**, which drops `/private` and doubled slashes
  (`$TMPDIR` ends in `/`): `/private/tmp/x` is saved as `replica:/tmp/x/`. `layout` normalises
  its argument to match.
- **`task` creates Recurrence instances only when a report runs**, so the fixture ends with
  `task next`. Without it the Replica has the template and no instances.
- **Stale builds:** `open -a` reuses a running copy; `launch` goes through `just run`, which quits
  the old dev build first.

## Human path

`just run`, then File > Open Replica… (⌘O) and File > Choose Taskrc… (⌥⌘O).
