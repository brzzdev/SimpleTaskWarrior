# SimpleTaskWarrior

A native macOS client for [Taskwarrior 3](https://taskwarrior.org) data. Each
window works on one Replica, the TaskChampion database `TASKDATA` points at,
alongside the `task` CLI: changes made in either show up in the other.

## Setup

1. Install a **Developer ID Application** certificate for your team, from
   [Apple Developer ▸ Certificates](https://developer.apple.com/account/resources/certificates)
   or Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates. The app signs manually
   with Developer ID and ad-hoc signing is disabled, so a build without the
   certificate fails at the signing step even with the team ID set.

2. Set your signing team so Tuist can produce a signed, sandboxed app:

   ```sh
   export TUIST_DEVELOPMENT_TEAM=XXXXXXXXXX
   ```

3. Install the developer tools. The build lints through Mint and fails without it:

   ```sh
   just tools
   ```

4. Generate, build, run:

   ```sh
   just generate
   just build
   just run
   ```

## Development

```sh
just tools     # brew bundle, mint packages and git hooks (once)
just test      # run the full test plan (xcodebuild, unsigned)
just format    # SwiftFormat
just lint      # SwiftLint
```

> Raw `swift build` / `swift test` are intentionally blocked (they create a
> multi-GB local `.build/`). Use the `just` recipes, which drive `xcodebuild`.

## Architecture

Single SPM package, one module per concern, wired with
[The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture):

| Module | Role |
| --- | --- |
| `Taskrc` | Parses a Taskrc the way Taskwarrior 3.5 does, over its compiled-in defaults |
| `Models` | Task decoding, Urgency, the blocked rule and the write planner |
| `ReplicaClient` | The engine behind an actor, one per open Replica |
| `TaskrcClient` | Loads, watches and reloads a window's Taskrc |
| `BookmarkClient` | Security-scoped bookmarks for Replicas, Taskrcs and their includes |
| `ReplicaFeature` | The window: sidebar, task table and inspector |
| `App` | Scenes, Open Replica… and Choose Taskrc… |
| `TestSupport` | Fixtures shared by the test targets |

The reasoning behind it is in [`CONTEXT.md`](CONTEXT.md) and
[`docs/adr/`](docs/adr/).

## License

Licensed under the [GNU General Public License v3.0](LICENSE).

Copyright (C) 2026 brzzdev
