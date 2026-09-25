# The app ships Developer ID only, outside the App Sandbox

The app ships only as a hardened, notarised Developer ID build, and it doesn't run in the App Sandbox. This reverses [Chart SimpleTaskWarrior v1](https://github.com/brzzdev/SimpleTaskWarrior/issues/1)'s "shippable via both the App Store and Developer ID", and [Sign and distribute the app](https://github.com/brzzdev/SimpleTaskWarrior/issues/39) drops its App Store build to match. The app is a window on files the `task` CLI reads by path: a Replica, `~/.taskrc`, and whatever the Taskrc includes. Inside the sandbox the app reaches those only through files the user picks. They're kept as security-scoped bookmarks, with a grant for every include and a remedy banner whenever a file is unreadable. Some of the CLI's behaviour still can't be matched. [Follow a symlinked Taskrc](https://github.com/brzzdev/SimpleTaskWarrior/issues/50) found that the file panel gives the app a symlinked Taskrc's resolved target, never the link. The app can't open the link node with or without the grant, and the grant reaches only that one target. So a Taskrc installed by stow can't be followed when its link is repointed.

## Consequences

- No Mac App Store release. App Review Guideline 2.4.5(i) requires the sandbox.
- The app and its engine can read anything the user can read. Folders TCC protects (`~/Documents`, `~/Desktop`, `~/Downloads`, iCloud Drive) still prompt.
- With no Taskrc chosen, the app reads the one the CLI would, `$TASKRC` or `~/.taskrc`, by path, and watches a symlink's link node too.
- Replica bookmarks and Taskrc pairings saved by sandboxed builds must still open after an upgrade.

## Considered options

- **Stay sandboxed and poll the link.** At pick time, the app would guess the link by checking whether `~/.taskrc` resolves to the chosen file. It would then poll `readlink`, which works without a grant. This infers what the user chose instead of knowing it, and it keeps every grant flow.
- **Two builds.** A sandboxed App Store build and an unsandboxed Developer ID build would need two ways into every file, each tested separately.
