//! A thin facade over TaskChampion for the Swift app. It wraps TaskChampion's primitives and holds
//! no Taskwarrior rules: no `modified` or `end` stamping, no tag or dependency mirrors. Those live in
//! Swift (docs/adr/0001-taskwarrior-rules-live-in-swift.md).

use std::collections::HashMap;
use std::collections::hash_map::Entry;
use std::path::Path;
use std::sync::{Mutex, OnceLock};

use rusqlite::{Connection, OpenFlags, OptionalExtension};
use taskchampion::chrono::DateTime;
use taskchampion::storage::AccessMode;
use taskchampion::{Operation, Operations, Replica, SqliteStorage, TaskData, Uuid};
use tokio::runtime::Runtime;

uniffi::setup_scaffolding!();

const DATABASE_FILE: &str = "taskchampion.sqlite3";

/// How many times a snapshot is retried while the CLI keeps committing under it.
const SNAPSHOT_ATTEMPTS: usize = 5;

/// The schema major version TaskChampion 3.1 reads. TaskChampion refuses a newer major itself, but
/// with an untyped error; gating first lets the app say why.
const SUPPORTED_SCHEMA_MAJOR: u32 = 0;

/// What TaskChampion reads a missing `version` table or row as: a schema from before it versioned.
const UNVERSIONED_SCHEMA: (u32, u32) = (0, 0);

#[derive(Debug, uniffi::Error)]
pub enum EngineError {
	Failed { message: String },
	/// The folder has no TaskChampion database.
	NotAReplica,
	/// The database's schema major version is newer than this engine reads.
	UnsupportedSchema { major: u32, minor: u32 },
}

impl std::fmt::Display for EngineError {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self {
			EngineError::Failed { message } => f.write_str(message),
			EngineError::NotAReplica => f.write_str("the folder has no TaskChampion database"),
			EngineError::UnsupportedSchema { major, minor } => {
				write!(f, "schema version {major}.{minor} is newer than this engine reads")
			}
		}
	}
}

impl<E: std::error::Error> From<E> for EngineError {
	fn from(error: E) -> Self {
		failed(error)
	}
}

fn failed(message: impl ToString) -> EngineError {
	EngineError::Failed {
		message: message.to_string(),
	}
}

/// A coherent read of a Replica: every task and the working set, as of `data_version`.
#[derive(uniffi::Record)]
pub struct Snapshot {
	pub data_version: i64,
	pub tasks: Vec<TaskProperties>,
	pub working_set: Vec<WorkingSetEntry>,
}

/// Named so the generated Swift type doesn't shadow Swift's `Task`.
#[derive(uniffi::Record)]
pub struct TaskProperties {
	pub uuid: String,
	pub properties: HashMap<String, String>,
}

#[derive(uniffi::Record)]
pub struct WorkingSetEntry {
	pub id: u64,
	pub uuid: String,
}

/// One change in a batch passed to `apply`. Each writes exactly what it names.
#[derive(uniffi::Enum)]
pub enum PlannedOperation {
	/// Refused with `Conflict` when the UUID already names a task, including one created earlier in
	/// the batch.
	Create {
		uuid: String,
	},
	/// Writes `status` alone. TaskChampion adds a task to the working set when it becomes pending
	/// or recurring; stamping `end` is the planner's job.
	SetStatus {
		uuid: String,
		status: Status,
	},
	/// Removes the property when `value` is `None`.
	SetValue {
		uuid: String,
		property: String,
		value: Option<String>,
	},
}

#[derive(uniffi::Enum)]
pub enum Status {
	Completed,
	Deleted,
	Pending,
	Recurring,
}

impl Status {
	fn stored_value(&self) -> &'static str {
		match self {
			Status::Completed => "completed",
			Status::Deleted => "deleted",
			Status::Pending => "pending",
			Status::Recurring => "recurring",
		}
	}
}

/// A value the planner read, which must still hold for its plan to commit. A missing task reads
/// every property as `None`.
#[derive(uniffi::Record)]
pub struct Expectation {
	pub uuid: String,
	pub property: String,
	pub value: Option<String>,
}

