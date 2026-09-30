# Run recipes under bash with pipefail so a failing xcodebuild isn't masked by a
# successful `| xcbeautify` (which would otherwise let CI go green on a red build).
set shell := ["bash", "-euo", "pipefail", "-c"]

scheme := "SimpleTaskWarrior"
workspace := "SimpleTaskWarrior.xcworkspace"
destination := "platform=macOS"
# Pinned so `run` can construct the product path instead of paying a second
# `xcodebuild -showBuildSettings` to ask for it, which re-resolves the package
# graph. `build`, `test`, `run` and `clean` all share it, so they never build the
# same code into two trees.
#
# It has to sit under `.build/`. Derived data carries `SourcePackages/checkouts`,
# a full copy of every dependency's sources, and the shared SwiftFormat and
# SwiftLint configs (brzzdev/Configs) exclude `.build` and nothing else of the
# sort — anywhere else in the tree and `just format` and `just lint` walk into
# the dependencies. `just clean` already removes `.build` wholesale, so the
# pinned tree is covered there too.
#
# Xcode.app keeps its own DerivedData under ~/Library, so a CLI build and an
# Xcode build do not share one; the first after switching cold-compiles.
# `archive` deliberately does not pin it — a notarised build has no business
# reusing an incremental dev cache.
derived_data := ".build/xcode"
# Repo-scoped because a path shared across repos lets two checkouts on different
# config revisions fight over one file, each overwriting the other's mid-commit.
swiftformat_base := "/tmp/swiftformat-base-SimpleTaskWarrior"
swiftformat_url := "https://raw.githubusercontent.com/brzzdev/Configs/main/Configs/swiftformat"
# The Debug configuration's product name, which names the `.app` and executable `run` launches.
debug_product := scheme + " Debug"
notary_profile := "SimpleTaskWarrior"
release_dir := ".release"
# The app `archive` exports, which `release` and `publish` notarize.
release_app := release_dir / "export" / scheme + ".app"
release_zip := release_dir / scheme + ".zip"
# The one target `Engine/rust-toolchain.toml` installs.
engine_target := "aarch64-apple-darwin"
# The Brewfile's rustup is keg-only, so it is off PATH unless the shell put it
# there. Recipes prepend it, because Homebrew's `rust` formula puts a cargo in
# /opt/homebrew/bin that ignores rust-toolchain.toml; rustup's proxies honour it,
# from a recipe whose working directory is `Engine/`.
rustup_bin := "/opt/homebrew/opt/rustup/bin"

# List available recipes
default:
	@just --list

# Regenerates the bindings in `Sources/Engine` and assembles
# `Engine/build/EngineFFI.xcframework`. Xcode.app has no build phase for this
# (cargo in a script phase fights the user-script sandbox), so run it after
# pulling engine changes.
# Build the Rust engine, its Swift bindings and the xcframework
[working-directory: "Engine"]
engine:
	#!/usr/bin/env bash
	set -euo pipefail

	export PATH="{{ rustup_bin }}:$PATH"
	target={{ engine_target }}
	cargo build --locked --release --target "$target" --package engine
	library="target/$target/release/libengine.a"

	# Two SQLite copies in one process can drop each other's POSIX locks and
	# corrupt the Replica, so the engine must reference the system libsqlite3
	# rather than bundle its own. The symbols are captured first so a failing
	# `nm` stops the recipe instead of reading as zero matches, which is what
	# Xcode's `nm` does on the objects this toolchain's newer LLVM emits.
	nm="$(rustc --print sysroot)/lib/rustlib/$target/bin/llvm-nm"
	symbols="$("$nm" --quiet -g --defined-only "$library")"
	if grep -q ' _sqlite3_' <<<"$symbols"; then
		echo "libengine.a defines sqlite3_ symbols: something enabled rusqlite's \`bundled\` feature." >&2
		exit 1
	fi

	generated=build/generated
	rm -rf "$generated"
	cargo run --locked --quiet --release --target "$target" --package uniffi-bindgen -- \
		generate --library "$library" --language swift --out-dir "$generated"
	# Copied only when changed, so an unchanged binding keeps its mtime and
	# doesn't recompile the target.
	bindings=../Sources/Engine/Engine.swift
	cmp -s "$generated/Engine.swift" "$bindings" || cp "$generated/Engine.swift" "$bindings"

	xcframework=build/EngineFFI.xcframework
	if [ "$library" -nt "$xcframework" ]; then
		rm -rf build/headers "$xcframework"
		mkdir -p build/headers
		cp "$generated/EngineFFI.h" build/headers/
		cp "$generated/EngineFFI.modulemap" build/headers/module.modulemap
		xcodebuild -create-xcframework -library "$library" -headers build/headers -output "$xcframework"
	fi

