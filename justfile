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
# `release` deliberately does not pin it — a notarised build has no business
# reusing an incremental dev cache.
derived_data := ".build/xcode"
# Repo-scoped because a path shared across repos lets two checkouts on different
# config revisions fight over one file, each overwriting the other's mid-commit.
swiftformat_base := "/tmp/swiftformat-base-SimpleTaskWarrior"
swiftformat_url := "https://raw.githubusercontent.com/brzzdev/Configs/main/Configs/swiftformat"
notary_profile := "SimpleTaskWarrior"
release_dir := ".release"

# List available recipes
default:
	@just --list

# Regenerates the bindings in `Sources/Engine` and assembles
# `Engine/build/EngineFFI.xcframework`. Xcode.app has no build phase for this
# (cargo in a script phase fights the user-script sandbox), so run it after
# pulling engine changes.
# Build the Rust engine, its Swift bindings and the xcframework
engine:
	#!/usr/bin/env bash
	set -euo pipefail

	# The Brewfile's rustup is keg-only, so it is off PATH unless the shell put it
	# there. Prepended, because Homebrew's `rust` formula puts a cargo in
	# /opt/homebrew/bin that ignores rust-toolchain.toml; rustup's proxies honour it.
	export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
	cd Engine
	target=aarch64-apple-darwin
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

# Each fixture's `expected.rc` is what `task _show` prints for its `taskrc`,
# which `TaskrcTests` compares the parser against. The environment is fixed to
# the one the tests expand with, and `task` runs from an empty directory so no
# include resolves against the CWD, which the app ignores.
# Record the golden Taskrc fixtures from real `task` 3.5
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
	if [ -e "$taskdata" ]; then
		echo "$taskdata already exists; remove it or wait for the other recording" >&2
		exit 1
	fi
	scratch="$(mktemp -d)"
	trap 'rm -rf "$scratch" "$taskdata"' EXIT
	for fixture in "$PWD"/Tests/TaskrcTests/Fixtures/*/; do
		(
			cd "$scratch"
			env -i HOME=/home/fixture USER=fixture FIXTURE=value \
				TASKDATA="$taskdata" TASKRC="$fixture/taskrc" "$task" _show
		) > "$fixture/expected.rc"
	done

# Edit the Tuist manifests in Xcode
edit:
	tuist edit

# Build the app
build: ensure-generated
	xcodebuild -workspace {{ workspace }} -scheme {{ scheme }} -destination '{{ destination }}' -allowProvisioningUpdates -derivedDataPath {{ derived_data }} build | xcbeautify

# Run the test plan (all package test targets)
test: ensure-generated
	xcodebuild -workspace {{ workspace }} -scheme {{ scheme }} -destination '{{ destination }}' CODE_SIGNING_ALLOWED=NO -derivedDataPath {{ derived_data }} test | xcbeautify

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
	app="{{ derived_data }}/Build/Products/Debug/{{ scheme }}.app"
	if [ ! -d "$app" ]; then
		echo "no app at $app — \`just build\` should have produced it" >&2
		exit 1
	fi

	# `open` only activates a copy that is already running, so quit the previous
	# dev build first. Matching the exact executable path spares an installed
	# release copy and anything else that merely names the path.
	binary="$PWD/$app/Contents/MacOS/{{ scheme }}"
	running() {
		for pid in $(pgrep -x {{ scheme }}); do
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
			echo "the previous {{ scheme }} is still running; quit it and retry" >&2
			exit 1
		fi
	fi

	open "$app"

# Interactive — prompts for an App Store Connect API key (recommended) or your
# Apple ID + an app-specific password (appleid.apple.com ▸ Sign-In and Security
# ▸ App-Specific Passwords). Stored under the `{{ notary_profile }}` profile.
# One-time setup for `just release`: store Apple notarization credentials
notary-setup:
	xcrun notarytool store-credentials {{ notary_profile }} --team-id "${TUIST_DEVELOPMENT_TEAM:?set TUIST_DEVELOPMENT_TEAM in your shell profile}"

# Run `just notary-setup` once first. By default the running app is quit and the
# freshly notarized one launched; pass `false` to skip that:
#   just release          # quit old, install, launch new (default)
#   just release false    # install only, don't touch the running app
# Archive, notarize (Developer ID), and install to /Applications
release quit_and_launch="true": ensure-generated
	#!/usr/bin/env bash
	set -euo pipefail

	team="${TUIST_DEVELOPMENT_TEAM:?set TUIST_DEVELOPMENT_TEAM in your shell profile}"
	archive="{{ release_dir }}/{{ scheme }}.xcarchive"
	export_dir="{{ release_dir }}/export"
	options="{{ release_dir }}/ExportOptions.plist"
	app="$export_dir/{{ scheme }}.app"
	zip="{{ release_dir }}/{{ scheme }}.zip"
	dest="/Applications/{{ scheme }}.app"

	rm -rf "{{ release_dir }}"
	mkdir -p "{{ release_dir }}"

	echo "==> Archiving"
	xcodebuild archive \
		-workspace {{ workspace }} -scheme {{ scheme }} \
		-destination 'generic/platform=macOS' \
		-archivePath "$archive" \
		-allowProvisioningUpdates | xcbeautify

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
		-exportPath "$export_dir" \
		-exportOptionsPlist "$options" | xcbeautify

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
