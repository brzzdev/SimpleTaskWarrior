# Taskwarrior rules live in Swift, over a thin engine facade

The app embeds TaskChampion behind a thin Rust facade exposed with UniFFI, which wraps TaskChampion's primitives and holds no Taskwarrior rules. Every Taskwarrior rule lives in pure Swift modules: write mirroring, Urgency, TW's blocked rule, and Taskrc parsing. These rules are Taskwarrior's, layered on top of TaskChampion, and they change when TW changes. Keeping them in Swift puts them in the language the rest of the app and its tests use, and changing a rule never touches the bindings. [Draw the module graph](https://github.com/brzzdev/SimpleTaskWarrior/issues/6) has the facade's surface and the module graph, and [Specify how app writes mirror the CLI](https://github.com/brzzdev/SimpleTaskWarrior/issues/9) has the rules.

The facade is TaskChampion's only commit point, and it never commits a plan that a concurrent write has invalidated. The Swift planner works from a snapshot that can go stale, and TaskChampion's commit doesn't check it, so the facade checks the values the plan read inside the same call that commits, and refuses on a mismatch. That leaves the app the same race window the `task` CLI has between its own read and commit.

## Considered options

- **A thick facade**, with the rules in Rust next to TaskChampion's types. Urgency and the Taskrc parser would move into Rust only for Swift to call back into them.
- **A split**, with write mirroring in Rust next to the transaction. The transaction needs protection from stale plans, and the facade's commit check gives it that wherever the rules live.
