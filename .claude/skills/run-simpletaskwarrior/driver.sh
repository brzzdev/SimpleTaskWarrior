#!/usr/bin/env bash
# Drives the dev build of SimpleTaskWarrior through System Events and posted mouse events.
# Run from the repo root. `driver.sh help` lists the commands.
set -euo pipefail

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The Debug product, which has its own name and bundle ID so it runs alongside an installed release.
product="SimpleTaskWarrior Debug"
app="$PWD/.build/xcode/Build/Products/Debug/$product.app"
bundle_id=dev.brzz.SimpleTaskWarrior.debug
mouse_bin="${TMPDIR:-/tmp}/simpletaskwarrior-mouse"
# `frame` pins the window here, so the header row sits at a known y.
window_x=100
window_y=100
header_y=$((window_y + 66))

# The dev build's PID, by executable path: another checkout's dev build runs under the same
# process name. Compared as a string, since `pgrep -f` would read the path as a regex and miss a
# checkout under a name like `fix(ci)`.
dev_pid() {
	local binary="$app/Contents/MacOS/$product" pid
	for pid in $(pgrep -x "$product" || true); do
		if [ "$(ps -o comm= -p "$pid")" = "$binary" ]; then
			echo "$pid"
			return 0
		fi
	done
	return 1
}

# se SCRIPT [ARG...]: runs SCRIPT against the dev build, frontmost. Data goes in as ARGs, which
# SCRIPT reads as `item n of argv`, so a quote or backslash in a path can't change the script.
se() {
	local script=$1 pid
	shift
	if ! pid="$(dev_pid)"; then
		echo "the dev build isn't running; run \`driver.sh launch\`" >&2
		exit 1
	fi
	osascript -e "on run argv" \
		-e "tell application \"System Events\" to tell (first process whose unix id is $pid)" \
		-e "set frontmost to true" -e "$script" -e "end tell" -e "end run" "$@"
}

mouse() {
	if [ ! -x "$mouse_bin" ] || [ "$skill_dir/mouse.swift" -nt "$mouse_bin" ]; then
		swiftc -O "$skill_dir/mouse.swift" -o "$mouse_bin"
	fi
	se "delay 0.2" >/dev/null
	"$mouse_bin" "$@"
}

case "${1:-help}" in
fixture)
	# fixture DIR: a Replica and a Taskrc with UDAs, made by the real `task`.
	# Fresh only: rerunning `task add` into an existing Replica duplicates every task. Checked on
	# the resolved path, since `find` doesn't descend into a symlink named as its start.
	dir="$(mkdir -p "$2" && cd "$2" && pwd -P)"
	if [ -n "$(find "$dir" -mindepth 1 -print -quit)" ]; then
		echo "fixture: $2 isn't empty" >&2
		exit 1
	fi
	mkdir -p "$dir/replica"
	cat >"$dir/taskrc" <<-EOF
		data.location=$dir/replica
		confirmation=off
		news.version=3.5.0
		uda.size.type=string
		uda.size.label=Size
		uda.size.values=S,M,L
		uda.estimate.type=duration
		uda.estimate.label=Estimate
	EOF
	t() { TASKRC="$dir/taskrc" TASKDATA="$dir/replica" task rc.verbose=nothing "$@"; }
	t add Write the quarterly report project:work +office priority:H due:tomorrow size:L
	t add Buy groceries project:home priority:M size:S
	t add Fix the bike +outdoor priority:L estimate:2h
	t add Read a book
	t add Pay rent due:today-7d project:home recur:monthly
	t add Wait for parcel wait:someday
	t add Deploy the release project:work priority:H depends:1
	t add Plan the trip project:home size:M
	t add Scheduled check-in scheduled:now+4min
	t 3 start
	t 4 annotate first note
	t 4 annotate second note
	# `task` creates Recurrence instances only when a report runs.
	t next >/dev/null
	echo "replica: $dir/replica"
	echo "taskrc:  $dir/taskrc"
	;;
