# How app writes mirror the CLI

Research for [#9](https://github.com/brzzdev/SimpleTaskWarrior/issues/9). The question: exactly what must the app reproduce on each write so that `task` 3.5 cannot tell the app's writes apart from its own?

This builds on [#2](https://github.com/brzzdev/SimpleTaskWarrior/issues/2) (`docs/research/taskchampion-engine.md`: embed TaskChampion, mirror TW semantics in a compatibility layer) and [#3](https://github.com/brzzdev/SimpleTaskWarrior/issues/3) (`docs/research/urgency-taskrc.md`: Taskrc parsing, UDA types, the default config layer).

Sources are pinned to the versions TW 3.5.0 builds against:

- `TW` is [taskwarrior @ v3.5.0](https://github.com/GothenburgBitFactory/taskwarrior/tree/v3.5.0)
- `TC` is [taskchampion @ v3.1.0](https://github.com/GothenburgBitFactory/taskchampion/tree/v3.1.0)

Claims marked *verified* were checked on 2026-09-23 against the installed `task` 3.5.0. Each run used a scratch `TASKDATA`/`TASKRC`, and the `operations`, `tasks` and `working_set` tables were diffed after every CLI command.

## Short answer

Write through TaskChampion's **`Task`** API (`create_task`, `set_value`, `set_status`), the same one TW 3.5 uses, and never through raw `TaskData::update`. That API already gives the app three things: the `modified` stamp, `end` handling on status changes, and adding newly pending tasks to the working set. On top of it, the app adds a small, fixed set of rules, all taken from `Task::validate` and five commands:

1. **Every write:** one `UndoPoint` first. Set `modified` to now. Write `status` last. Remove keys by removing them, never by writing `""`.
2. **Create:** `entry` and `modified` set to now, then `status:pending` (or `recurring`/`rtype:periodic` when `due` + `recur` are set). Then `default.project`, `default.due`, `default.scheduled` and every `uda.<n>.default`, each only when the key is absent.
3. **Tags and dependencies:** write `tag_<t>` and `dep_<uuid>` with the value `"x"`, and keep the legacy `tags`/`depends` mirrors equal to the sorted, comma-joined set, removing them when the set is empty.
4. **Status transitions:** done removes `start` and sets `end`. Delete sets `end` and keeps `start`. Start on a completed or deleted task makes it pending. Back to pending removes `end`. `wait` never changes `status`.
5. **Encodings:** dates are integer epoch-second strings. Durations are ISO 8601 (`PT1H30M`, `P7D`). Numerics are normalised decimals. Annotations are `annotation_<epoch>`, bumped by one second until the key is unique.
6. **Working set:** only ever let `commit_operations` append. Never call `rebuild_working_set`, because renumbering is the CLI's job during `gc`.

With these rules, `task export`, `task info` and every report read an app-written task exactly as they read a CLI-written one. The only remaining differences are in the operation log's ordering and in duplicate `modified` updates. TW never interprets either of those (§8).

## 1. How the CLI writes: the pipeline

Every CLI write goes through one of two functions in [`TW src/TDB2.cpp`](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/TDB2.cpp):

**`TDB2::add`** ([L71-L115](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/TDB2.cpp#L71-L115)):

1. Calls `task.validate(true)`, which fills in defaults (§3).
2. Pushes an `UndoPoint`, via `maybe_add_undo_point`.
3. Calls `replica.create_task(uuid)`.
4. Calls `set_value(k, v)` for every key except `uuid`, `id` and `status`. TW's in-memory task is a `std::map`, so this runs in byte-sorted key order.
5. Calls `set_status(...)` last, "so `tc::Task::set_status` sees complete input".
6. Makes one `commit_operations`.

**`TDB2::modify`** ([L132-L224](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/TDB2.cpp#L132-L224)):

1. `task.setAsNow("modified")`, which overwrites any `modified` the user or a hook set.
2. `task.validate(false)`: the same fix-ups as on add, but no defaults.
3. Pushes an `UndoPoint`.
4. For each key whose value differs from the stored task, calls `set_value`, or `set_value_remove` if the new value is `""`.
5. Removes keys that have disappeared.
6. Calls `set_status` last, and only if the status changed.
7. Makes one `commit_operations`.

`maybe_add_undo_point` ([L256-L261](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/TDB2.cpp#L256-L261)) adds an `UndoPoint` only before the first change of a process. So one `task` command, even one that touches many tasks, is **one undo group**.

The bridge methods `set_value`, `set_value_remove` and `set_status` wrap `tc::Task`, not `TaskData` ([`TW src/taskchampion-cpp/src/lib.rs` L1310-L1350](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/taskchampion-cpp/src/lib.rs#L1310-L1350)). This matters, because `tc::Task` carries behaviour:

| `tc::Task` method | Behaviour the app gets for free | Source |
|---|---|---|
| `set_value(k, v)` | The **first** `set_value` on a `Task` value also writes `modified = now`, unless `k` is `modified` itself. After that, `updated_modified` suppresses further stamps | [TC src/task/task.rs L346-L381](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/task/task.rs#L346-L381) |
| `set_status(s)` | `completed`/`deleted` set `end = now` if there is no `end`. `pending`/`recurring` remove `end` if present. Then it writes `status` | [task.rs L303-L324](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/task/task.rs#L303-L324) |
| `Replica::commit_operations` | Any `status` update from something other than pending/recurring (including absent) **to** pending/recurring appends the task to the working set, unless it is already there | [TC src/replica.rs L355-L389](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/replica.rs#L355-L389), [taskdb/mod.rs L36-L78](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/taskdb/mod.rs#L36-L78) |

`TaskData::update` does none of this. The facade should expose `Task`-level operations only.

## 2. Every write

| Rule | Why | Source |
|---|---|---|
| Push `Operation::UndoPoint` once, at the start of each user action. A multi-task action, such as completing a selection, is one group | Matches `maybe_add_undo_point`, so `task undo` reverts the whole app action, just as it reverts a whole CLI command | TDB2.cpp L256-L261 |
| Set `modified` to the current epoch second | `TDB2::modify` always does. With `tc::Task` it happens on the first `set_value` | TDB2.cpp L134-L135; task.rs L360-L366 |
| Apply `validate`'s status fix-ups (§4): pending → no `end`; completed/deleted → `end` present; `entry` present | `validate(false)` runs on every modify | [Task.cpp L1444-L1595](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1444-L1595) |
| Write `status` last, and only when it changes | `set_status` handles `end` relative to the keys already set; `commit_operations` keys the working-set add on the `status` op | TDB2.cpp L89-L106, L187-L191 |
| Remove a key by removing it (`set_value(k, None)`) | TW's modify path maps `""` to removal | TDB2.cpp L173-L177 |
| Refuse what the CLI refuses: a blank description, `recur` without `due`, removing `due` or `recur` from a recurring task, or setting `end` on a pending task | These are hard errors in the CLI, so an app write that allows them creates a task the CLI would never have produced | [Task.cpp `validate_add` L1422-L1432](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1422-L1432), [CmdModify.cpp `checkConsistency` L111-L126](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/commands/CmdModify.cpp#L111-L126) |
| Validate UDA values against `uda.<n>.values` and the UDA type | The CLI rejects `priority:Q` and `size:007` (*verified*) | [`Task::modify` L1994-L2011](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1994-L2011), `columns/ColType*.cpp` |

`validate` also prints warnings for inverted date pairs (`wait` after `due`, `scheduled` after `due`, and so on). These are warnings only; the CLI still writes the task ([Task.cpp L1564-L1571](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1564-L1571)). The app may warn, but must not block these writes.

## 3. Create

In `Task::validate(true)` order ([Task.cpp L1444-L1595](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1444-L1595)):

| Key | Value | Condition |
|---|---|---|
| `uuid` | New v4 UUID. It is the TC task id, not a property | Always |
| `status` | `pending` | Default |
| `status` | `recurring` | `due` and `recur` are set and there is no `parent`/`template`. This makes it a Recurrence template |
| `rtype` | `periodic` | When `status` is `recurring` and `rtype` is absent |
| `entry` | now (epoch) | Absent or empty |
| `modified` | now | Absent or empty |
| `end` | now | Only when created as `completed`/`deleted` (`task log`) |
| `project` | `default.project` | Key absent, no `parent`, the default is non-empty, and it passes the project column's validation |
| `due` / `scheduled` | `default.due` / `default.scheduled`, converted to an epoch. A duration is added to now; otherwise it is parsed as a date or synonym (`eow`, `tomorrow`) | Same conditions as `project` |
| `<uda>` | The **raw string** of `uda.<uda>.default` | No `parent`, and the task's value is empty. Every config key starting `uda.` and containing `.default` is scanned, including the compiled default layer |

Defaults apply **only on create** (`applyDefault` is `false` in `TDB2::modify`), and never to recurrence instances, which have a `parent`.

*Verified* with `default.project=Inbox`, `default.due=eow`, `uda.area.default=home`, `uda.size.default=3`, `uda.review.default=tomorrow` (where `review` is a date UDA):

```
task add Alpha +home +Work estimate:2h
→ Create; modified=1790179320; area=home; description=Alpha; due=1790549999; entry=1790179320;
  estimate=PT2H; modified=1790179320; project=Inbox; review=tomorrow; size=3;
  tag_Work=x; tag_home=x; tags=Work,home; status=pending
```

Note `review=tomorrow`. **UDA defaults are stored verbatim, even for date and duration UDAs.** `task export` then silently omits the unparseable date (*verified*). Code-wise this is a CLI bug. The app has to choose between byte parity and a usable value (see open questions).

The first `modified` op comes from TC's auto-stamp on the first `set_value`, and the second comes from TW setting `modified` explicitly in key order. TW never interprets this duplicate (§8), so the app need not reproduce it.

`task log` is `add` with `status:completed`. It sets `end = now`, and refuses `recur` and `wait` ([CmdLog.cpp L52-L66](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/commands/CmdLog.cpp#L52-L66); *verified*). A completed task never enters the working set.

## 4. Status transitions

TW 3 stores only `pending`, `completed`, `deleted` and `recurring`. "Waiting" is virtual: `pending` plus `wait` in the future ([`getStatus` Task.cpp L295-L308](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L295-L308); ChangeLog "TW #2554 Remove the waiting state"). `setStatus(waiting)` writes `pending` ([L311-L319](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L311-L319)). A legacy stored `waiting` is read as `pending` ([`textToStatus` L154-L169](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L154-L169)).

| User action | CLI | Keys written (besides `modified`), all *verified* | Source |
|---|---|---|---|
| Complete | `done` (pending or waiting only) | `end=now` if absent; **`start` removed** if present; `status=completed` | [CmdDone.cpp L85-L98](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/commands/CmdDone.cpp#L85-L98) |
| Delete | `delete` (anything not deleted) | `end=now` if absent; `status=deleted`. **`start` is kept** | [CmdDelete.cpp L86-L93](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/commands/CmdDelete.cpp#L86-L93) |
| Start | `start` (not already started) | `start=now`. If completed/deleted: also `status=pending`, and `end` removed | [CmdStart.cpp L83-L96](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/commands/CmdStart.cpp#L83-L96) |
| Stop | `stop` | `start` removed | [CmdStop.cpp](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/commands/CmdStop.cpp) |
| Reopen | `modify status:pending` | `end` removed; `status=pending`. The task is re-added to the working set at the end | `validate` + `set_status` |
| Mark done via modify | `modify status:completed` | `end=now`; `status=completed` | same |
| Wait / unwait | `modify wait:<date>` / `wait:` | only `wait`. **No status write**, in either direction. A wait expiring is not a write: no operations appear when a report runs after it lapses | *verified* |

`journal.time` (default `0`) makes start, stop and done also add an annotation from `journal.time.start.annotation` / `journal.time.stop.annotation` ([CmdStart.cpp](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/commands/CmdStart.cpp), [CmdDone.cpp L96](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/commands/CmdDone.cpp#L96)). The app should honour it if it reads the Taskrc.

**Side effects the CLI chains onto done and delete:**

- **Recurrence instance** (has `parent` and `imask`): `updateRecurrenceMask` sets the template's `mask[imask]` to `-`, `+`, `X` or `W` and modifies the template in the same undo group ([recur.cpp L368-L397](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/recur.cpp#L368-L397)). This runs on every done, delete, start, stop and modify of an instance.
- **Dependency chain repair** (`dependencyChainOnComplete`, [dependency.cpp L113-L154](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/dependency.cpp#L113-L154)): if the completed or deleted task both blocks something and is blocked by something, the CLI offers to rewire the blocked tasks onto its own dependencies. The prompt appears when `dependency.confirmation=1`, the default; with `0` the rewiring happens silently. With no answer, nothing is rewired (*verified*).
- **Deleting a recurring task** optionally deletes its siblings and template, or its children, based on `recurrence.confirmation` (default `prompt`) ([CmdDelete.cpp L104-L150](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/commands/CmdDelete.cpp#L104-L150)). Modify propagates the same way ([CmdModify.cpp L130-L207](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/commands/CmdModify.cpp#L130-L207)).

## 5. Tags, dependencies, annotations

| Thing | Stored key/value | Legacy mirror | Source |
|---|---|---|---|
| Tag `t` | `tag_<t>` = **`"x"`** | `tags` = the tag names, comma-joined in byte order (so `Work` sorts before `home`). Removed when there are no tags | [`addTag` Task.cpp L1175-L1182](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1175-L1182), [`fixTagsAttribute` L1239-L1248](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1239-L1248) |
| Dependency on `u` | `dep_<u>` = **`"x"`** | `depends` = the UUIDs, comma-joined in byte order. Removed when empty | [`addDependency` L991-L1013](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L991-L1013), [`fixDependsAttribute` L1267-L1276](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1267-L1276) |
| Annotation | `annotation_<epoch>` = text. If the key is already taken, the epoch is bumped by one second until it is free | none | [`addAnnotation` L922-L934](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L922-L934) |

- **TC's helpers differ.** `tc::Task::add_tag` and `add_dependency` write `""`, not `"x"`, and `add_annotation` **overwrites** an existing annotation with the same second ([task.rs L416-L443, L535-L539](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/task/task.rs#L416-L443)). For parity the facade should call `set_value("tag_<t>", "x")` directly and do TW's collision bump itself. TC's book says the value "is ignored" ([TC docs/src/tasks.md](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/docs/src/tasks.md)).
- **Validate tags and dependencies before writing.** A tag cannot be synthetic (TC's `Tag` parse rejects uppercase-only synthetic names). A task cannot depend on itself, and the CLI refuses circular dependencies ([L995, L1003-L1006](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L991-L1013)).

**How much the mirrors matter.** TW 3.5 never *reads* `tags`/`depends` from the replica: tags come from `tag_*` and dependencies from `dep_*`. The mirrors are only parsed from imported JSON ([`Task::parse` L525-L546](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L525-L546)). `task info`'s journal explicitly skips `modified`, `tags` and `depends` ([CmdInfo.cpp L598-L602](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/commands/CmdInfo.cpp#L598-L602)).

*Verified*: a task injected with `tag_foo=""`, `dep_<A>=""`, no mirrors and no `modified` exports with `"tags":["foo"]` and `"depends":[…]`, and matches `+foo`. The next CLI tag change then filled in `tags=bar,foo`. So omitting the mirrors would not break the CLI.

They are still cheap and deterministic to keep, and other tools reading the SQLite file (older integrations, TW 2.x-era sync bridges) may rely on them. **Recommendation:** after any tag or dependency change, recompute each mirror from the `tag_*`/`dep_*` keys and write it if it changed, or remove it if the set is now empty. TC's book warns that a list-valued `tags` is last-writer-wins across synced replicas. That is harmless here, because nothing authoritative reads it.

## 6. Value encodings

All *verified* in `tasks.data`. Dates and durations go through `Variant` ([columns/ColTypeDate.cpp](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/columns/ColTypeDate.cpp), [ColTypeDuration.cpp](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/columns/ColTypeDuration.cpp), [ColTypeNumeric.cpp](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/columns/ColTypeNumeric.cpp)).

| Kind | Encoding | Examples |
|---|---|---|
| Date: `due`, `wait`, `scheduled`, `until`, `start`, `end`, `entry`, `modified`, date UDAs | Integer Unix epoch seconds, as a decimal string. Relative inputs resolve in the **local** time zone (`tomorrow` → local midnight). Must lie within TW's `EPOCH_MIN_VALUE`..`EPOCH_MAX_VALUE` | `due:tomorrow` → `"1790204400"`; `due:2026-10-01T09:30` → `"1790843400"` (BST) |
| Duration UDA | ISO 8601, normalised by TW's `Duration`. Months are 30 days and years 365 days | `2h`→`PT2H`, `90min`/`1.5h`→`PT1H30M`, `36h`→`P1DT12H`, `1w`→`P7D`, `1mo`→`P30D`, `1y`→`P365D` |
| `recur` | The **raw** user string, validated as a duration | `recur:weekly` → `"weekly"` ([ColRecur.cpp](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/columns/ColRecur.cpp)) |
| Numeric UDA | Normalised decimal, without trailing zeros | `4.50`→`4.5`, `1e3`→`1000`, `-0.25`; `007` is rejected |
| String / uuid UDA, `project`, `description` | Verbatim. No escaping; the old `&open;`/`&close;` encoding is not applied on the TC path | `desc with [brackets] & "quotes"` stored as-is |
| `priority` | A string UDA from the default layer, restricted to `H`, `M`, `L` or empty | `"H"` |
| Tag / dependency presence | `"x"` | §5 |

The CLI stores `""` for explicitly blanked attributes on **add** (`task add X due: project:` wrote `"due":""`, `"project":""`; *verified*). This comes from `Task::modify`'s blank handling, which keeps the key so that defaults are suppressed ([Task.cpp L1966-L1990](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1966-L1990)). It is an artefact of the CLI parser. The app should simply omit the key; TW reads an empty value and a missing one the same way.

## 7. Working set and IDs

- **Adding to the set.** A task joins the working set when its `status` op moves it into pending/recurring. It goes at index `max(id)+1` ([TC storage/sqlite/inner.rs L420-L433](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/storage/sqlite/inner.rs#L420-L433)), so the app gets this from `commit_operations`. Holes are never reused until a renumbering. A reopened or restarted task gets a new, higher ID (*verified*: completed task `L` → `start` → ID 2).
- **Nothing is removed on write.** A completed or deleted task **keeps its slot and its ID** until the next renumber (*verified*). Until then `task 1 …` still resolves to it ([`TDB2::id` L527-L530](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/TDB2.cpp#L527-L530)).
- **Only the CLI renumbers.** It calls `rebuild_working_set(true)` in `TDB2::gc` before any command with `needs_gc` (reports, `export`, `ids`, …) when `gc=1` ([TDB2.cpp L272-L281](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/TDB2.cpp#L272-L281), [Context.cpp L823-L825](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Context.cpp#L823-L825)). This compacts the set: 1…n in old order, then new pending tasks ([TC taskdb/working_set.rs L9-L80](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/taskdb/working_set.rs#L9-L80)). Write commands (`add`, `done`, `modify`, …) have `_needs_gc = false`. The rebuild writes no operations and no undo point.
- **App rule:** never call `rebuild_working_set`. Not with `renumber=true`, which would move IDs the user just saw in a terminal. And not with `false` either: it is harmless but pointless, because it only nulls slots, which the next CLI `gc` does anyway. The app should show an ID only for a task whose working-set slot holds it *and* whose status is pending or recurring. A completed task still holding a slot is one `task list` away from losing it.
- **Watch for renumbering.** IDs change underneath the app whenever the CLI runs a report. The window has to re-read the working set on replica change, not cache it.

## 8. What the CLI can and cannot observe

TW reads a task only as its property map (`parseTC`, [Task.cpp L721-L739](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L721-L739)). The only view of the operation log is `task info`'s journal (`journal.info=1`). That journal sorts the operations, groups those within one second, and ignores `modified`, `tags` and `depends` ([CmdInfo.cpp L511-L530, L598-L602](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/commands/CmdInfo.cpp#L511-L530)). So none of these need matching:

- the order of `Update` ops within a commit, beyond "status last"
- TW's duplicate `modified` ops
- `old_value == value` no-op updates

What *is* observable: the final property map, and the undo grouping (`task undo` reverts back to the last `UndoPoint`).

## 9. CLI behaviour the app should not copy, or should defer

| Behaviour | Where | Recommendation |
|---|---|---|
| `handleUntil`: deletes pending tasks whose `until` has passed | [recur.cpp L399-L415](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/recur.cpp#L399-L415), on every report | Don't: that is a write on read. Show `until`-expired tasks as expired, and let the CLI delete them |
| `handleRecurrence`: generates Recurrence instances | [recur.cpp L65+](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/recur.cpp#L65), on every report | Out of scope here; needs its own decision (below) |
| `gc` renumbering, `expire_tasks` | TDB2.cpp L272-L284 | Never |
| Verbatim `uda.*.default` for date/duration UDAs | §3 | Decide (below) |
| `""` values for blanked keys on add | §6 | Omit keys instead |
| Hooks (`on-add`, `on-modify`) | [TDB2.cpp L85, L147](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/TDB2.cpp#L85) | Can't run in the sandbox (#2). App writes skip them. Known, unavoidable divergence |
| `updateRecurrenceMask` shadowing bug: when `imask` ≥ `mask.length`, the padded mask goes into a local variable and the template's mask is rewritten unchanged | recur.cpp L380-L391 | Reproduce the observable result (mask unchanged) only if the app edits instances |

## 10. Golden-test recipe

The comparison harness these experiments used works as a test oracle:

1. Create a fresh temp `TASKDATA` and a `TASKRC` with known UDAs and defaults.
2. Perform action *X* with `task`, and dump `tasks.data` and `working_set`.
3. Reset, perform *X* through the facade, and dump again.
4. Compare the property maps (ignoring `modified`/`entry`/`end` values within ±1 s, and UUIDs), the working-set layout, and the number of `UndoPoint`s.

Also run `task export` and `task <uuid> info` over app-written data. The cases from §3 to §7 make the table: add with and without defaults, tags, deps, done-while-started, delete-while-started, start-completed, reopen, wait/unwait, annotate twice in one second, and denotate.

## Open questions

1. **Date/duration UDA defaults:** copy the CLI's verbatim write (`review=tomorrow`, invisible to `export`), or resolve the default to an epoch / ISO duration, which is more useful but differs from the CLI? Resolving needs TW's date-synonym parser (`eow`, `tomorrow`, …) in the app. That parser is also needed for `default.due`/`default.scheduled`.
2. **Recurrence writes:** does the app generate instances (`handleRecurrence` plus `recurrence.limit`) or leave that to the CLI? And does completing or deleting an instance update the template `mask` and offer the sibling/template cascade that `recurrence.confirmation` controls?
3. **Dependency chain repair:** when the user completes a task in the middle of a chain, does the app prompt (as `dependency.confirmation=1` does), repair silently, or never repair?
4. **Showing IDs for completed tasks** still in the working set before a CLI `gc`: hide them (recommended), or show them because `task 1` still resolves?
5. **Date-synonym parity:** entering relative dates (`eow`, `som`, `weekstart`-aware) in the app needs the same resolution as TW's `Datetime`, including the local time zone. Is that a native picker only, or text entry with TW semantics?
