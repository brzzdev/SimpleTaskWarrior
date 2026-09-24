#!/usr/bin/env bash
# PreToolUse(Bash) hook: steer `swift build` / `swift test` to the justfile,
# which drives xcodebuild into DerivedData instead of a multi-GB local .build/.
input="$(cat)"

if command -v jq >/dev/null 2>&1; then
	cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)"
else
	cmd="$input"
fi

# Newlines collapse to \001 because sed is line-oriented and a quoted span
# routinely spans lines — a multi-line `git commit -m` body being the case that
# caught this. \001 is a plain separator to the boundary classes below, so it
# changes no other verdict.
raw="$(printf '%s' "$cmd" | tr '\n' '\001')"

# Quoted spans are data, not command position, so drop them before matching:
# `git commit -m "fix swift build"` is a commit message, not a build.
stripped="$(printf '%s' "$raw" | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')"

# …except where a shell is in play, because then the quoted text may be the
# payload rather than data. Parsing *how* it is handed over turned out to be
# the wrong shape: `-c`, then `-c` with option-arguments (`-O extglob -c`),
# then `+` options (`+O extglob -c`) each needed another rule, and `-s`,
# a herestring and a pipe into a shell were all still open.
#
# So the test is only whether something that can execute a string is named at
# all: a shell by name or via $SHELL, or `eval`. Naming one is rare in this
# repo, and when it happens the quoted text gets scanned too — the whole
# payload class in one rule, at the cost of denying a line that both invokes a
# shell and quotes the command in prose.
#
# The names are enumerated rather than matched as "a word ending in sh". That
# suffix is tempting and wrong: `git push` ends in it, so pairing a push with
# a commit message quoting the command would deny a routine line. csh and tcsh
# both ship on macOS and run a `-c` payload, so an sh-shaped pattern missed
# them. Adding a shell here is one entry; keep the list honest.
shells='(ash|bash|csh|dash|fish|ksh|mksh|pdksh|pwsh|sh|tcsh|xonsh|zsh)'
executor='(^|[^[:alnum:]_.-])((/[^[:space:]]*/)?'"${shells}"'|\$\{?[A-Za-z_]*SHELL\}?|eval)([^[:alnum:]_.-]|$)'

# Anchoring on shell separators alone let `/usr/bin/swift build` and
# `env FOO=1 swift test` straight through, and enumerating the wrappers that
# can precede it (env, xcrun, nice -n 5, sudo -u me, …) is whack-a-mole. So
# the rule is inverted: `swift build`/`swift test` anywhere it isn't glued to
# a word character. `.` and `-` stay out of both boundary classes so
# `swiftlint`, `swift-format` and `build.log` don't trip it.
#
# Deliberately not matched: `swift package resolve` / `update`, which write
# .build/ too but are the documented way to move the TCA26 branch pin
# (docs/scaffolding.md). Clean up after those by hand.
before='(^|[^[:alnum:]_.-])'
path='(/[^[:space:]]*/)?'
after='([^[:alnum:]_.-]|$)'
invocation="${before}${path}"'swift[[:space:]]+(build|test)'"${after}"

blocked=false
if printf '%s' "$stripped" | grep -qE "$invocation"; then
	blocked=true
elif printf '%s' "$raw" | grep -qE "$executor" && printf '%s' "$raw" | grep -qE "$invocation"; then
	blocked=true
fi

if [ "$blocked" = true ]; then
	printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Use `just build` / `just test` instead. Raw `swift build` / `swift test` create a multi-GB local .build/ folder; the justfile runs xcodebuild into DerivedData."}}'
fi

exit 0