# Run the Rust engine's tests
[working-directory: "Engine"]
engine-test:
	PATH="{{ rustup_bin }}:$PATH" cargo test --locked --target {{ engine_target }} --package engine

# Generate the Xcode project from Project.swift. The touch stamps the workspace
# for `ensure-generated`: Tuist leaves unchanged files alone, so without it the
# workspace's mtime would not record that a generate ran.
generate: engine
	tuist generate --no-open
	touch {{ workspace }}

# Generate when the workspace is missing or older than anything Tuist reads to
# build it: the manifest, the app host files its globs pick up, and the pins in
# `.package.resolved`, which it restores into the workspace. The package's own
# sources need nothing, since Xcode resolves the local package itself.
#
# It depends on `engine`, and so does everything that builds through it
# (`build`, `test`, `release`): the package's binary target points into
# `Engine/build/`, and the bindings must match the library they call.
# `--no-deps` because `engine` has already run.
[private]
ensure-generated: engine
	[ -d {{ workspace }} ] && [ -z "$(find .package.resolved Project.swift AppHost -newer {{ workspace }})" ] || just --no-deps generate

# Each Taskrc fixture's `expected.rc` is what `task _show` prints for its
# `taskrc`, which `TaskrcTests` compares the parser against. The environment is
# fixed to the one the tests expand with, and `task` runs from an empty directory
# so no include resolves against the CWD, which the app ignores.
#
# Each Models fixture's `tasks.sh` builds a fresh Replica under its `taskrc`, in
# UTC. `ModelsTests` reads the Replica's properties (`tasks.json`) back against
# what `task` reports at `now`: `export.json`, and the UUIDs it counts as
# blocked, blocking and templates. TW stamps tasks with the time, so every
# recording differs.
#
# Each write fixture's `cases.sh` runs one write per case, which
# `WritePlannerTests` plans against what `task` committed for it.
# Record the golden Taskrc, Models, write and date input fixtures from real `task` 3.5
fixtures:
	#!/usr/bin/env bash
	set -euo pipefail

	task="$(command -v task)"
	version="$("$task" --version)"
	if [ "$version" != 3.5.0 ]; then
		echo "the fixtures are recorded from task 3.5.0, not $version" >&2
		exit 1
	fi

	# `_show` prints `TASKDATA` as `data.location`, so it's a fixed path rather than a temporary
	# one: a re-recording leaves the goldens unchanged.
	taskdata=/tmp/SimpleTaskWarrior-fixtures
	scratch="$(mktemp -d)"
	trap 'rm -rf "$scratch"' EXIT
	# `mkdir` claims the path atomically, and the cleanup below covers it only once it's this
	# run's, so a concurrent recording is never removed.
	if ! mkdir "$taskdata"; then
		echo "can't claim $taskdata: another recording is running, or remove it" >&2
		exit 1
	fi
	trap 'rm -rf "$scratch" "$taskdata"' EXIT
	for fixture in "$PWD"/Tests/TaskrcTests/Fixtures/*/; do
		(
			cd "$scratch"
			env -i HOME=/home/fixture USER=fixture FIXTURE=value \
				TASKDATA="$taskdata" TASKRC="$fixture/taskrc" "$task" _show
		) > "$fixture/expected.rc"
	done

	# Runs `task` against `$replica` under `$fixture`'s Taskrc, in UTC, for the Models and write
	# fixtures.
	task() {
		(
			cd "$scratch"
			env -i HOME=/home/fixture TZ=UTC TASKDATA="$replica" TASKRC="$fixture/taskrc" \
				"$task" rc.confirmation=0 rc.hooks=0 rc.verbose=nothing "$@"
		)
	}
	for fixture in "$PWD"/Tests/ModelsTests/Fixtures/*/; do
		replica="$taskdata/$(basename "$fixture")"
		source "$fixture/tasks.sh" > /dev/null
		# TW generates Recurrence instances only when a report runs.
		task list > /dev/null
		sqlite3 "$replica/taskchampion.sqlite3" "
			SELECT json_group_object(uuid, json_object(
				'properties', json(data),
				'workingSetID', (SELECT id FROM working_set WHERE working_set.uuid = tasks.uuid)
			)) FROM tasks
		" | python3 -m json.tool --sort-keys --tab > "$fixture/tasks.json"
		date +%s > "$fixture/now"
		task export > "$fixture/export.json"
		task +BLOCKED _uuids | sort > "$fixture/blocked"
		task +BLOCKING _uuids | sort > "$fixture/blocking"
		task status:recurring or +TEMPLATE _uuids | sort > "$fixture/templates"
	done

	# Each `case_<name>` in a write fixture's `cases.sh` builds a fresh Replica under its `taskrc`,
	# in UTC, then runs one write with `act`, or with `refuse` where `task` must refuse it.
	# `<name>.json` records the second it ran in, the Replica's properties before and after, and the
	# operations the write committed, which `WritePlannerTests` plans the same write against. A case
	# that straddles a second is retried, so every stamp the case makes is `now`, or the recording
	# fails.
	properties() {
		sqlite3 "$replica/taskchampion.sqlite3" \
			"SELECT coalesce(json_group_object(uuid, json(data)), '{}') FROM tasks"
	}
	snapshot() {
		last=0
		if [ ! -d "$replica" ]; then
			echo '{}' > "$scratch/before"
			return
		fi
		properties > "$scratch/before"
		last="$(sqlite3 "$replica/taskchampion.sqlite3" "SELECT coalesce(max(id), 0) FROM operations")"
	}
	# The operations after the snapshot's, rather than since the newest Undo point: a refused write
	# pushes none, so that would record the previous command's. The Undo point itself is left out.
	record() {
		properties > "$scratch/after"
		sqlite3 "$replica/taskchampion.sqlite3" "
			SELECT json_group_array(json(data)) FROM (
				SELECT data FROM operations
				WHERE id > $last AND data != '\"UndoPoint\"'
				ORDER BY id
			)
		" > "$scratch/operations"
	}
	act() {
		snapshot
		task "$@"
		record
	}
	refuse() {
		snapshot
		if task "$@"; then
			echo "task accepted \`$*\`, which the case expects it to refuse" >&2
			return 1
		fi
		record
	}
	for fixture in "$PWD"/Tests/ModelsTests/WriteFixtures/*/; do
		replica="$taskdata/writes"
		source "$fixture/cases.sh"
		cases=($(declare -F | sed -n 's/^declare -f case_//p'))
		for case in "${cases[@]}"; do
			for attempt in {1..5}; do
				rm -rf "$replica"
				now="$(date +%s)"
				"case_$case" > /dev/null
				[ "$(date +%s)" = "$now" ] && break
				if [ "$attempt" = 5 ]; then
					echo "every run of $case in $fixture straddled a second" >&2
					exit 1
				fi
			done
			python3 - "$now" "$scratch" > "$fixture/$case.json" <<-'PYTHON'
				import json, pathlib, sys
				now, scratch = int(sys.argv[1]), pathlib.Path(sys.argv[2])
				recording = {
					name: json.loads((scratch / name).read_text())
					for name in ["after", "before", "operations"]
				}
				recording["now"] = now
				print(json.dumps(recording, indent="\t", sort_keys=True))
			PYTHON
		done
		for case in "${cases[@]}"; do unset -f "case_$case"; done
	done

	# Each line of `DateFixtures/inputs` is one `attribute:value` argument, added to a fresh Replica
	# after fixed `scheduled`, `review` and `span` values for it to reference. `expected` records,
	# for each of the fixture's `zones`, the second the add ran in and what TW stored, or nothing
	# where it refused the input. An add that straddles a second is retried, so relative inputs
	# resolve against the recorded second, or the recording fails.
	dates="$PWD/Tests/ModelsTests/DateFixtures"
	for fixture in "$dates"/*/; do
		replica="$taskdata/dates"
		: > "$fixture/expected"
		while IFS= read -r zone; do
			while IFS= read -r input; do
				attribute="${input%%:*}"
				for attempt in {1..5}; do
					rm -rf "$replica"
					before="$(date +%s)"
					stored=""
					if (
						cd "$scratch"
						env -i HOME=/home/fixture TZ="$zone" TASKDATA="$replica" \
							TASKRC="$fixture/taskrc" "$task" rc.confirmation=0 rc.hooks=0 \
							rc.verbose=nothing add probe scheduled:1790845200 review:1791000000 \
							span:P2D "$input"
					) > /dev/null 2>&1; then
						stored="$(sqlite3 "$replica/taskchampion.sqlite3" \
							"SELECT json_extract(data, '\$.$attribute') FROM tasks")"
					fi
					[ "$(date +%s)" = "$before" ] && break
					if [ "$attempt" = 5 ]; then
						echo "every add of $input in $zone straddled a second" >&2
						exit 1
					fi
				done
				printf '%s\t%s\t%s\t%s\n' "$zone" "$before" "$input" "$stored" >> "$fixture/expected"
			done < "$dates/inputs"
		done < "$fixture/zones"
	done