#[derive(uniffi::Enum)]
pub enum ApplyOutcome {
	Committed,
	/// Nothing was committed, because these tasks no longer match the expectations, or already
	/// exist where the batch creates them.
	Conflict { uuids: Vec<String> },
}

/// TaskChampion's `Operation`, renamed so the generated Swift type doesn't shadow Foundation's.
/// Pass these back to `commit_reversed_operations` unchanged: TaskChampion reverses them only when
/// they equal its newest undo operations exactly, timestamps included, which is why the timestamp
/// crosses as integer nanoseconds rather than a lossy `Date`.
#[derive(uniffi::Enum)]
pub enum UndoOperation {
	Create {
		uuid: String,
	},
	Delete {
		uuid: String,
		old_task: HashMap<String, String>,
	},
	UndoPoint,
	Update {
		uuid: String,
		property: String,
		old_value: Option<String>,
		value: Option<String>,
		timestamp_nanoseconds: i64,
	},
}

impl TryFrom<Operation> for UndoOperation {
	type Error = EngineError;

	fn try_from(operation: Operation) -> Result<Self, EngineError> {
		Ok(match operation {
			Operation::Create { uuid } => UndoOperation::Create {
				uuid: uuid.to_string(),
			},
			Operation::Delete { uuid, old_task } => UndoOperation::Delete {
				uuid: uuid.to_string(),
				old_task,
			},
			Operation::UndoPoint => UndoOperation::UndoPoint,
			Operation::Update {
				uuid,
				property,
				old_value,
				value,
				timestamp,
			} => UndoOperation::Update {
				uuid: uuid.to_string(),
				property,
				old_value,
				value,
				timestamp_nanoseconds: timestamp
					.timestamp_nanos_opt()
					.ok_or_else(|| failed(format!("timestamp {timestamp} is out of range")))?,
			},
		})
	}
}

impl TryFrom<UndoOperation> for Operation {
	type Error = EngineError;

	fn try_from(operation: UndoOperation) -> Result<Self, EngineError> {
		Ok(match operation {
			UndoOperation::Create { uuid } => Operation::Create {
				uuid: parse_uuid(&uuid)?,
			},
			UndoOperation::Delete { uuid, old_task } => Operation::Delete {
				uuid: parse_uuid(&uuid)?,
				old_task,
			},
			UndoOperation::UndoPoint => Operation::UndoPoint,
			UndoOperation::Update {
				uuid,
				property,
				old_value,
				value,
				timestamp_nanoseconds,
			} => Operation::Update {
				uuid: parse_uuid(&uuid)?,
				property,
				old_value,
				value,
				timestamp: DateTime::from_timestamp_nanos(timestamp_nanoseconds),
			},
		})
	}
}

#[derive(uniffi::Enum)]
pub enum UndoOutcome {
	/// The reversal committed, so the snapshot needs refreshing. `error` is a failure that followed
	/// it, while TaskChampion rebuilt the working set.
	Applied { error: Option<String> },
	/// The operations were no longer TaskChampion's newest Undo point, so nothing changed.
	NotApplied,
}

/// `SqliteStorage` runs its own thread and runtime; this one only awaits its channels.
fn runtime() -> &'static Runtime {
	static RUNTIME: OnceLock<Runtime> = OnceLock::new();
	RUNTIME.get_or_init(|| {
		tokio::runtime::Builder::new_current_thread()
			.build()
			.expect("tokio runtime")
	})
}

fn parse_uuid(uuid: &str) -> Result<Uuid, EngineError> {
	Uuid::parse_str(uuid).map_err(|error| failed(format!("invalid UUID {uuid}: {error}")))
}

fn data_version(connection: &Connection) -> Result<i64, EngineError> {
	Ok(connection.query_row("PRAGMA data_version", [], |row| row.get(0))?)
}

fn schema_version(connection: &Connection) -> Result<(u32, u32), EngineError> {
	if !connection.table_exists(None, "version")? {
		return Ok(UNVERSIONED_SCHEMA);
	}
	let version = connection
		.query_row("SELECT major, minor FROM version", [], |row| {
			Ok((row.get(0)?, row.get(1)?))
		})
		.optional()?;
	Ok(version.unwrap_or(UNVERSIONED_SCHEMA))
}

