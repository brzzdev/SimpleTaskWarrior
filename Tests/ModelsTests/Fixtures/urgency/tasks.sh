# Sourced by `just fixtures` with `task` running against this fixture's Replica.

# Adds a task and prints its UUID.
add() {
	task add "$@"
	task +LATEST _uuids
}

add Plain entry:now-10d
add Older than urgency.age.max entry:now-400d
add Entered in the future entry:now+2d
add Overdue a week due:now-8d
add Overdue due:now-3d
add Due soon due:now+5d
add Due in three weeks due:now+21d
add Due earlier today due:today
add Due later today due:eod
add Due tomorrow due:tomorrow
add Due yesterday due:yesterday
add Due this month due:eom
add Due this quarter due:eoq
add Due this year due:eoy
add Scheduled in the past scheduled:now-1d
add Scheduled in the future scheduled:now+1d
add Waiting wait:now+3d
add Waited wait:now-3d
add Until until:now+30d
add Sub-project project:Home.garden
add Not a sub-project project:Homework
add Fix Bug in keyword
add Fix bug in lowercase keyword
add One tag +a
add Two tags +a +b
add Four tags +a +b +c +later
add Priority high priority:H
add Priority medium priority:M
add Priority low priority:L
add Every UDA area:work estimate:2h link:6f1d4a3c-5b1e-4f7a-9c2d-8e0b1a2c3d4e review:now+1d size:3.5
add Another size size:7
add Orphan rc.uda.note.type=string note:kept

annotated=$(add Annotated three times)
task "$annotated" annotate one
task "$annotated" annotate two
task "$annotated" annotate three
annotated=$(add Annotated once)
task "$annotated" annotate one

active=$(add Active)
task "$active" start

completed=$(add Completed)
task "$completed" done
deleted=$(add Deleted)
task "$deleted" delete

blocker=$(add Blocker)
add Blocked by a pending task depends:"$blocker"
add Blocked by a completed task depends:"$completed"
add Blocked by a deleted task depends:"$deleted"
waiting=$(add Waiting blocker wait:now+2d)
add Blocked by a waiting task depends:"$waiting"
add Waiting and blocked wait:now+2d depends:"$blocker"
blocked=$(add Completed while blocked depends:"$blocker")
task "$blocked" done

add Weekly recur:weekly due:now+1d until:now+30d
weekly=$(task status:recurring description:Weekly _uuids)
add Monthly recur:monthly due:now+2d
monthly=$(task status:recurring description:Monthly _uuids)
task rc.recurrence.confirmation=no "$monthly" delete
add Blocked by a template depends:"$weekly"
