# Write fixtures

`just fixtures` runs each `case_<name>` in a fixture's `cases.sh` against a fresh Replica under that
fixture's `taskrc`, and records `<name>.json`: the second it ran in, every task's properties before
and after the write, and the operations `task` 3.5 committed for it. `WritePlannerTests` plans the
same write and expects the same changes, with `status` last, except where the app departs from the
CLI on purpose:

- **UDA defaults.** A date or duration `uda.<name>.default`, such as `tomorrow` or `90min`, resolves
  to a real value when a task is created. The CLI stores the text, which `task export` then drops.
- **Context writes.** Only a Context's `project:` and `+tag` modifications apply to a new task. The
  plan reports any other, such as `priority:H`, rather than applying it.
- **Numbers.** A numeric value is stored as an integer when it's whole, and otherwise with six
  significant digits. The CLI stores a whole number typed with a point, such as `1234567.0`, in the
  six-digit form too (`1.23457e+06`).

Operation order within a task, and the CLI's second `modified` update, aren't compared: TW never
reads either.