# Edit the Tuist manifests in Xcode
edit:
	tuist edit

# Build the app
build: ensure-generated
	just xcodebuild-strict -allowProvisioningUpdates build

# Run the test plan (all package test targets)
test: ensure-generated
	just xcodebuild-strict CODE_SIGNING_ALLOWED=NO test

# `treatAllWarnings` can't catch every warning: Swift 6.4 downgrades a nonisolated
# call into AppKit's imported main actor API to a warning that
# `-warnings-as-errors` leaves alone. So this fails on any warning the raw log
# locates in our own sources, whose directories leave out the dependencies'
# checkouts under `.build`.
#
# It sees only what this run compiled, so an incremental build passes over a
# warning in an unchanged file. CI builds from scratch and sees them all.
[positional-arguments]
[private]
xcodebuild-strict *args:
	#!/usr/bin/env bash
	set -euo pipefail

	log="$(mktemp)"
	trap 'rm -f "$log"' EXIT
	xcodebuild -workspace {{ workspace }} -scheme {{ scheme }} -destination '{{ destination }}' \
		-derivedDataPath {{ derived_data }} "$@" 2>&1 | tee "$log" | xcbeautify

	# The physical path, as the compiler reports it, so a symlinked checkout still
	# matches. `index` rather than a regex, since a worktree path can hold regex
	# syntax such as a branch's `fix(ci)` scope.
	warnings="$(awk -v root="$(pwd -P)/" '
		index($0, root) != 1 { next }
		{ path = substr($0, length(root) + 1) }
		path ~ /^(AppHost|Sources|Tests)\/[^:]+:[0-9]+:[0-9]+: warning: / { print path }
	' "$log" | sort -u)"
	if [ -n "$warnings" ]; then
		printf 'warnings in our sources:\n%s\n' "$warnings" >&2
		exit 1
	fi

