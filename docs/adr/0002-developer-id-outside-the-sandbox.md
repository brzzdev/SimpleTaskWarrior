# Ship Developer ID only, outside the App Sandbox

The app ships only as a notarised Developer ID build, and it doesn't run in the App Sandbox. This reverses [Chart SimpleTaskWarrior v1](https://github.com/brzzdev/SimpleTaskWarrior/issues/1)'s "shippable via both the App Store and Developer ID". The app is a window on files the `task` CLI already reads by path: a Replica, `~/.taskrc`, and whatever the Taskrc includes. Inside the sandbox it can only reach those through files the user picks, kept as security-scoped bookmarks, plus a grant for every include. That costs a Choose Taskrc… step, a Grant Access… flow and a banner for each unreadable file, and some of the CLI's behaviour still can't be matched. [Follow a symlinked Taskrc](https://github.com/brzzdev/SimpleTaskWarrior/issues/50) found that the file panel gives the app a symlinked Taskrc's resolved target, never the link. It also found that the sandboxed app can't open the link node even while it holds the grant, so a Taskrc installed by stow can't be followed when its link is repointed. Outside the sandbox the app reads the same paths the CLI reads, when the CLI reads them.

## Consequences

- No Mac App Store release. App Review Guideline 2.4.5(i) requires the sandbox.
- The app and its engine can read anything the user can read. Folders TCC protects (`~/Documents`, `~/Desktop`, `~/Downloads`, iCloud Drive) still prompt once.
- [Run the app outside the App Sandbox](https://github.com/brzzdev/SimpleTaskWarrior/issues/51) removes the bookmarks' security scope and the include grants. It also makes `~/.taskrc` the default Taskrc.

## Considered options

- **Stay sandboxed and poll the link.** At pick time, the app would guess the link by checking whether `~/.taskrc` resolves to the chosen file, then poll `readlink`, which works without a grant. This infers what the user chose instead of knowing it, and it keeps every grant flow.
- **Two builds.** A sandboxed App Store build and an unsandboxed Developer ID build would need two ways into every file, each tested separately.
