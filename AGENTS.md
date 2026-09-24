# SimpleTaskWarrior

- Build and test via `just build` / `just test`; never call xcodebuild directly
- The Xcode project is Tuist-generated from `Project.swift`: edit the manifest, never the `.xcodeproj`

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `brzzdev/SimpleTaskWarrior`, managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` plus `docs/adr/` at the repo root. See `docs/agents/domain.md`.