# Build (signed) and launch the app
run: build
	#!/usr/bin/env bash
	set -euo pipefail

	# `build` above put the app under the pinned derived data, so the path is
	# known and needs no second xcodebuild to ask for it — that query re-resolves
	# the package graph.
	#
	# The guard is not checking whether the build succeeded (pipefail already
	# did) but whether the product still lands where this line says, which a
	# scheme or configuration change would quietly move.
	app="{{ derived_data }}/Build/Products/Debug/{{ debug_product }}.app"
	if [ ! -d "$app" ]; then
		echo "no app at $app — \`just build\` should have produced it" >&2
		exit 1
	fi

	# `open` only activates a copy that is already running, so quit the previous
	# dev build first. Matching the exact executable path spares a copy built
	# elsewhere and anything else that merely names the path.
	binary="$PWD/$app/Contents/MacOS/{{ debug_product }}"
	running() {
		for pid in $(pgrep -x "{{ debug_product }}"); do
			[ "$(ps -o comm= -p "$pid")" = "$binary" ] && echo "$pid"
		done
		return 0
	}
	pids="$(running)"
	if [ -n "$pids" ]; then
		kill $pids
		# Up to five seconds for it to exit.
		for _ in {1..50}; do
			[ -z "$(running)" ] && break
			sleep 0.1
		done
		if [ -n "$(running)" ]; then
			echo "the previous {{ debug_product }} is still running; quit it and retry" >&2
			exit 1
		fi
	fi

	open "$app"

