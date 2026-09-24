# Date input fixtures

`just fixtures` records what `task` 3.5 stores for each line of `inputs`, under each fixture's
`taskrc` and in each of its `zones`, into `expected`: the zone, the second the input was added in,
the input, and the stored value, which is empty where `task` refused the input. `DateInputTests`
reads every input back through `DateInput` and expects the same result, except where the app departs
from the CLI on purpose:

- **Holidays.** `easter`, `eastermonday`, `goodfriday`, `ascension`, `pentecost`, `midsommar`,
  `midsommarafton` and `juhannus` are refused rather than resolved.
- **Booleans.** `true`, `false`, comparisons and logic in an expression are refused. The CLI turns a
  boolean into the date 0 or 1, which it refuses too, unless more arithmetic follows.
- **UDA defaults.** A date or duration `uda.<name>.default`, such as `tomorrow`, resolves to a real
  value when a task is created. The CLI stores the text, which `task export` then drops. No fixture
  covers this: the parser doesn't read defaults, and whatever applies them does.
