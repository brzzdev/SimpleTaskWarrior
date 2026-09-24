#!/usr/bin/env bash
# Drives block-swift-build.sh over block-swift-build.cases.tsv, comparing each
# verdict against the expected one. Run it directly: no arguments, no fixtures
# to point at.
#
#   bash .claude/hooks/block-swift-build.test.sh
#
# Exits non-zero with the failing count, so it can gate a change to the hook.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$here/block-swift-build.sh"
cases="$here/block-swift-build.cases.tsv"

if ! command -v jq >/dev/null 2>&1; then
	echo "jq is required (the hook reads the tool call as JSON)" >&2
	exit 2
fi

fail=0
total=0

while IFS=$'\t' read -r want cmd; do
	case "${want:-}" in
	'' | '#'*) continue ;;
	esac
	total=$((total + 1))

	# The hook prints a deny payload and nothing otherwise.
	if [ -n "$(printf '%s' "$cmd" | jq -Rsc '{tool_input:{command:.}}' | bash "$hook")" ]; then
		got=deny
	else
		got=allow
	fi

	if [ "$got" = "$want" ]; then
		printf 'ok    %-5s | %s\n' "$got" "$cmd"
	else
		printf 'FAIL  want=%-5s got=%-5s | %s\n' "$want" "$got" "$cmd"
		fail=$((fail + 1))
	fi
done <"$cases"

echo "---"
if [ "$fail" -eq 0 ]; then
	echo "$total cases, all pass"
else
	echo "$total cases, $fail failed"
fi
exit "$fail"