launch)
	# Builds, quits any running dev copy, and opens the app.
	just run >/dev/null
	sleep 3
	;;
open)
	# open REPLICA_DIR: the Dock's path into application(_:openFile:), no panel needed.
	open -a "$app" "$2"
	sleep 3
	;;
taskrc)
	# taskrc FILE: File > Choose Taskrc… on the front window, then Go to Folder.
	se 'click menu item "Choose Taskrc…" of menu "File" of menu bar 1
		delay 1.5
		keystroke "g" using {command down, shift down}
		delay 1
		keystroke (item 1 of argv)
		delay 1
		key code 36
		delay 1.5
		key code 36
		delay 2' "$2" >/dev/null
	;;
frame)
	# frame [W H]: moves the front window to the pinned origin, 1500×700 by default.
	se "set position of window 1 to {$window_x, $window_y}
		set size of window 1 to {${2:-1500}, ${3:-700}}" >/dev/null
	sleep 1
	;;
windows)
	se "get {name, position, size} of every window"
	;;
shot)
	# shot FILE [W H]: the pinned window region, in points; the PNG is 2x on Retina.
	se "delay 0.3" >/dev/null
	screencapture -x -R"$window_x,$window_y,${3:-1500},${4:-700}" "$2"
	echo "$2"
	;;
click | rclick | drag)
	mouse "$@"
	;;
header)
	# header TITLE [X]: toggles a column in the header's menu by type-select.
	mouse rclick "${3:-850}" "$header_y"
	sleep 0.8
	se 'keystroke (item 1 of argv)
		delay 0.4
		key code 36' "$2" >/dev/null
	sleep 0.8
	;;
key)
	# key KEY MODIFIERS, e.g. key i "command down, control down". MODIFIERS is AppleScript.
	se "keystroke (item 1 of argv) using {$3}" "$2" >/dev/null
	sleep 1
	;;
menu)
	# menu MENU ITEM
	se 'click menu item (item 2 of argv) of menu (item 1 of argv) of menu bar 1' "$2" "$3" >/dev/null
	sleep 1
	;;
close)
	se 'keystroke "w" using command down' >/dev/null
	sleep 1.5
	;;
relaunch)
	# ⌘Q, then launch with no file, so only window restoration can bring windows back.
	se 'keystroke "q" using command down' >/dev/null
	sleep 3
	if dev_pid >/dev/null; then
		echo "still running after ⌘Q" >&2
		exit 1
	fi
	open "$app"
	sleep 5
	;;
layout)
	# layout REPLICA_DIR: the table's autosaved columns and sort for that Replica.
	python3 - "$bundle_id" "$2" <<-'EOF'
		import os, plistlib, subprocess, sys
		defaults = plistlib.loads(
		    subprocess.run(["defaults", "export", sys.argv[1], "-"], capture_output=True, check=True).stdout
		)
		# AppKit keys the autosave by the standardized path: no /private, no doubled slashes.
		name = "replica:" + os.path.realpath(sys.argv[2]).removeprefix("/private").rstrip("/") + "/"
		for prefix in ("NSTableView Columns v3", "NSTableView Sort Ordering v2"):
		    value = defaults.get(f"{prefix} {name}")
		    if value is None:
		        continue
		    objects = plistlib.loads(value)["$objects"]
		    def resolve(item):
		        item = objects[item.data] if isinstance(item, plistlib.UID) else item
		        if isinstance(item, dict) and "NS.keys" in item:
		            return {resolve(k): resolve(v) for k, v in zip(item["NS.keys"], item["NS.objects"])}
		        if isinstance(item, dict) and "NS.objects" in item:
		            return [resolve(o) for o in item["NS.objects"]]
		        return item
		    print(prefix)
		    for entry in resolve(plistlib.loads(value)["$top"]["Array"]):
		        print("  ", entry)
	EOF
	;;
quit)
	se 'keystroke "q" using command down' >/dev/null
	;;
*)
	awk '/^[a-z| ]+\)$/ || /^\t# / { sub(/^\t/, "  "); print }' "$0"
	;;
esac
