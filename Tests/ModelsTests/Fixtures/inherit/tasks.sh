# Sourced by `just fixtures` with `task` running against this fixture's Replica.

# Adds a task and prints its UUID.
add() {
	task add "$@"
	task +LATEST _uuids
}

root=$(add Root of the chain)
middle=$(add Middle of the chain depends:"$root")
add Urgent end of the chain due:now-8d +next depends:"$middle"
add Less urgent, blocked by the root depends:"$root"

blocking=$(add Blocking only a completed task)
blocked=$(add Completed while blocked due:now-8d depends:"$blocking")
task "$blocked" done
