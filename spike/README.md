# Spike: sandboxed Replica access against the CLI

Throwaway spike for [Prove sandboxed Replica access against the CLI](https://github.com/brzzdev/SimpleTaskWarrior/issues/10). Run 2026-09-24 on macOS 27, Xcode 27.0, Rust 1.98.1 and Taskwarrior 3.5.0 (Homebrew), against a scratch Replica and Taskrc.

## Verdict

Everything the ticket asked about works. A Developer ID-signed, hardened, sandboxed app holding only `app-sandbox` and `files.user-selected.read-write` can:

- open a Replica through a security-scoped folder bookmark, using TaskChampion 3.1.0 behind UniFFI and linked to the system SQLite;
- commit while `task` writes the same Replica;
- see the CLI's writes through `PRAGMA data_version`;
- keep watching a Taskrc through a file bookmark while `task config` and `task context` rewrite it, including after a relaunch.

No temporary-exception entitlements were needed, and `files.bookmarks.app-scope` wasn't either.

## Results

| Check | Result |
| --- | --- |
| No bundled SQLite | `libstw_engine.a` defines 0 `sqlite3_` symbols and references 47. The app links `/usr/lib/libsqlite3.dylib`, and `sqlite_version()` is 3.54.0. |
| Folder grant → bookmark | A folder passed with `open -a` becomes a `.withSecurityScope` bookmark. Resolving it gives `startAccessing… = true`, and it resolves the same way after a relaunch. |
| CLI write → app | `task add` bumped the app's `data_version` (2 → 3), and a 250 ms poll picked it up. |
| App write → CLI | `task export` shows the app's task with an id, `pending`, and `entry`/`modified` set. One `task undo` reverts the app's whole add. |
| Another process holds the lock 2 s | The app's commit waited, then succeeded in 1.6 s. |
| Another process holds the lock 7 s | The app's commit failed after 5.0 s with `database is locked` (TaskChampion's rusqlite 5 s busy timeout). |
| App holds the lock 2 s | `task add` waited, then succeeded (exit 0, 1.5 s). |
| App holds the lock 7 s | `task add` failed after 5.2 s: `database is locked: Error code 5` (exit 2). |
| Storm: 25 app adds interleaved with 25 CLI adds | 0 failures on either side, 50/50 tasks, and `PRAGMA integrity_check` returns `ok`. |
| `task config` / `task context` | They rewrite the Taskrc **in place**, keeping the same inode. The file watcher sees `attrib`, then `write\|extend`, and the file stays readable. |
| Editor-style replace (write a temp file, rename it over) | The watcher gets `delete` on the old inode. Re-arming at the same path works, and the file-bookmark grant still covers the new inode. On relaunch the bookmark resolves `stale=true` to the new file, re-saving fixes that, and access holds. |
| Replica moved (renamed) | On relaunch the bookmark follows the folder (`stale=true`) and the Replica opens at its new path. |
| Replica deleted and recreated at the same path | The bookmark resolves `stale=true` to the new folder with access. |

## Notes for the build

- **Lock ceiling is symmetric.** Each side waits 5 s for the other. The app must keep every commit short, and must surface `database is locked` as a retryable failure, not a crash.
- **`data_version` also moves for the app's own commits** when the watcher is a separate connection, as it is here. Reloading after the app's own writes is therefore free. Nothing needs to filter them out.
- **Taskrc watching:** an in-place rewrite needs only `write`/`extend`. Treat `delete`/`rename` as "re-open the path and re-arm", and re-save a bookmark that resolves stale.
- **The async bridge wasn't exercised.** The facade exports sync functions that `block_on` a current-thread tokio runtime, the way Taskwarrior's own bridge does, and Swift calls them from a detached task. Exporting `async fn` through UniFFI is still untested.
- **Grants came from LaunchServices open events**, not from `NSOpenPanel`. Both are user-intent grants that produce the same security-scoped URL. The panel itself is ordinary AppKit.

## Build steps

```sh
# 1. Engine: static library, arm64 only, no `bundled` SQLite
cd spike/engine
cargo build --release --target aarch64-apple-darwin
nm -g --defined-only target/aarch64-apple-darwin/release/libstw_engine.a | grep -c ' _sqlite3_'  # must be 0

# 2. Swift bindings and xcframework
cargo run --bin uniffi-bindgen -- generate --library target/aarch64-apple-darwin/release/libstw_engine.a \
	--language swift --out-dir ../build/gen
mkdir -p ../build/headers
cp ../build/gen/stw_engineFFI.h ../build/headers/
cp ../build/gen/stw_engineFFI.modulemap ../build/headers/module.modulemap
xcodebuild -create-xcframework -library target/aarch64-apple-darwin/release/libstw_engine.a \
	-headers ../build/headers -output ../build/StwEngineFFI.xcframework

# 3. App: SwiftPM build, hand-assembled bundle, Developer ID + hardened runtime + sandbox
../app/build.sh

# 4. Race it against the CLI
lab=/some/scratch; mkdir -p $lab/replica
printf 'data.location=%s/replica\ncontext.work.read=+work\ncontext.work.write=+work\n' $lab > $lab/taskrc
TASKRC=$lab/taskrc task add seed
open -a "$PWD/../build/STWSpike.app" $lab/replica   # absolute path: `open -a` treats a relative one as an app name
../drive.sh $lab
```

Build notes: `taskchampion =3.1.0` pins `rusqlite 0.39`, so a direct `rusqlite` dependency has to match, because `links = "sqlite3"` allows only one `libsqlite3-sys`. The UniFFI target needs `linkedLibrary("sqlite3")`. The generated Swift file needs Swift 5 language mode.
