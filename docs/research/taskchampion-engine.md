# Choosing the sandboxed TaskChampion engine

Research for [#2](https://github.com/brzzdev/SimpleTaskWarrior/issues/2). Question: how should a sandboxed macOS app (App Store and Developer ID) read and write a TW3 Replica without corrupting its operation log, while the `task` CLI works on the same Replica?

Sources are pinned to TaskChampion `v3.1.0` (the version Taskwarrior 3.5.0 links) and Taskwarrior `v3.5.0` unless noted. The experiments were run on 2026-09-23 against Taskwarrior 3.5.0 (Homebrew), macOS 27, with `TASKDATA` pointed at a scratch directory.

## Recommendation

Embed the `taskchampion` crate (3.1.x, `default-features = false`, `storage-sqlite` only) behind a small app-shaped Rust facade crate, and expose it to Swift through **UniFFI**. Ship it as an arm64 static-library xcframework consumed by one SPM module. Link that module against the **system `libsqlite3`** rather than TaskChampion's `bundled` SQLite, so the process holds exactly one copy of SQLite.

- **Why not the CLI:** a bundled `task` gives exact CLI semantics for free. But every read becomes a process spawn and a JSON parse, fine-grained undo is impossible, and the app would ship a C++/CMake/Rust build and hooks it cannot run inside the sandbox. It is the fallback if the TW-compatibility layer (below) proves too costly.
- **Why not direct SQLite:** the schema is explicitly not a public API. A write has to keep `tasks`, `operations`, `working_set` and the undo points consistent within one transaction. That is TaskChampion's job, and redoing it by hand is the "corrupting the operation log" failure the ticket fears.
- **Main cost:** TaskChampion is the storage layer, not Taskwarrior. The app has to reproduce the write-side conventions `task` applies on top of it (see [Taskwarrior semantics TaskChampion does not provide](#taskwarrior-semantics-taskchampion-does-not-provide)).

## Does upstream require going through the CLI?

No. Upstream recommends the library.

- Taskwarrior's developer docs: "Other applications, besides Taskwarrior, can use TaskChampion to manage tasks. Taskwarrior is just one application using the TaskChampion interface." ([`doc/devel/contrib/rust-and-c++.md`](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/doc/devel/contrib/rust-and-c++.md))
- Maintainer Dustin Mitchell (djmitche), answering exactly this question for TW 3.0: "The preferred way to interact with the taskdb is to use taskchampion as a library. The DB schema isn't considered a public API, and will probably change a bit … Ideally, your app would have its own Taskchampion replica, and sync that replica with the replica used by Taskwarrior, instead of both addressing the same replica. But, both using the same replica should also work." ([discussion #3381](https://github.com/GothenburgBitFactory/taskwarrior/discussions/3381))
- The TaskChampion book lists Rust as the "primary public API". It points C/C++ users to wrapping it with a tool like cxx, as Taskwarrior does in `src/taskchampion-cpp`. ([`docs/src/usage.md`](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/docs/src/usage.md))
- The crate docs name "user interfaces for task management, such as mobile apps" as an intended use. ([`src/crate-doc.md`](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/crate-doc.md))

The maintainer's "ideally … its own replica, and sync" does not fit this app, because the product is a window on *the* Replica the CLI uses. Upstream says sharing one works, and the locking below backs that up.

**Prior art:** [Taskchamp](https://github.com/marriagav/taskchamp) (MIT, on the App Store for iOS and iPadOS, and on Apple-silicon Macs as an iPad app) links TaskChampion as a Rust static-library xcframework built from a private `task-champion-swift` repo ([`scripts/build_taskchampion_swift.sh`](https://github.com/marriagav/taskchamp/blob/main/scripts/build_taskchampion_swift.sh)). It syncs its own replica instead of sharing the CLI's.

## Why direct SQLite is unsafe

What the CLI actually writes (experiment: `task add … +home due:tomorrow`, `annotate`, `done`, then a dump of `taskchampion.sqlite3`):

- Five tables: `tasks(uuid, data JSON)`, `operations(id, data JSON, synced, uuid VIRTUAL)`, `working_set`, `sync_meta`, and `version` (currently `0|0|2`).
- Each `task` command appends an `"UndoPoint"`, a `Create`, then one `Update{uuid, property, old_value, value, timestamp}` per property. The same change is applied to the `tasks` row in the same transaction. This matches the model in the book: "Each operation is added to the list of operations in the storage, and simultaneously applied to the tasks in that storage." ([`taskdb.md`](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/docs/src/taskdb.md), [`storage.md`](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/docs/src/storage.md))
- Undo and sync both depend on those operations: `old_value` must match exactly, or [`commit_reversed_operations`](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/replica.rs#L430) refuses. Sync converts unsynced operations and drops undo points.
- The schema changes between releases. Upgrade `0.2` rewrote the `operations.uuid` virtual column because its `json_extract` syntax broke on SQLite 3.50.4 ([`schema.rs`](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/storage/sqlite/schema.rs#L109)).

Hand-written SQL would have to reproduce all of this and track every future schema change. Read-only SQL would be safe, but it would still couple the app to a non-public schema.

## Locking, WAL and the sandbox

**Upstream facts:**

- `SqliteStorage` opens `<dir>/taskchampion.sqlite3`, sets `PRAGMA journal_mode=WAL`, and runs a schema upgrade when opened read-write. Every storage transaction is `BEGIN IMMEDIATE`. ([`inner.rs` L60-L117](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/storage/sqlite/inner.rs#L60-L117))
- A regression test covers two writers on the same DB: the second must wait for the first rather than fail with `SQLITE_BUSY` (`test_concurrent_access`, same file).
- Taskwarrior opens the Replica read-write only when a command writes, or when `gc` or a recurrence update is due ([`Context.cpp` L638-L642](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Context.cpp#L638-L642)).
- SQLite: "All processes using a database must be on the same host computer; WAL does not work over a network filesystem." Opening a WAL database needs write access to the `-shm` file, or to the directory if `-shm` does not exist yet. ([sqlite.org/wal.html](https://sqlite.org/wal.html))

**Experiments** (another process holds `BEGIN IMMEDIATE`, then `task add` runs):

| Lock held | Result |
| --- | --- |
| 2 s | `task add` waited, then succeeded (exit 0, 1.5 s) |
| 7 s | `task add` failed after 5.2 s: `database is locked: Error code 5` (exit 2) |
| 3 s, `task count` (read) | returned at once (0.03 s); WAL readers don't block |

The CLI waits about 5 s for a lock (rusqlite calls `sqlite3_busy_timeout(db, 5000)` on every connection it opens, [`inner_connection.rs` L118](https://github.com/rusqlite/rusqlite/blob/v0.40.2/src/inner_connection.rs#L118)), then fails. **Rule for the app: never hold a TaskChampion transaction across UI work or an `await`.** Build `Operations` in memory and commit them in one short `commit_operations` call. TaskChampion's API already works this way.

**Sandbox coverage:** "When the URL your app receives from a standard user interface interaction represents a folder, the operating system extends your app's sandbox to items within that folder, and recursively in nested folders". A stored `.withSecurityScope` bookmark restores that after `startAccessingSecurityScopedResource()` ([Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)). The Replica is a folder, and the `-wal` and `-shm` files are created as siblings inside it, so a folder bookmark covers them. The `NSIsRelatedItemType` / file-presenter dance is only needed when a single *file* is granted. SQLite locks are POSIX advisory locks on those files, which the sandbox does not partition, so the app and an unsandboxed `task` coordinate normally. **Still to confirm:** a signed, sandboxed build locking against the CLI. That belongs in the first engine spike; the experiments above ran unsandboxed.

**One copy of SQLite per process.** SQLite's corruption guide warns that two copies linked into one app each keep their own list of open files: "A close() operation on one connection might unknowingly clear the locks on a different database connection, leading to database corruption." ([howtocorrupt.html §2.3](https://sqlite.org/howtocorrupt.html#multiple_copies_of_sqlite_linked_into_the_same_application)) TaskChampion's default `bundled` feature compiles its own SQLite into the static library. If any Swift code (SQLiteData/GRDB, Core Data) ever opens `taskchampion.sqlite3` in the same process, that is exactly this bug. Build with `default-features = false, features = ["storage-sqlite"]` so `libsqlite3-sys` links the system library (the macOS 27 system `sqlite3` reports 3.54.0), and route every SQLite access to the Replica, including change polling, through the Rust facade.

**Other sandbox notes:**
- `~/.task` and `~/.taskrc` are hidden, so the open panel needs `showsHiddenFiles`, or the user presses ⇧⌘. in the panel.
- `com.apple.security.files.user-selected.read-write` plus bookmarks is enough. No temporary-exception entitlements are needed.

## Change detection for live refresh

SQLite's documented mechanism fits: "The integer values returned by two invocations of `PRAGMA data_version` from the same connection will be different if changes were committed to the database by any other connection in the interim." It is unchanged for the connection's own commits ([sqlite.org/pragma.html#pragma_data_version](https://sqlite.org/pragma.html#pragma_data_version)).

Experiment on one long-lived connection: `task list` left it at 3, `task add` moved it to 4, and `task undo` moved it to 5. A `task list` whose `gc` had nothing to renumber did not bump it, so ordinary CLI reports don't cause spurious refreshes.

Design:
- The facade keeps one extra read-only connection per Replica (same linked SQLite) and exposes `dataVersion()`.
- A Swift clock loop polls it about once a second, or when woken by a DispatchSource/FSEvents hint on the Replica folder, and reloads when it changes.
- WAL writes land in `-wal`, and that file can be checkpointed away or recreated, so a vnode watch on one file is unreliable as the *only* signal. Use it as a wake-up, not as the truth.
- On reload, call `dependency_map(force: true)` or rebuild the `Replica`. The cached dependency map is only invalidated by the app's *own* commits ([`replica.rs` L79, L189](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/replica.rs#L189)).

## Versioning and compatibility

- **Crate versions move fast.** 1.0.0 shipped in Dec 2024, 2.0.0 in Jan 2025, 3.0.0 in Jan 2026 and 3.1.0 on 2026-05-30 ([crates.io](https://crates.io/crates/taskchampion/versions)). 3.0 made every `Replica`/`Storage` method `async` and made `Replica` generic over storage ([v3.0.0 notes](https://github.com/GothenburgBitFactory/taskchampion/releases/tag/v3.0.0)). The facade crate absorbs this churn so Swift never sees it.
- **The on-disk schema is versioned separately** as `DbVersion(major, minor)`. Any build can use a DB with the same major version and upgrades older minors when it opens read-write. A newer *major* is refused with "Database is too new for this version of TaskChampion". ([`schema.rs`](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/storage/sqlite/schema.rs)) Every release so far is major 0. POLICY: "TaskChampion will never upgrade any storage to a non-compatible version without explicit user's request." ([`POLICY.md`](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/POLICY.md))
- **Implication:** opening read-write silently applies minor upgrades, which older CLIs tolerate by design. The app should pin the TaskChampion minor version that current Homebrew Taskwarrior links (3.5.0 → `taskchampion 3.1.0`, [`taskchampion-cpp/Cargo.toml`](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/taskchampion-cpp/Cargo.toml)). Before opening, it should read `version` from a read-only connection and refuse, with a clear message, any major version it doesn't know. Open with `create_if_missing = false`, so a missing or moved Replica errors instead of turning into an empty one.
- **Async bridge:** `SqliteStorage` runs rusqlite on its own thread with a private current-thread tokio runtime and talks to it over `tokio::sync` channels ([`send_wrapper/wrapper.rs`](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/storage/send_wrapper/wrapper.rs)). UniFFI can therefore export `async fn` directly as Swift `async`, and "There's no requirement for a Rust event loop" ([UniFFI futures](https://mozilla.github.io/uniffi-rs/latest/futures.html)). UniFFI does not propagate cancellation, which doesn't matter for short commits. Taskwarrior's own bridge instead wraps each call in `block_on` on a global runtime ([`lib.rs` L534](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/taskchampion-cpp/src/lib.rs#L534)), which is a valid simpler fallback.
- **Architecture:** macOS 27 is Apple-silicon only ("macOS Tahoe will be the last release for Intel-based Mac computers", [Apple: Rosetta](https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment)), so the xcframework needs only `aarch64-apple-darwin`.

## Licence

- TaskChampion and Taskwarrior are both MIT.
- The minimal-feature dependency tree (`cargo tree --no-default-features --features storage-sqlite`) is all permissive: MIT, Apache-2.0, Zlib, Unlicense, 0BSD, and Unicode-3.0 via `unicode-ident`, which is a build-time proc-macro dependency. There is no copyleft.
- Dropping the default `sync` features also drops the AWS/GCP SDKs, reqwest and rustls, which cuts both binary size and licence surface.
- Ship an acknowledgements file generated by `cargo about` or similar. MIT requires the notices to be included.

## App Store review

- Guideline 2.5.2: apps "may not … download, install, or execute code which introduces or changes features or functionality". A statically linked Rust library is ordinary compiled code inside the binary, so this doesn't apply. 2.4.5(i) requires the app to be "appropriately sandboxed" ([App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)).
- Taskchamp shows a TaskChampion static library passing review.
- Reading and writing a user-chosen folder through the open panel plus bookmarks is the sanctioned sandbox path.
- Privacy manifest: TaskChampion is not on Apple's list of SDKs that require one. Check whether the facade touches any required-reason API, such as file timestamps via `stat`. If it does, the app's own `PrivacyInfo.xcprivacy` declares it.

**If the CLI fallback is ever taken:** a bundled `task` must live in `Contents/MacOS`, signed with *only* `com.apple.security.app-sandbox` and `com.apple.security.inherit` ([Apple: Embedding a helper tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)). Sandboxed apps cannot run programs outside the bundle or container without `files.user-selected.executable`, so user hooks in `<Replica>/hooks` would not run.

## Taskwarrior semantics TaskChampion does not provide

TaskChampion stores string maps. The rest of what `task` does is Taskwarrior code that the app must mirror when it writes:

- **Legacy mirrors.** Taskwarrior reads tags from `tag_<name>` and dependencies from `dep_<uuid>`. When writing, it also keeps a comma-joined `tags` and `depends` in sync (`fixTagsAttribute` / `fixDependsAttribute`, [`Task.cpp` L1239-L1275](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/Task.cpp#L1239-L1275)). The experiment shows both forms in `tasks.data`.
- **`modified`.** `TDB2::modify` stamps `modified` on every change and applies `Task::validate` defaults such as `entry`. The status is set last, through `set_status`, so TaskChampion maintains the working set ([`TDB2.cpp` L70-L225](https://github.com/GothenburgBitFactory/taskwarrior/blob/v3.5.0/src/TDB2.cpp#L70-L225)).
- **Undo points.** `task` adds one `UndoPoint` per command, before its first change (`maybe_add_undo_point`).
- **Working-set IDs.** The CLI renumbers them during `gc` (`rebuild_working_set(true)`). The app should never renumber, because that changes the IDs a user just saw in the terminal. `commit_operations` already adds newly pending tasks.
- **Values.** Dates are integer epoch strings. UDA values are strings whose type comes from the Taskrc.

This layer is small and well-defined, and it is where CLI-compatibility bugs will come from. It needs golden tests that write through the app and read back through `task export`, and the reverse.

## Undo (input for the ⌘Z decision)

- `get_undo_operations` returns everything back to the last `UndoPoint` in the *shared* log.
- `commit_reversed_operations` returns `false` if those operations no longer match the stored local operations, for example because the CLI or a sync changed things in between ([`replica.rs` L415-L446](https://github.com/GothenburgBitFactory/taskchampion/blob/v3.1.0/src/replica.rs#L415-L446)).
- A naive ⌘Z could therefore undo the CLI's last command. The app has to check that the pending undo group is one it committed, for example by remembering the operations or undo-point position it wrote, before reversing.
- Operations that have been synced can never be undone.

## Engine comparison

| | Embedded TaskChampion (UniFFI) | Bundled `task` binary | Direct SQLite |
| --- | --- | --- | --- |
| Log integrity | Guaranteed by upstream code | Guaranteed | Hand-rolled, fragile |
| Upstream stance | Preferred ("use taskchampion as a library") | Works; CLI output is the documented interface | Schema "isn't considered a public API" |
| TW semantics | Must mirror in the facade or Swift | Exact | Must mirror |
| Reads | In-process, typed, fast | Spawn plus `task export` JSON each time | Fast |
| Undo control | Operation-level | `task undo` only | None |
| Build/CI | Rust + UniFFI → xcframework | C++/CMake + Rust (corrosion), helper signing | None |
| Sandbox | Folder bookmark | Folder bookmark + `inherit` helper; hooks can't run | Folder bookmark |
| Version drift | Pin TaskChampion to the CLI's minor | Pin TW version | Breaks on schema changes |

## New questions surfaced

1. **Module graph:** where does the TW-compatibility layer live? Options are the Rust facade (one place, testable against `task`) or a Swift `TaskwarriorModel` module over a thin UniFFI surface. This adds a Rust crate plus an xcframework-producing target to the Tuist/SPM graph.
2. **Undo ownership:** how the app recognises its own undo groups in the shared log. This feeds the existing ⌘Z fog item.
3. **SQLite linkage check:** confirm `libsqlite3-sys` without `bundled` links cleanly against the macOS 27 SDK's `libsqlite3.tbd`, and add a build check that the static library contains no `sqlite3_` symbols.
4. **Sandboxed locking spike:** a signed, sandboxed build commits while `task` holds and waits on the lock, which confirms the one assumption not yet tested inside the sandbox.
5. **Version gate UX:** what the window shows for an unknown schema major version, or a Replica that is missing or moved (overlaps the existing fog item).
