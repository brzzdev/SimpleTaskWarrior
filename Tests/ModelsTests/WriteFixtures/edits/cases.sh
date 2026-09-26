# Sourced by `just fixtures`. Each `case_<name>` builds a fresh Replica with `task`, then runs the
# write under test with `act`, or `refuse` where `task` must refuse it, all within one second.

case_add() {
	act add Alpha
}

case_add_annotation() {
	task add Alpha
	act 1 annotate Note
}

case_add_annotation_in_a_taken_second() {
	task add Alpha
	task 1 annotate First
	act 1 annotate Second
}

case_add_dependency() {
	task add Alpha
	task add Beta
	task add Gamma
	task 1 modify depends:3
	act 1 modify depends:2
}

case_add_tag() {
	task add Alpha +home
	act 1 modify +Work
}

case_complete() {
	task add Alpha
	act 1 done
}

case_complete_several() {
	task add Alpha
	task add Beta
	act 1,2 done
}

case_complete_started() {
	task add Alpha
	task 1 start
	act 1 done
}

case_delete_started() {
	task add Alpha
	task 1 start
	act 1 delete
}

case_mark_completed_pending() {
	task add Alpha
	task 1 done
	act "$(task +LATEST _uuids)" modify status:pending
}

case_mark_deleted_pending() {
	task add Alpha
	task 1 start
	task 1 delete
	act "$(task +LATEST _uuids)" modify status:pending
}

case_remove_annotation() {
	task add Alpha
	task 1 annotate Note
	act 1 denotate Note
}

case_remove_dependency() {
	task add Alpha
	task add Beta
	task 1 modify depends:2
	act 1 modify depends:-2
}

case_remove_last_tag() {
	task add Alpha +home
	act 1 modify -home
}

case_remove_project() {
	task add Alpha project:Home
	act 1 modify project:
}

case_remove_tag() {
	task add Alpha +home +Work
	act 1 modify -home
}

case_remove_wait() {
	task add Alpha wait:2030-01-01
	act 1 modify wait:
}

case_set_description() {
	task add Alpha
	act 1 modify Beta
}

case_set_duration() {
	task add Alpha
	act 1 modify estimate:90min
}

case_set_integer() {
	task add Alpha
	act 1 modify size:1234567
}

case_set_project() {
	task add Alpha
	act 1 modify project:Home.garden
}

case_set_real() {
	task add Alpha
	act 1 modify size:4.50
}

case_set_real_past_six_digits() {
	task add Alpha
	act 1 modify size:3.14159265
}

case_set_uda_date() {
	task add Alpha
	act 1 modify review:2030-01-01
}

case_set_wait() {
	task add Alpha
	act 1 modify wait:2030-01-01
}

case_start() {
	task add Alpha
	act 1 start
}

case_start_completed() {
	task add Alpha
	task 1 done
	act "$(task +LATEST _uuids)" start
}

case_start_deleted() {
	task add Alpha
	task 1 delete
	act "$(task +LATEST _uuids)" start
}

case_start_deleted_while_started() {
	task add Alpha
	task 1 start
	task 1 delete
	refuse "$(task +LATEST _uuids)" start
}

case_stop() {
	task add Alpha
	task 1 start
	act 1 stop
}