# Interactive — prompts for an App Store Connect API key (recommended) or your
# Apple ID + an app-specific password (appleid.apple.com ▸ Sign-In and Security
# ▸ App-Specific Passwords). Stored under the `{{ notary_profile }}` profile.
# One-time setup for `release` and `publish`: store notarization credentials
notary-setup:
	xcrun notarytool store-credentials {{ notary_profile }} --team-id "${TUIST_DEVELOPMENT_TEAM:?set TUIST_DEVELOPMENT_TEAM in your shell profile}"

# Archives the app and exports it with Developer ID to `release_app`. The build
# number counts the commits reaching HEAD, which only grows along `main` while
# it is never rewritten; Sparkle orders releases by it. `version` stamps the
# marketing version over the manifest's development default.
[private]
archive version="": ensure-generated
	#!/usr/bin/env bash
	set -euo pipefail

	team="${TUIST_DEVELOPMENT_TEAM:?set TUIST_DEVELOPMENT_TEAM in your shell profile}"
	archive="{{ release_dir }}/{{ scheme }}.xcarchive"
	options="{{ release_dir }}/ExportOptions.plist"
	versioning=("CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD)")
	if [ -n "{{ version }}" ]; then
		versioning+=("MARKETING_VERSION={{ version }}")
	fi

	rm -rf "{{ release_dir }}"
	mkdir -p "{{ release_dir }}"

	echo "==> Archiving"
	xcodebuild archive \
		-workspace {{ workspace }} -scheme {{ scheme }} \
		-destination 'generic/platform=macOS' \
		-archivePath "$archive" \
		-allowProvisioningUpdates "${versioning[@]}" | xcbeautify

	echo "==> Exporting (Developer ID)"
	cat > "$options" <<-PLIST
		<?xml version="1.0" encoding="UTF-8"?>
		<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
		<plist version="1.0">
		<dict>
			<key>method</key>
			<string>developer-id</string>
			<key>teamID</key>
			<string>$team</string>
			<key>signingStyle</key>
			<string>manual</string>
			<key>signingCertificate</key>
			<string>Developer ID Application</string>
		</dict>
		</plist>
	PLIST
	xcodebuild -exportArchive \
		-archivePath "$archive" \
		-exportPath "{{ parent_directory(release_app) }}" \
		-exportOptionsPlist "$options" | xcbeautify

# Run `just notary-setup` once first. By default the running app is quit and the
# freshly notarized one launched; pass `false` to skip that:
#   just release          # quit old, install, launch new (default)
#   just release false    # install only, don't touch the running app
# Archive, notarize (Developer ID), and install to /Applications
release quit_and_launch="true": archive
	#!/usr/bin/env bash
	set -euo pipefail

	app="{{ release_app }}"
	zip="{{ release_zip }}"
	dest="/Applications/{{ scheme }}.app"

	echo "==> Notarizing (waiting for Apple — this can take a few minutes)"
	ditto -c -k --keepParent "$app" "$zip"
	xcrun notarytool submit "$zip" --keychain-profile {{ notary_profile }} --wait

	echo "==> Stapling notarization ticket"
	xcrun stapler staple "$app"

	if [ "{{ quit_and_launch }}" = "true" ]; then
		echo "==> Quitting running {{ scheme }}"
		osascript -e 'tell application "{{ scheme }}" to quit' 2>/dev/null || true
		sleep 1
		pkill -x "{{ scheme }}" 2>/dev/null || true
	fi

	echo "==> Installing to $dest"
	rm -rf "$dest"
	ditto "$app" "$dest"

	if [ "{{ quit_and_launch }}" = "true" ]; then
		echo "==> Launching"
		open "$dest"
	fi

	echo "✅ Released {{ scheme }} → $dest"

