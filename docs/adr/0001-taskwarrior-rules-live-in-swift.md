# Taskwarrior rules live in Swift, over a thin engine facade

The app embeds TaskChampion behind a thin Rust facade exposed with UniFFI, which wraps TaskChampion's primitives and holds no Taskwarrior rules. Every Taskwarrior rule lives in pure Swift modules: write mirroring, Urgency, TW's blocked rule, and Taskrc parsing. These rules are Taskwarrior's, layered on top of TaskChampion, and they change when TW changes. Keeping them in Swift puts them in the language the rest of the app and its tests use, and changing a rule never touches the bindings. [Draw the module graph](https://github.com/brzzdev/SimpleTaskWarrior/issues/6) has the facade's surface and the module graph, and [Specify how app writes mirror the CLI](https://github.com/brzzdev/SimpleTaskWarrior/issues/9) has the rules.

The facade is TaskChampion's only commit point, and it refuses a plan whose inputs changed before it commits. The Swift planner works from a snapshot that can go stale, and TaskChampion's commit doesn't check it, so inside the same call that commits, the facade re-reads the values the plan read and refuses on a mismatch. It runs that check inside the commit's own transaction, through a storage wrapper TaskChampion commits with, so the check and the write happen under one SQLite write lock and no write can land between them. The `task` CLI has no such check, so a race between two CLI commands is still last writer wins.

## Considered options

- **A thick facade**, with the rules in Rust next to TaskChampion's types. Urgency and the Taskrc parser would move into Rust only for Swift to call back into them.
- **A split**, with write mirroring in Rust next to the transaction. Moving the rules wouldn't close the stale-plan race any further, because the facade's check already runs inside the commit's transaction wherever the rules live.
