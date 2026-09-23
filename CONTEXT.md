# SimpleTaskWarrior

A native macOS client for Taskwarrior 3 data, where each window works on one replica alongside the `task` CLI.

## Language

**Replica**:
One Taskwarrior 3 data store: the TaskChampion database directory that `TASKDATA` points at. A window shows exactly one.
_Avoid_: File, document, database, task list

**Taskrc**:
The Taskwarrior configuration file paired with a replica, together with the files it includes, supplying its UDA definitions and urgency coefficients.
_Avoid_: Config, settings, rc file

**Context**:
A named pair defined in a taskrc: a read filter narrowing which tasks show, and write modifications applied to new tasks, plus optional overrides of other taskrc settings. At most one is active.
_Avoid_: Workspace, perspective, filter

**UDA**:
A user-defined attribute declared in a taskrc, extending the attributes every task can carry.
_Avoid_: Custom field

**Urgency**:
The computed score that orders tasks, derived from a task's attributes and the taskrc's coefficients; never stored.
_Avoid_: Priority, score

**Recurrence template**:
The hidden task with status `recurring` that defines a repeating task.
_Avoid_: Parent, recurring task

**Recurrence instance**:
A pending task generated from a recurrence template; the only form of a repeating task users work with.
_Avoid_: Occurrence, child