# Refuses a version that isn't a clean `main` commit tagged `vX.Y.Z` here and on
# origin, and newer than every other release. Checked before the minutes of
# archiving and notarizing, rather than left to
# `gh release create --verify-tag` at the end.
[private]
check-tag version:
	#!/usr/bin/env bash
	set -euo pipefail

	tag="v{{ version }}"
	if [[ ! "{{ version }}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "the version is X.Y.Z, not {{ version }}" >&2
		exit 1
	fi
	if [ -n "$(git status --porcelain)" ]; then
		echo "the working tree has changes the tag doesn't" >&2
		exit 1
	fi
	if [ "$(git rev-parse -q --verify "refs/tags/$tag^{commit}")" != "$(git rev-parse HEAD)" ]; then
		echo "$tag isn't a tag on HEAD" >&2
		exit 1
	fi
	remote="$(git ls-remote --tags origin "refs/tags/$tag" | cut -f1)"
	if [ "$remote" != "$(git rev-parse "refs/tags/$tag")" ]; then
		echo "$tag isn't on origin as it is here: push it first" >&2
		exit 1
	fi
	# Off `main`, the commit count stops ordering releases.
	git fetch --quiet origin main
	if ! git merge-base --is-ancestor HEAD origin/main; then
		echo "HEAD isn't on origin/main" >&2
		exit 1
	fi

	# Sparkle upgrades only to a higher build number, the commit count `archive`
	# stamps, so HEAD's must exceed every other release's. Releases are origin's
	# `vX.Y.Z` tags, each with the commit it peels to, rather than local tags,
	# which can be stale. Captured first so a failing git stops the check.
	build="$(git rev-list --count HEAD)"
	releases="$(git ls-remote --tags origin 'refs/tags/v*' | awk '
		{ name = $2; sub("^refs/tags/", "", name); sub(/\^\{\}$/, "", name); commit[name] = $1 }
		END { for (name in commit) if (name ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) print name, commit[name] }
	')"
	while read -r other commit; do
		[ -z "$other" ] && continue
		[ "$other" = "$tag" ] && continue
		# Only a tag on `main` can have been published.
		git merge-base --is-ancestor "$commit" origin/main || continue
		count="$(git rev-list --count "$commit")"
		if [ "$count" -ge "$build" ]; then
			echo "$other is built at $count, not below HEAD's $build" >&2
			exit 1
		fi
	done <<< "$releases"

# Run `just notary-setup` once first, then tag HEAD `v<version>` and push the
# tag. Never installs, quits or launches the app. The zip is what Sparkle
# updates from; the DMG is for downloading by hand.
# Archive, notarize, and publish a zip and DMG as release `v<version>`
publish version: (check-tag version) (archive version)
	#!/usr/bin/env bash
	set -euo pipefail

	tag="v{{ version }}"
	app="{{ release_app }}"
	dmg="{{ release_dir }}/{{ scheme }}.dmg"
	staging="{{ release_dir }}/dmg"
	unzipped="{{ release_dir }}/unzipped"
	zip="{{ release_zip }}"

	echo "==> Building the DMG"
	mkdir "$staging"
	ditto "$app" "$staging/{{ scheme }}.app"
	ln -s /Applications "$staging/Applications"
	diskutil image create from --volumeName {{ scheme }} "$staging" "$dmg"
	# Signed by the certificate the export chose for the app.
	identity="$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
	if [ -z "$identity" ]; then
		echo "$app has no signing identity to sign the DMG with" >&2
		exit 1
	fi
	codesign --sign "$identity" --timestamp "$dmg"

	# One submission covers the DMG and the app inside it, which is the exported
	# app unchanged, so its ticket staples to both.
	echo "==> Notarizing (waiting for Apple — this can take a few minutes)"
	xcrun notarytool submit "$dmg" --keychain-profile {{ notary_profile }} --wait

	echo "==> Stapling and checking"
	xcrun stapler staple "$dmg"
	xcrun stapler staple "$app"
	xcrun stapler validate "$dmg"
	xcrun stapler validate "$app"
	spctl -a -vv -t open --context context:primary-signature "$dmg"
	spctl -a -vv -t exec "$app"

	# Zipped after stapling, so the ticket travels with the app for offline use,
	# and checked as it comes back out.
	ditto -c -k --keepParent "$app" "$zip"
	ditto -x -k "$zip" "$unzipped"
	xcrun stapler validate "$unzipped/{{ scheme }}.app"
	spctl -a -vv -t exec "$unzipped/{{ scheme }}.app"

	echo "==> Publishing $tag"
	gh release create "$tag" --verify-tag --generate-notes "$zip" "$dmg"

	echo "✅ Published {{ scheme }} $tag"

# Fetched rather than vendored, but at most once a day: this is a dependency of
# `format-staged`, which the pre-commit hook runs on every commit, so an
# unconditional fetch would put GitHub on the commit path.
#
# `-f` is load-bearing. Without it curl exits 0 on a 404 and writes the error body
# into the config file, and swiftformat then reformats the whole tree against
# `404: Not Found` from inside the pre-commit hook — silently, since the hook
# stays green. Verified.
[private]
fetch-swiftformat-config:
	#!/usr/bin/env bash
	set -euo pipefail

	# Fresh enough: nothing to do. `find -mmin` is a single stat on one file.
	if [ -n "$(find {{ swiftformat_base }} -mmin -1440 2>/dev/null)" ]; then
		exit 0
	fi

	# Per-invocation, because the cache path is shared by every clone and worktree
	# of this repo. Given a single hardcoded temp name instead, two concurrent hooks
	# write the same file, the first `mv` hands the half-written result over as the
	# live config, and the second `mv` then fails on a name that is already gone.
	# The trap covers every exit below, so no temp file outlives the recipe.
	#
	# `mv` carries the temp file's mode across, so the cache lands 0600 rather than
	# the 0644 `curl -o` gave it under the default umask. That is the right way
	# round for a per-user cache sitting in a world-writable directory.
	tmp="$(mktemp {{ swiftformat_base }}.XXXXXX)"
	trap 'rm -f "$tmp"' EXIT

	if curl -sfL --retry 2 --max-time 10 {{ swiftformat_url }} -o "$tmp"; then
		# Same filesystem, so this is an atomic rename: a concurrent reader sees the
		# old config or the new one, never a partial write.
		mv "$tmp" {{ swiftformat_base }}
		exit 0
	fi

	# Offline, or the config moved. A stale copy still formats correctly enough to
	# commit against; no copy at all cannot, so that is the one hard failure.
	if [ ! -f {{ swiftformat_base }} ]; then
		echo "cannot reach {{ swiftformat_url }} and no cached config at {{ swiftformat_base }}." >&2
		exit 1
	fi

	# The mtime records the last *attempt*, not when the contents arrived. Without
	# this a failed refresh leaves the stale copy stale, so every commit from here
	# on reaches the curl above and an offline one pays the timeout each time —
	# exactly what the daily cache exists to prevent. Nothing reads this mtime but
	# the staleness test at the top.
	touch {{ swiftformat_base }}

# Format code with SwiftFormat
format: fetch-swiftformat-config
	mint run swiftformat . --base-config {{ swiftformat_base }}

# Format only the staged Swift hunks (used by the lefthook pre-commit hook)
[private]
format-staged: fetch-swiftformat-config
	#!/usr/bin/env bash
	# `mint which` writes the path to stdout and its failures to stderr, so piping
	# it into `tail` without pipefail swallows a 127 and yields an empty string. The
	# formatter command would then start with a bare ` stdin`, and the pre-commit
	# hook would pass while formatting nothing at all. The assignment sits in the
	# `if` condition so `set -e` does not abort on it before the message is printed.
	set -euo pipefail

	if ! formatter="$(mint which swiftformat | tail -1)" || [ -z "$formatter" ]; then
		echo "swiftformat not installed — run \`just tools\`." >&2
		exit 1
	fi

	git-format-staged \
		--formatter "$formatter stdin --stdinpath '{}' --base-config {{ swiftformat_base }}" \
		"*.swift"

# Install git hooks via lefthook
install-hooks:
	lefthook install

# Install developer tools (mint packages + git hooks)
tools:
	# `brew bundle` first: it installs git-format-staged, which the hook
	# `just install-hooks` wires up then shells out to on every commit.
	brew bundle install
	mint bootstrap
	just install-hooks

# Run SwiftLint
lint:
	# `--config` is load-bearing, not decoration. With the config merely
	# discovered, SwiftLint treats a failed `parent_config` fetch as a warning,
	# falls back to its own built-in defaults and exits 0 — a gate that lints
	# nothing we asked for. Naming the file explicitly takes SwiftLint's
	# "explicitly specified ... -> fail" path instead. Verified on 0.65.1:
	# identical rule set (260 rows of `swiftlint rules`), exit 134 when the
	# config cannot load, and still exit 0 when it falls back to a cached copy
	# of our own config.
	#
	# Pass this one file, not the parent and child separately: two `--config`
	# arguments silently resolve to a *different* rule set — measured, 172 rows
	# of that table flip. The local overrides are inlined into `.swiftlint.yml`
	# for the same reason a second file is a liability: a referenced local
	# config that goes missing is ignored with a warning and a zero exit.
	mint run swiftlint --strict --config .swiftlint.yml

# Remove the SwiftPM build folder, which holds the pinned DerivedData too
clean:
	rm -rf .build