/// A task's current data, read from the Replica once per `apply`.
async fn task_data<'a>(
	replica: &mut Replica<SqliteStorage>,
	tasks: &'a mut HashMap<Uuid, Option<TaskData>>,
	uuid: Uuid,
) -> Result<&'a mut Option<TaskData>, EngineError> {
	Ok(match tasks.entry(uuid) {
		Entry::Occupied(entry) => entry.into_mut(),
		Entry::Vacant(entry) => entry.insert(replica.get_task_data(uuid).await?),
	})
}

async fn update(
	replica: &mut Replica<SqliteStorage>,
	tasks: &mut HashMap<Uuid, Option<TaskData>>,
	uuid: &str,
	property: &str,
	value: Option<String>,
	operations: &mut Operations,
) -> Result<(), EngineError> {
	let uuid = parse_uuid(uuid)?;
	let Some(task) = task_data(replica, tasks, uuid).await? else {
		return Err(failed(format!("no task {uuid}")));
	};
	task.update(property, value, operations);
	Ok(())
}

/// One open Replica. Every call is a short, synchronous transaction: the CLI waits at most 5 s on a
/// held lock, so nothing here holds one open between calls.
#[derive(uniffi::Object)]
pub struct EngineHandle {
	replica: Mutex<Replica<SqliteStorage>>,
	/// Its own connection, because `PRAGMA data_version` moves only for other connections' commits.
	/// The replica's connection counts as another, so the app's own writes move it too.
	watcher: Mutex<Connection>,
}

#[uniffi::export]
impl EngineHandle {
	/// Opens the Replica in `directory`, refusing a folder without one rather than creating it, and
	/// a schema major version newer than this engine reads.
	#[uniffi::constructor]
	pub fn open(directory: String) -> Result<Self, EngineError> {
		let database = Path::new(&directory).join(DATABASE_FILE);
		if !database.is_file() {
			return Err(EngineError::NotAReplica);
		}
		// Read-write though it only reads: once the last connection closes, SQLite deletes the
		// `-wal` and `-shm` files, and a read-only connection can't recreate them. No
		// `SQLITE_OPEN_CREATE`, so a missing database still fails rather than appearing empty.
		let mut flags = OpenFlags::default();
		flags.remove(OpenFlags::SQLITE_OPEN_CREATE);
		let watcher = Connection::open_with_flags(&database, flags)?;
		let (major, minor) = schema_version(&watcher)?;
		if major > SUPPORTED_SCHEMA_MAJOR {
			return Err(EngineError::UnsupportedSchema { major, minor });
		}
		let storage =
			runtime().block_on(SqliteStorage::new(&directory, AccessMode::ReadWrite, false))?;
		Ok(Self {
			replica: Mutex::new(Replica::new(storage)),
			watcher: Mutex::new(watcher),
		})
	}

	/// Commits `operations` as one Undo point, but only if every expectation still holds just
	/// before the commit. TaskChampion's commit never checks an update's old value, so without this
	/// a plan made from a stale snapshot would overwrite whatever changed since. A write landing
	/// between the check and the commit still gets through, as it does for the CLI.
	pub fn apply(
		&self,
		operations: Vec<PlannedOperation>,
		expectations: Vec<Expectation>,
	) -> Result<ApplyOutcome, EngineError> {
		let mut replica = self.replica.lock().unwrap();
		let replica = &mut *replica;
		runtime().block_on(async {
			let mut tasks = HashMap::new();
			let mut conflicts: Vec<String> = Vec::new();
			for expectation in &expectations {
				if conflicts.contains(&expectation.uuid) {
					continue;
				}
				let uuid = parse_uuid(&expectation.uuid)?;
				let task = task_data(replica, &mut tasks, uuid).await?;
				let current = task.as_ref().and_then(|task| task.get(&expectation.property));
				if current == expectation.value.as_deref() {
					continue;
				}
				conflicts.push(expectation.uuid.clone());
			}
			if !conflicts.is_empty() {
				return Ok(ApplyOutcome::Conflict { uuids: conflicts });
			}
			// A lone Undo point would still land in the shared log, where `task undo` sees it.
			if operations.is_empty() {
				return Ok(ApplyOutcome::Committed);
			}

			let mut batch = vec![Operation::UndoPoint];
			for operation in operations {
				match operation {
					PlannedOperation::Create { uuid: text } => {
						// TaskChampion skips creating a task that exists but still logs the
						// create, and undoing it would delete that task.
						let uuid = parse_uuid(&text)?;
						let task = task_data(replica, &mut tasks, uuid).await?;
						if task.is_some() {
							return Ok(ApplyOutcome::Conflict { uuids: vec![text] });
						}
						*task = Some(TaskData::create(uuid, &mut batch));
					}
					PlannedOperation::SetStatus { uuid, status } => {
						let value = Some(status.stored_value().to_string());
						update(replica, &mut tasks, &uuid, "status", value, &mut batch).await?;
					}
					PlannedOperation::SetValue {
						uuid,
						property,
						value,
					} => {
						update(replica, &mut tasks, &uuid, &property, value, &mut batch).await?;
					}
				}
			}
			replica.commit_operations(batch).await?;
			Ok(ApplyOutcome::Committed)
		})
	}

