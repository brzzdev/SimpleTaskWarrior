#!/bin/zsh
# Races the sandboxed spike app against the `task` CLI on one scratch Replica.
# Usage: drive.sh <lab dir>, after ./app/build.sh and `open -a build/STWSpike.app <lab>/replica`.
set -uo pipefail
zmodload zsh/datetime
lab=$1
db=$lab/replica/taskchampion.sqlite3
export TASKRC=$lab/taskrc
task() { command task rc.verbose=nothing "$@" }

applog() { /usr/bin/log show --last ${1:-15s} --predicate 'subsystem == "me.brzz.stwspike"' --style compact | tail -n +2 | cut -c12-23,58- }
app() { open -g "stwspike://$1" }
hold() { (print "BEGIN IMMEDIATE;"; sleep $1; print "COMMIT;") | /usr/bin/sqlite3 $db }
timed() { local start=$EPOCHREALTIME; "$@"; local code=$?; printf '  → exit %d in %.2fs\n' $code $((EPOCHREALTIME - start)) }

print "## 1. CLI write, app notices via data_version"
task add cli-1 >/dev/null; sleep 1; applog 3s

print "\n## 2. App write, CLI reads it back"
app 'add?d=app-1'; sleep 1; applog 3s
task rc.verbose=nothing status:pending export | jq -c '.[] | select(.description=="app-1") | {id, status, entry, modified, uuid}'

print "\n## 3. App commits while another process holds the write lock"
for seconds in 2 7; do
	print "### lock held ${seconds}s"
	hold $seconds & sleep 0.3
	app "add?d=app-during-${seconds}s-lock"; wait; sleep 1; applog $((seconds + 3))s | grep -E "add|failed"
done

print "\n## 4. CLI commits while the app holds the write lock"
for seconds in 2 7; do
	print "### app holds ${seconds}s"
	app "hold?s=$seconds"; sleep 0.5
	timed task add "cli-during-${seconds}s-app-lock"
	sleep $((seconds)); applog $((seconds + 3))s | grep hold
done

print "\n## 5. Interleaved storm: 25 CLI adds and 25 app adds at once"
(for i in {1..25}; do task add storm-cli-$i >/dev/null 2>>$lab/storm.err || print "cli-$i failed" >>$lab/storm.err; done) &
for i in {1..25}; do app "add?d=storm-app-$i"; sleep 0.05; done
wait; sleep 2
print "CLI errors: $(cat $lab/storm.err 2>/dev/null | wc -l | tr -d ' ')"
print "App failures: $(applog 30s | grep -c 'storm.*failed')"
print "Tasks via CLI: $(task rc.verbose=nothing status:pending export | jq '[.[] | select(.description|startswith("storm"))] | length') of 50"
print "App's last seen pending count: $(applog 30s | grep data_version | tail -1 | grep -o 'storm' | wc -l | tr -d ' ') storm tasks"
/usr/bin/sqlite3 $db 'PRAGMA integrity_check;'
