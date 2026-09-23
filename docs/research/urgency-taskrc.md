# Urgency and Taskrc semantics in Taskwarrior 3.5

Research for [#3](https://github.com/brzzdev/SimpleTaskWarrior/issues/3). The question: what must the app implement to match Taskwarrior 3.5 for Urgency and Taskrc handling?

Sources are pinned to the exact versions TW 3.5.0 builds against:

- `TW` is [taskwarrior @ v3.5.0](https://github.com/GothenburgBitFactory/taskwarrior/tree/v3.5.0)
- `LS` is [libshared @ 8693555](https://github.com/GothenburgBitFactory/libshared/tree/86935551e0faa56ed14c52802a23280a593df338), the submodule TW 3.5.0 pins. It holds the taskrc parser.
- `TC` is [taskchampion @ v3.1.0](https://github.com/GothenburgBitFactory/taskchampion/tree/v3.1.0), the crate version in TW 3.5.0's `Cargo.lock`.

The behaviour was also checked against the installed `task` 3.5.0, using a throwaway `TASKDATA`/`TASKRC`. Those runs are labelled *verified* below.

## 1. Urgency

### Formula

Urgency is a `float` sum, computed in [`Task::urgency_c`, TW src/Task.cpp L1710-L1802](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1710-L1802):

```
U = Σ (term_i × coefficient_i)                  over the 10 built-in terms, when |coefficient_i| > 1e-6
  + Σ coefficient_k                              over every matching urgency.user.* / urgency.uda.* key
then, if urgency.inherit is on and the task is blocking:
  U = max(U, max urgency of the tasks it blocks) + 0.01
```

If a coefficient has a magnitude of 1e-6 or less, the term is skipped entirely (`epsilon`, [L66](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L66)). Urgency is never stored. `task export` adds it with `decorate` ([L896-L897](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L896-L897)).

### Built-in terms ([TW src/Task.cpp L1835-L1943](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1835-L1943))

| Key | Default | Term value |
|---|---|---|
| `urgency.active.coefficient` | 4.0 | 1 if a `start` key is present |
| `urgency.age.coefficient` | 2.0 | No `entry` → 1. Otherwise `age = trunc((now − entry) / 86400)` in whole days. If `urgency.age.max == 0` or `age > max`, the term is 1; otherwise it is `age / max` |
| `urgency.age.max` | 365 | (the cap for the age term, not a coefficient) |
| `urgency.annotations.coefficient` | 1.0 | 0, 1, 2 and ≥3 annotations → 0, 0.8, 0.9, 1.0 |
| `urgency.blocked.coefficient` | −5.0 | 1 if `is_blocked` (see below) |
| `urgency.blocking.coefficient` | 8.0 | 1 if `is_blocking` |
| `urgency.due.coefficient` | 12.0 | No `due` → 0. With `d = (now − due) / 86400.0` (fractional): `d ≥ 7` → 1.0; `d ≥ −14` → `(d + 14) × 0.8 / 21 + 0.2`; otherwise 0.2. So a due date anywhere in the future still scores at least 0.2 |
| `urgency.project.coefficient` | 1.0 | 1 if a `project` key is present |
| `urgency.scheduled.coefficient` | 5.0 | 1 if `scheduled` < now, strictly in the past |
| `urgency.tags.coefficient` | 1.0 | 0, 1, 2 and ≥3 real tags (`tag_*` keys) → 0, 0.8, 0.9, 1.0. Synthetic tags don't count ([`getTagCount` L1101-L1109](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1101-L1109)) |
| `urgency.waiting.coefficient` | −3.0 | 1 if status is `pending` **and** `wait` > now ([`is_waiting` L513-L521](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L513-L521)) |
| `urgency.inherit` | 0 (bool) | See the inherit rule above. Recursive: each blocked task's urgency uses the same rule ([L1794-L1800, L1820-L1832](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1794-L1832)). Candidates are pending-set tasks, not completed or deleted, that list this task in `dep_*` ([L1087-L1097](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1087-L1097)). The `+0.01` always applies, because `max ≥ prev`. The man page advises zeroing the blocked and blocking coefficients when this is on ([taskrc.5 L1166-L1175](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/doc/man/taskrc.5.in#L1166-L1175)) |

The defaults come from the compiled-in `configurationDefaults` string ([TW src/Context.cpp L186-L199](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Context.cpp#L186-L199)), which is parsed *before* the user's taskrc ([L516-L520](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Context.cpp#L516-L520)). An empty taskrc therefore still carries every coefficient in this table, plus `urgency.user.tag.next.coefficient=15.0`, the `priority` UDA and its three coefficients (§2). **The app must ship this same default layer and overlay the taskrc on top.**

A key with no value (`urgency.due.coefficient=`) overrides its default with an empty string, and `getReal("")` returns 0 ([LS Configuration.cpp L300-L307](https://github.com/GothenburgBitFactory/libshared/blob/86935551e0faa56ed14c52802a23280a593df338/src/Configuration.cpp#L300-L307)). Numbers are parsed with `strtod`, so trailing junk is ignored and a non-number reads as 0. Booleans are true only for `true`, `1`, `y`, `yes` or `on`, compared case-insensitively ([L310-L325](https://github.com/GothenburgBitFactory/libshared/blob/86935551e0faa56ed14c52802a23280a593df338/src/Configuration.cpp#L310-L325)).

### Blocked and blocking

TW sets these flags in [`dependency_scan`, TW src/TDB2.cpp L540-L567](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/TDB2.cpp#L540-L567). For each task A with a `dep_<B>` key: if **both** A and B are in the loaded set and **neither** is `completed` or `deleted`, then A is blocked and B is blocking. The loaded set is the working set ([L319-L340](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/TDB2.cpp#L319-L340)), or all tasks for `all_tasks()`. A dependency on a `recurring` template therefore still blocks.

TaskChampion's own `is_blocked`/`is_blocking` differ slightly: they treat a dependency as unresolved only when its status is exactly `pending` ([TC src/replica.rs L189-L243](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/replica.rs#L189-L243)). The app should follow TW's rule.

### User and UDA coefficients ([TW src/Task.cpp L1744-L1792](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1744-L1792))

Every config key starting `urgency.user.` or `urgency.uda.` is loaded into `Task::coefficients` ([TW src/Context.cpp L1123-L1127](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Context.cpp#L1123-L1127)). The name is whatever sits between the prefix and the **first** `.coefficient`. A matching key adds its coefficient once, as a flat amount, not multiplied by a term:

| Key | Matches when |
|---|---|
| `urgency.user.project.<p>.coefficient` | `project == p`, or `project` starts with `p + "."` (subprojects). So `Foo` matches `Foo.bar` but not `Foobar` (*verified*) |
| `urgency.user.tag.<t>.coefficient` | `hasTag(t)`, which **includes synthetic tags** whenever `t` starts with an uppercase letter: `OVERDUE`, `DUE`, `TODAY`, `WEEK`, `BLOCKED`, `READY`, `ACTIVE`, `WAITING` and so on ([`hasTag` L1121-L1167](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1121-L1167)). `urgency.user.tag.OVERDUE.coefficient=7` works (*verified*). Default: `next` = 15.0 |
| `urgency.user.keyword.<k>.coefficient` | `description` contains `k` as a plain, **case-sensitive** substring. No regex, and annotations are not searched (*verified*: `Bug` ≠ `bug`) |
| `urgency.uda.<name>.coefficient` | The task has the key `<name>`. Any value, including `priority` |
| `urgency.uda.<name>.<value>.coefficient` | `get(name) == value`, split at the first `.`, so the value may contain dots. Defaults: `priority.H` = 6.0, `priority.M` = 3.9, `priority.L` = 1.8 |

Because synthetic tags feed the tag coefficients, Urgency can depend on the date settings. Those depend on `due`, `weekstart` and the current time (§4).

### Worked checks (*verified* against `task export`)

- Project `Foo.bar` (+1), active (+4), 1 annotation (+0.8), 2 tags (+0.9), due in 0.298 days (+12 × 0.722 = 8.664), blocking (+8), `size` UDA present (+1), keyword `bug` (+3), `urgency.user.project.Foo` (+4). Total 31.3639.
- A waiting task that is also blocked scores −3 − 5 = −8.
- With `urgency.inherit=1` and the blocked/blocking coefficients at 0: the blocked child scores 15.8, and the parent blocking it scores 15.81.

## 2. UDAs

### Definition keys

| Key | Meaning |
|---|---|
| `uda.<name>.type` | `string`, `numeric`, `date`, `duration` or `uuid`. Any other non-empty value is a fatal config error. An empty value means "no UDA", which is how a user removes the default `priority` ([TW src/columns/Column.cpp L220-L259](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/columns/Column.cpp#L220-L259)) |
| `uda.<name>.label` | Column heading |
| `uda.<name>.values` | Comma-separated list of allowed values. A trailing empty entry (`H,M,L,`) permits blank. The list order is also the **sort order, highest first** (`Task::customOrder`, [Context.cpp L1097-L1104](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Context.cpp#L1097-L1104)). Validation applies to string, numeric, date and duration, but not uuid ([ColUDA.cpp](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/columns/ColUDA.cpp)) |
| `uda.<name>.default` | Applied on add when the task has no value for the UDA ([Task.cpp L1538-L1557](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1538-L1557)) |
| `uda.<name>.indicator` | Display glyph only |

A UDA exists once any `uda.<name>.*` key exists and has a non-empty type ([Column.cpp L196-L217](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/columns/Column.cpp#L196-L217)). The name runs up to the first `.` after `uda.`. A UDA named after a core attribute (`uda.due.type=…`) is a fatal error (*verified*).

The default layer defines `priority` as a UDA: `type=string`, `label=Priority`, `values=H,M,L,` ([Context.cpp L221-L229](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Context.cpp#L221-L229)). In TW 3, priority is a UDA, not a core attribute.

The man page documents all of this in [taskrc.5 L1390-L1440](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/doc/man/taskrc.5.in#L1390-L1440).

### How attributes appear in TaskChampion

A task is a flat `String → String` map ([TC docs/src/tasks.md](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/docs/src/tasks.md)). TC's known keys are `description`, `due`, `end`, `entry`, `modified`, `priority`, `start`, `status` and `wait`, plus the prefixed keys `tag_<t>`, `annotation_<epoch>` and `dep_<uuid>` ([TC src/task/task.rs L49-L61, L573-L578](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/task/task.rs#L49-L61)). **Every other key is a UDA** to TC ([`get_user_defined_attributes` L264-L269](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/task/task.rs#L264-L269)). That includes TW's own core attributes that TC doesn't know about, such as `project`, `scheduled`, `until`, `recur`, `mask`, `imask`, `parent`, `rtype` and `template`. Note that TC treats `priority` as known, while TW treats it as a UDA.

Values are stored as TW writes them. This is what the SQLite `tasks.data` column shows (*verified*):

| TW type | Stored as | Example |
|---|---|---|
| date (core or UDA) | Unix epoch seconds as a decimal string | `"review":"1790809200"` |
| duration UDA | ISO-8601 duration | `"estimate":"PT2H"` |
| numeric UDA | Decimal string | `"size":"3"` |
| string / uuid UDA | The raw string | `"area":"home"` |

TW 3.5 also writes legacy mirrors next to the prefixed keys: `"tags":"a,b"` and `"depends":"<uuid>,…"` ([`fixTagsAttribute` Task.cpp L1239-L1247](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1239-L1247)). It reads tags and dependencies from `tag_*`/`dep_*` when loading from TC ([`parseTC` L721-L738](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L721-L738)).

A key that is neither core nor defined in the taskrc is an **orphan**. TW preserves it untouched and exposes it through `+ORPHAN` ([`getUDAOrphans` L1302-L1310](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1302-L1310)). The same attribute can be a UDA in one taskrc and an orphan in another, because the replica doesn't record which it is. `urgency.uda.<name>.*` still matches orphans, since `has()` and `get()` read the raw map.

## 3. Taskrc syntax

The parser is [`Configuration::parse`/`load`, LS src/Configuration.cpp L128-L254](https://github.com/GothenburgBitFactory/libshared/blob/86935551e0faa56ed14c52802a23280a593df338/src/Configuration.cpp#L128-L254). It is documented in [taskrc.5 L66-L116](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/doc/man/taskrc.5.in#L66-L116).

The parser handles each line as follows:

1. **Comments.** Everything from the first `#` to the end of the line is dropped, even inside a value. There is no escaping: `nag=has # hash` → `has` (*verified*). Blank lines are skipped.
2. **`key = value`.** The line splits at the **first** `=`, and both sides are trimmed: `a=b=c` → key `a`, value `b=c` (*verified*). There are no line continuations. Two transforms then apply to the value:
   - `Path::expand` ([LS src/FS.cpp L343-L419](https://github.com/GothenburgBitFactory/libshared/blob/86935551e0faa56ed14c52802a23280a593df338/src/FS.cpp#L343-L419)) runs on **every value**, not just paths. It expands a leading `~` or `~user` (`$HOME`, then `getpwuid`) and every `$NAME` (`[A-Za-z0-9_]+`) from the environment. An unset variable becomes the empty string.
   - `json::decode` then turns `\t`, `\uNNNN` and similar into real characters (*verified*).
3. **Last write wins.** Keys go into one flat map, in file order, and includes are processed inline at their position. A later line overrides an earlier one, and the file overrides the compiled defaults.
4. **Includes.** Any line with no `=` that *contains* `include` is an include, and the path is whatever follows the substring. `xxincludeyy f` tries to include `yy f` (*verified*). The path is `~`/`$VAR`-expanded, then resolved in this order:
   1. an absolute path is used as-is
   2. relative to the **CWD**
   3. relative to the **directory of the including file**, after `realpath`
   4. relative to each search path, where TW passes only `TASK_RCDIR` (e.g. `/opt/homebrew/share/doc/task/rc`)

   If the file isn't found, or can't be read, parsing fails fatally. Nesting deeper than 10 levels is fatal, and a nested file resolves relative to *its own* directory (*verified*).
5. **Anything else** (no `=` and no `include`) is fatal: `Malformed entry '<line>' in config file.` (*verified*).

**Per-context overrides.** `Configuration::get` first looks for `context.<active>.rc.<key>`, where `<active>` is the value of the `context` key, and falls back to `<key>` ([LS Configuration.cpp L257-L286](https://github.com/GothenburgBitFactory/libshared/blob/86935551e0faa56ed14c52802a23280a593df338/src/Configuration.cpp#L257-L286)). The named urgency coefficients therefore change with the active context (*verified*: `context=work` plus `context.work.rc.urgency.project.coefficient=50` gave urgency 50). `urgency.user.*`/`urgency.uda.*` keys are *discovered* only under their bare names, but each value is then read through the same context lookup.

**CLI-only overrides** (`rc:<file>`, `rc.<key>=<value>`, `TASKRC`, `TASKDATA`, the XDG lookup) are process inputs ([TW src/Context.cpp L466-L552](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Context.cpp#L466-L552)). The app can't see them, and they don't apply to it.

### What `include` means under the sandbox

A security-scoped bookmark grants the one file. Include targets fall into three groups:

- **Bundled files under `TASK_RCDIR`** (`*.theme`, `holidays.*.rc`). These set only `color.*`, `holiday.*` and `rule.precedence.color` keys, as seen in the installed set, so they can't change Urgency or UDAs. The app can **skip them safely**.
- **User files next to the taskrc, or anywhere else.** These can hold UDAs and coefficients, and the file bookmark doesn't cover them. The app can resolve the path, but reading it needs a second grant. Options: bookmark the taskrc's *folder* instead of the file (covers the common `~/.config/task/*.rc` layout), or ask the user for each unreadable include with an open panel pointed at the resolved path, storing one bookmark per include.
- **CWD-relative includes.** For a GUI app these are meaningless: a launched app's CWD is `/`, and the CLI's depends on the shell. The app should ignore that rule, and warn if an include only resolved that way.

Expansion also differs in the sandbox:

- `$HOME`/`NSHomeDirectory()` is the **container** path, so `~` must be expanded to the real home (`getpwuid(getuid())->pw_dir`).
- A GUI app's environment lacks the user's shell variables (`$XDG_CONFIG_HOME` and others), so a `$VAR` in an include path or value expands differently from the CLI.

## 4. Other taskrc keys that change semantics

These keys matter to the app. Keys that affect only reports, colour, verbosity, sync or the CLI parser are left out. The full set of keys TW reads is available with `grep config.get src/`.

| Key (default) | Effect | Relevance |
|---|---|---|
| `context` (unset) + `context.<n>.rc.*` | Selects per-context overrides of any key, including coefficients. `context.<n>.read`/`.write` hold the filter and default modifications | Urgency differs per active context. `task context <n>` **rewrites the taskrc** |
| `due` (7) | Days ahead within which a task counts as `+DUE` ([Task.cpp L340](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L340)) | Feeds `urgency.user.tag.DUE` |
| `weekstart` (sunday) | Must be Sunday or Monday, otherwise fatal ([Context.cpp L1085-L1089](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Context.cpp#L1085-L1089)). Sets the bounds of `+WEEK` and the week-relative date names | Synthetic tags; date entry |
| `dateformat`, `dateformat.*`, `date.iso` | Parsing of CLI date input and display | Display only, if the app uses native pickers |
| `default.project`, `default.due`, `default.scheduled`, `uda.<n>.default` | Applied when a task is added without that attribute ([Task.cpp L1510-L1557](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1510-L1557)) | App-created tasks should match the CLI |
| `search.case.sensitive` (1), `regex` (1) | CLI filter matching | Only if the app mirrors CLI search |
| `recurrence` (1), `recurrence.limit` (1) | Whether this client generates recurrence instances, and how many pending instances ahead ([recur.cpp L68](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/recur.cpp#L68)) | Recurrence behaviour |
| `gc` (1) | Renumbering and working-set rebuild | IDs shown by the app |
| `urgency.*` | §1 | Urgency |
| `uda.*` | §2 | UDAs |
| `data.location` | Replica path | Ignored: the window already has its replica |
| `report.*` | Reports | Out of scope by design |

## Open questions

- Whether the app honours the active `context`: its `context.<n>.rc.*` coefficient overrides, and its read filter.
- How include grants work: bookmark the folder, or one bookmark per include.
- Whether app writes should keep the legacy `tags`/`depends` mirrors that TW 3.5 writes.
- Whether the app watches the taskrc for changes, since `task context` and `task config` rewrite it.