	/// Reverts `operations` if they are still TaskChampion's newest undo operations.
	///
	/// After a failure, whether the reversal landed is judged by re-reading the log, which is only a
	/// best guess: a CLI write in between reads as applied, and a re-read that fails too (say, the
	/// CLI still holding the lock) is reported as the original error though the reversal may have
	/// committed. Refresh after any outcome but `NotApplied`.
	pub fn commit_reversed_operations(
		&self,
		operations: Vec<UndoOperation>,
	) -> Result<UndoOutcome, EngineError> {
		let operations = operations
			.into_iter()
			.map(Operation::try_from)
			.collect::<Result<Operations, _>>()?;
		let mut replica = self.replica.lock().unwrap();
		runtime().block_on(async {
			let error = match replica.commit_reversed_operations(operations.clone()).await {
				Ok(true) => return Ok(UndoOutcome::Applied { error: None }),
				Ok(false) => return Ok(UndoOutcome::NotApplied),
				Err(error) => error,
			};
			// TaskChampion rebuilds the working set after the reversal commits, so an error can
			// follow a reversal that already landed. It did if the operations are gone from the log.
			match replica.get_undo_operations().await {
				Ok(newest) if newest != operations => Ok(UndoOutcome::Applied {
					error: Some(error.to_string()),
				}),
				_ => Err(error.into()),
			}
		})
	}

	/// Changes whenever any connection, the app's own included, commits to the Replica.
	pub fn data_version(&self) -> Result<i64, EngineError> {
		data_version(&self.watcher.lock().unwrap())
	}

	/// The operations since the newest Undo point, which starts them.
	pub fn get_undo_operations(&self) -> Result<Vec<UndoOperation>, EngineError> {
		let mut replica = self.replica.lock().unwrap();
		let operations = runtime().block_on(replica.get_undo_operations())?;
		operations.into_iter().map(UndoOperation::try_from).collect()
	}

	/// Reads every task and the working set. They come from separate transactions, so the read is
	/// retried until `data_version` holds across it.
	pub fn snapshot(&self) -> Result<Snapshot, EngineError> {
		let mut replica = self.replica.lock().unwrap();
		let watcher = self.watcher.lock().unwrap();
		for _ in 0..SNAPSHOT_ATTEMPTS {
			let before = data_version(&watcher)?;
			let (tasks, working_set) = runtime().block_on(async {
				let tasks = replica.all_task_data().await?;
				let working_set = replica.working_set().await?;
				Ok::<_, taskchampion::Error>((tasks, working_set))
			})?;
			if data_version(&watcher)? != before {
				continue;
			}
			return Ok(Snapshot {
				data_version: before,
				tasks: tasks
					.into_iter()
					.map(|(uuid, task)| TaskProperties {
						uuid: uuid.to_string(),
						properties: task
							.iter()
							.map(|(key, value)| (key.clone(), value.clone()))
							.collect(),
					})
					.collect(),
				working_set: working_set
					.iter()
					.map(|(id, uuid)| WorkingSetEntry {
						id: id as u64,
						uuid: uuid.to_string(),
					})
					.collect(),
			});
		}
		Err(failed("the Replica kept changing while it was read"))
	}
}
