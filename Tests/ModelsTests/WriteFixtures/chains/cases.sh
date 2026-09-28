# Sourced by `just fixtures`. Each `case_<name>` builds a fresh Replica with `task`, then runs the
# write under test with `act`, all within one second. The Taskrc repairs every broken chain.

case_complete_already_depending() {
	task add Alpha
	task add Beta
	task add Gamma
	task 1 modify depends:2,3
	task 2 modify depends:3
	act 2 done
}

case_complete_declined() {
	task add Alpha
	task add Beta
	task add Gamma
	task 1 modify depends:2
	task 2 modify depends:3
	# `task` reads no answer from an empty stdin, so it leaves the chain.
	act rc.dependency.confirmation=on 2 done < /dev/null
}

case_complete_fanned() {
	task add Alpha
	task add Beta
	task add Gamma
	task add Delta
	task add Epsilon
	task 1,4 modify depends:2
	task 2 modify depends:3,5
	act 2 done
}

case_complete_middle() {
	task add Alpha
	task add Beta
	task add Gamma
	task 1 modify depends:2
	task 2 modify depends:3
	act 2 done
}

case_complete_several() {
	task add Alpha
	task add Beta
	task add Gamma
	task add Delta
	task 1 modify depends:2
	task 2 modify depends:3
	task 3 modify depends:4
	act 2,3 done
}

case_complete_with_closed_ends() {
	task add Alpha
	task add Beta
	task add Gamma
	task add Delta
	task add Epsilon
	task 1,4 modify depends:2
	task 2 modify depends:3,5
	task 1,3 done
	act 2 done
}

case_complete_with_template_dependent() {
	task add Beta
	task add Gamma
	task 1 modify depends:2
	task add Alpha due:2030-01-01 recur:weekly depends:1
	act 1 done
}

case_delete_completed() {
	task add Alpha
	task add Beta
	task add Gamma
	task 1 modify depends:2
	task 2 modify depends:3
	task rc.dependency.confirmation=on 2 done < /dev/null
	# `task` means to repair the chain, but looks the dependency up by a completed task's ID, 0, and
	# fails having deleted it, so the chain stays: the task stopped blocking when it was completed.
	act "$(task status:completed _uuids)" delete || :
}

case_delete_middle() {
	task add Alpha
	task add Beta
	task add Gamma
	task 1 modify depends:2
	task 2 modify depends:3
	act 2 delete
}
