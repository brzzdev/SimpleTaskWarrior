# Sourced by `just fixtures`. Each `case_<name>` builds a fresh Replica with `task`, with a daily
# Series whose template a report has generated three instances of, then deletes or changes one with
# `act`, all within one second.

# A daily Series due two days ago, so the template generates an instance for each day since.
series() {
	task add Alpha due:today-2d recur:daily
	task list
}

# The Series' instances.
instances() {
	task +INSTANCE _uuids
}

case_add_tag_to_series() {
	series
	act "$(instances | head -1)" modify +work
}

case_annotate_series() {
	series
	act "$(instances | head -1)" annotate Note
}

case_delete_series() {
	series
	act "$(instances | head -1)" delete
}

case_delete_series_with_completed_and_waiting() {
	series
	instances=($(instances))
	task "${instances[1]}" done
	# Only this instance, where the Taskrc would cascade the edit to the Series.
	task rc.recurrence.confirmation=no "${instances[2]}" modify wait:2030-01-01
	act "${instances[0]}" delete
}

case_set_description_of_series_with_completed_and_waiting() {
	series
	instances=($(instances))
	task "${instances[1]}" done
	task rc.recurrence.confirmation=no "${instances[2]}" modify wait:2030-01-01
	act "${instances[0]}" modify description:Beta
}

case_set_until_of_series() {
	series
	act "$(instances | head -1)" modify until:2030-01-01
}
