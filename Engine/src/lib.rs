//! A thin facade over TaskChampion for the Swift app. It wraps TaskChampion's primitives and holds
//! no Taskwarrior rules: no `modified` or `end` stamping, no tag or dependency mirrors. Those live in
//! Swift (docs/adr/0001-taskwarrior-rules-live-in-swift.md).

use std::collections::HashMap;
use std::collections::hash_map::Entry;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};

use async_trait::async_trait;
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use taskchampion::chrono::DateTime;
use taskchampion::storage::{AccessMode, Storage, StorageTxn, TaskMap};
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
	/// Another connection, such as the CLI's, held the Replica's lock past SQLite's 5 s busy
	/// timeout. Nothing was committed, so the call can be made again.
	Busy,
	Failed { message: String },
	/// The folder has no TaskChampion database, or what's in its place isn't one.
	NotAReplica,
	/// An undo failed, and so did the log read that would tell whether its reversal landed first, so
	/// it may have.
	UndoUnconfirmed { message: String },
	/// The database's schema major version is newer than this engine reads.
	UnsupportedSchema { major: u32, minor: u32 },
}

impl std::fmt::Display for EngineError {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self {
			EngineError::Busy => f.write_str("the Replica is locked by another connection"),
			EngineError::Failed { message } | EngineError::UndoUnconfirmed { message } => {
				f.write_str(message)
			}
			EngineError::NotAReplica => f.write_str("the folder has no TaskChampion database"),
			EngineError::UnsupportedSchema { major, minor } => {
				write!(f, "schema version {major}.{minor} is newer than this engine reads")
			}
		}
	}
}

impl<E: std::error::Error + 'static> From<E> for EngineError {
	fn from(error: E) -> Self {
		if is_busy(&error) {
			return EngineError::Busy;
		}
		failed(error)
	}
}

/// Whether `error` is SQLite giving up on a held lock. TaskChampion wraps SQLite's errors in an
/// `anyhow::Error`, which `source` skips past, so it's unwrapped by hand.
fn is_busy(error: &(dyn std::error::Error + 'static)) -> bool {
	let sqlite = match error.downcast_ref::<taskchampion::Error>() {
		Some(taskchampion::Error::Other(error)) => error.downcast_ref::<rusqlite::Error>(),
		Some(_) => None,
		None => error.downcast_ref::<rusqlite::Error>(),
	};
	sqlite.and_then(rusqlite::Error::sqlite_error_code) == Some(rusqlite::ErrorCode::DatabaseBusy)
}

fn failed(message: impl ToString) -> EngineError {
	EngineError::Failed {
		message: message.to_string(),
	}
}

/// Which file a Replica's database is: its device and inode, which a move keeps and a replacement,
/// such as a recreation or a restore from backup, doesn't.
#[derive(uniffi::Record)]
pub struct DatabaseIdentity {
	pub device: u64,
	pub inode: u64,
}

/// The database in `directory`, None where there's none. Found by `stat`, never by opening it:
/// closing any descriptor on the file drops every SQLite POSIX lock the process holds on it.
#[uniffi::export]
pub fn database_identity(directory: String) -> Option<DatabaseIdentity> {
	let metadata = std::fs::metadata(Path::new(&directory).join(DATABASE_FILE)).ok()?;
	Some(DatabaseIdentity {
		device: metadata.dev(),
		inode: metadata.ino(),
	})
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
	/// `operations` are exactly what was committed, its leading Undo point included, for
	/// `commit_reversed_operations` to undo. They're empty where the batch changed nothing.
	Committed { operations: Vec<UndoOperation> },
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

fn schema_version(connection: &Connection) -> rusqlite::Result<(u32, u32)> {
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
	replica: &mut Replica<CheckedStorage>,
	tasks: &'a mut HashMap<Uuid, Option<TaskData>>,
	uuid: Uuid,
) -> Result<&'a mut Option<TaskData>, EngineError> {
	Ok(match tasks.entry(uuid) {
		Entry::Occupied(entry) => entry.into_mut(),
		Entry::Vacant(entry) => entry.insert(replica.get_task_data(uuid).await?),
	})
}

async fn update(
	replica: &mut Replica<CheckedStorage>,
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

/// A value one task's property must still hold for a commit to go through.
struct ExpectedValue {
	property: String,
	uuid: Uuid,
	value: Option<String>,
}

/// What one commit must find in the Replica for it to go through.
#[derive(Default)]
struct Checks {
	/// Tasks the batch creates, which must not exist yet.
	creates: Vec<Uuid>,
	expectations: Vec<ExpectedValue>,
	/// Tasks the batch updates without creating, which must still exist. TaskChampion skips an
	/// update to a missing task but still logs it, so a purge would otherwise commit.
	updates: Vec<Uuid>,
}

impl Checks {
	/// The tasks that fail a check, each once. Each task is read once, since this runs under the
	/// write lock the CLI waits on.
	async fn conflicts(
		&self,
		txn: &mut (dyn StorageTxn + Send),
	) -> Result<Vec<Uuid>, taskchampion::Error> {
		let mut tasks: HashMap<Uuid, Option<TaskMap>> = HashMap::new();
		let expected_uuids = self.expectations.iter().map(|expected| &expected.uuid);
		for &uuid in expected_uuids.chain(&self.creates).chain(&self.updates) {
			if let Entry::Vacant(entry) = tasks.entry(uuid) {
				entry.insert(txn.get_task(uuid).await?);
			}
		}
		let changed = self.expectations.iter().filter(|expected| {
			let task = tasks[&expected.uuid].as_ref();
			task.and_then(|task| task.get(&expected.property)) != expected.value.as_ref()
		});
		let existing = self.creates.iter().filter(|uuid| tasks[*uuid].is_some());
		let missing = self.updates.iter().filter(|uuid| tasks[*uuid].is_none());
		let mut conflicts = Vec::new();
		for &uuid in changed.map(|expected| &expected.uuid).chain(existing).chain(missing) {
			if !conflicts.contains(&uuid) {
				conflicts.push(uuid);
			}
		}
		Ok(conflicts)
	}
}

/// Passes `apply`'s checks to the storage that runs them, and their conflicts back.
#[derive(Default)]
struct CheckChannel {
	/// The tasks the last checked transaction refused on.
	conflicts: Vec<Uuid>,
	/// Checks for the next transaction, which takes them so they run once.
	pending: Option<Checks>,
	/// Runs just before the next checked transaction opens, so a test can write in that window.
	#[cfg(test)]
	before_transaction: Option<Box<dyn FnOnce() + Send>>,
}

/// `SqliteStorage` that runs `apply`'s checks inside the commit's own transaction. TaskChampion's
/// commit opens exactly one transaction before it reads or writes anything, and `SqliteStorage`
/// opens it `Immediate`, so the checks and the write happen under one SQLite write lock.
struct CheckedStorage {
	checks: Arc<Mutex<CheckChannel>>,
	inner: SqliteStorage,
}

#[async_trait]
impl Storage for CheckedStorage {
	async fn txn<'a>(&'a mut self) -> Result<Box<dyn StorageTxn + Send + 'a>, taskchampion::Error> {
		let checks = {
			let mut commit_checks = self.checks.lock().unwrap();
			#[cfg(test)]
			if commit_checks.pending.is_some()
				&& let Some(hook) = commit_checks.before_transaction.take()
			{
				hook();
			}
			commit_checks.pending.take()
		};
		let Some(checks) = checks else {
			return self.inner.txn().await;
		};
		let mut txn = self.inner.txn().await?;
		let conflicts = checks.conflicts(txn.as_mut()).await?;
		if conflicts.is_empty() {
			return Ok(txn);
		}
		// Dropping the transaction rolls it back. `apply` reads the conflicts, not this error.
		self.checks.lock().unwrap().conflicts = conflicts;
		Err(taskchampion::Error::Database("expectations no longer hold".into()))
	}
}

/// One open Replica. Every call is a short, synchronous transaction: the CLI waits at most 5 s on a
/// held lock, so nothing here holds one open between calls.
#[derive(uniffi::Object)]
pub struct EngineHandle {
	/// Shared with the Replica's storage, which runs `apply`'s checks.
	checks: Arc<Mutex<CheckChannel>>,
	replica: Mutex<Replica<CheckedStorage>>,
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
		// The first read, so where a file that isn't a database, such as one overwritten, is found.
		let (major, minor) = schema_version(&watcher).map_err(|error| {
			if error.sqlite_error_code() == Some(rusqlite::ErrorCode::NotADatabase) {
				return EngineError::NotAReplica;
			}
			error.into()
		})?;
		if major > SUPPORTED_SCHEMA_MAJOR {
			return Err(EngineError::UnsupportedSchema { major, minor });
		}
		let inner =
			runtime().block_on(SqliteStorage::new(&directory, AccessMode::ReadWrite, false))?;
		let checks = Arc::new(Mutex::new(CheckChannel::default()));
		let storage = CheckedStorage {
			checks: Arc::clone(&checks),
			inner,
		};
		Ok(Self {
			checks,
			replica: Mutex::new(Replica::new(storage)),
			watcher: Mutex::new(watcher),
		})
	}

	/// Commits `operations` as one Undo point, but only if every expectation still holds, no
	/// created task exists yet, and every updated task still does. TaskChampion's commit never
	/// checks an update's old value, so without this a plan made from a stale snapshot would
	/// overwrite whatever changed since. The checks run first as a fast path, then again inside the
	/// commit's transaction, so no write lands between them and the commit.
	pub fn apply(
		&self,
		operations: Vec<PlannedOperation>,
		expectations: Vec<Expectation>,
	) -> Result<ApplyOutcome, EngineError> {
		let mut replica = self.replica.lock().unwrap();
		let replica = &mut *replica;
		runtime().block_on(async {
			let mut tasks = HashMap::new();
			let mut checks = Checks::default();
			let mut conflicts: Vec<String> = Vec::new();
			for Expectation {
				uuid: raw_uuid,
				property,
				value,
			} in expectations
			{
				let uuid = parse_uuid(&raw_uuid)?;
				let task = task_data(replica, &mut tasks, uuid).await?;
				let current = task.as_ref().and_then(|task| task.get(&property));
				if current != value.as_deref() && !conflicts.contains(&raw_uuid) {
					conflicts.push(raw_uuid);
				}
				checks.expectations.push(ExpectedValue {
					property,
					uuid,
					value,
				});
			}
			if !conflicts.is_empty() {
				return Ok(ApplyOutcome::Conflict { uuids: conflicts });
			}
			// A lone Undo point would still land in the shared log, where `task undo` sees it.
			if operations.is_empty() {
				return Ok(ApplyOutcome::Committed { operations: Vec::new() });
			}

			let mut batch = vec![Operation::UndoPoint];
			for operation in operations {
				match operation {
					PlannedOperation::Create { uuid: raw_uuid } => {
						// TaskChampion skips creating a task that exists but still logs the
						// create, and undoing it would delete that task.
						let uuid = parse_uuid(&raw_uuid)?;
						let task = task_data(replica, &mut tasks, uuid).await?;
						if task.is_some() {
							return Ok(ApplyOutcome::Conflict { uuids: vec![raw_uuid] });
						}
						*task = Some(TaskData::create(uuid, &mut batch));
						checks.creates.push(uuid);
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
			for operation in &batch {
				let Operation::Update { uuid, .. } = operation else {
					continue;
				};
				if checks.creates.contains(uuid) {
					continue;
				}
				checks.updates.push(*uuid);
			}
			self.checks.lock().unwrap().pending = Some(checks);
			let committed = replica.commit_operations(batch.clone()).await;
			// Cleared whether or not the commit reached its transaction, so no later call runs them.
			let conflicts = {
				let mut commit_checks = self.checks.lock().unwrap();
				commit_checks.pending = None;
				std::mem::take(&mut commit_checks.conflicts)
			};
			if !conflicts.is_empty() {
				let uuids = conflicts.iter().map(Uuid::to_string).collect();
				return Ok(ApplyOutcome::Conflict { uuids });
			}
			committed?;
			Ok(ApplyOutcome::Committed {
				operations: batch
					.into_iter()
					.map(UndoOperation::try_from)
					.collect::<Result<_, _>>()?,
			})
		})
	}

	/// Reverts `operations` if they are still TaskChampion's newest undo operations.
	///
	/// After a failure, whether the reversal landed is judged by re-reading the log, which is only a
	/// best guess: a CLI write in between reads as applied. A re-read that fails too (say, the CLI
	/// still holding the lock) is `UndoUnconfirmed`, since the reversal may have committed. Refresh
	/// after any outcome but `NotApplied`.
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
				Ok(_) => Err(error.into()),
				Err(read_error) => Err(EngineError::UndoUnconfirmed {
					message: format!("{error}; reading the log to confirm it failed too: {read_error}"),
				}),
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

#[cfg(test)]
mod tests {
	use std::time::{Duration, Instant};

	use super::*;

	fn assert_conflict(outcome: ApplyOutcome, uuid: Uuid) {
		let ApplyOutcome::Conflict { uuids } = outcome else {
			panic!("expected a conflict");
		};
		assert_eq!(uuids, vec![uuid.to_string()]);
	}

	fn create_task(handle: &EngineHandle, uuid: Uuid) {
		let create = PlannedOperation::Create {
			uuid: uuid.to_string(),
		};
		handle.apply(vec![create, set_description(uuid, "app")], Vec::new()).unwrap();
	}

	fn description(handle: &EngineHandle, uuid: Uuid) -> Option<String> {
		handle
			.snapshot()
			.unwrap()
			.tasks
			.into_iter()
			.find(|task| task.uuid == uuid.to_string())
			.and_then(|task| task.properties.get("description").cloned())
	}

	fn description_is(uuid: Uuid, value: &str) -> Expectation {
		Expectation {
			uuid: uuid.to_string(),
			property: "description".into(),
			value: Some(value.into()),
		}
	}

	/// An empty Replica in a temporary directory, open in a handle.
	fn open_replica() -> (tempfile::TempDir, EngineHandle) {
		let directory = tempfile::tempdir().unwrap();
		runtime()
			.block_on(SqliteStorage::new(directory.path(), AccessMode::ReadWrite, true))
			.unwrap();
		let handle = EngineHandle::open(directory.path().to_string_lossy().into_owned()).unwrap();
		(directory, handle)
	}

	fn set_description(uuid: Uuid, value: &str) -> PlannedOperation {
		PlannedOperation::SetValue {
			uuid: uuid.to_string(),
			property: "description".into(),
			value: Some(value.into()),
		}
	}

	/// Runs `sql` from its own connection, as the CLI would, after `apply`'s fast path passes but
	/// before the commit's transaction opens.
	fn write_before_transaction(
		handle: &EngineHandle,
		directory: &tempfile::TempDir,
		sql: &'static str,
		uuid: Uuid,
	) {
		let database = directory.path().join(DATABASE_FILE);
		handle.checks.lock().unwrap().before_transaction = Some(Box::new(move || {
			let connection = Connection::open(database).unwrap();
			connection.execute(sql, [uuid.to_string()]).unwrap();
		}));
	}

	#[test]
	fn refuses_a_create_whose_task_appears_before_the_commit_transaction() {
		let (directory, handle) = open_replica();
		let uuid = Uuid::new_v4();
		write_before_transaction(
			&handle,
			&directory,
			"INSERT INTO tasks (uuid, data) VALUES (?1, '{\"description\":\"cli\"}')",
			uuid,
		);
		let create = PlannedOperation::Create {
			uuid: uuid.to_string(),
		};

		let outcome = handle.apply(vec![create, set_description(uuid, "app")], Vec::new()).unwrap();

		assert_conflict(outcome, uuid);
		assert_eq!(description(&handle, uuid).as_deref(), Some("cli"));
		assert!(handle.get_undo_operations().unwrap().is_empty());
	}

	#[test]
	fn refuses_an_update_to_a_task_purged_before_the_commit_transaction() {
		let (directory, handle) = open_replica();
		let uuid = Uuid::new_v4();
		create_task(&handle, uuid);
		write_before_transaction(&handle, &directory, "DELETE FROM tasks WHERE uuid = ?1", uuid);
		let set_priority = PlannedOperation::SetValue {
			uuid: uuid.to_string(),
			property: "priority".into(),
			value: Some("H".into()),
		};
		// An edit setting an absent property expects only its absence, which a purged task matches.
		let priority_is_absent = Expectation {
			uuid: uuid.to_string(),
			property: "priority".into(),
			value: None,
		};

		let outcome = handle.apply(vec![set_priority], vec![priority_is_absent]).unwrap();

		assert_conflict(outcome, uuid);
		let logged_priority = handle.get_undo_operations().unwrap().into_iter().any(|operation| {
			matches!(operation, UndoOperation::Update { property, .. } if property == "priority")
		});
		assert!(!logged_priority);
	}

	#[test]
	fn refuses_an_update_changed_before_the_commit_transaction_and_leaves_no_checks_behind() {
		let (directory, handle) = open_replica();
		let uuid = Uuid::new_v4();
		create_task(&handle, uuid);
		write_before_transaction(
			&handle,
			&directory,
			"UPDATE tasks SET data = json_set(data, '$.description', 'cli') WHERE uuid = ?1",
			uuid,
		);

		let outcome = handle
			.apply(vec![set_description(uuid, "stale")], vec![description_is(uuid, "app")])
			.unwrap();
		assert_conflict(outcome, uuid);
		assert_eq!(description(&handle, uuid).as_deref(), Some("cli"));

		let outcome = handle
			.apply(vec![set_description(uuid, "fresh")], vec![description_is(uuid, "cli")])
			.unwrap();
		let ApplyOutcome::Committed { operations } = outcome else {
			panic!("expected a commit");
		};
		assert_eq!(description(&handle, uuid).as_deref(), Some("fresh"));

		let undone = handle.commit_reversed_operations(operations).unwrap();
		assert!(matches!(undone, UndoOutcome::Applied { error: None }));
		assert_eq!(description(&handle, uuid).as_deref(), Some("cli"));
	}

	#[test]
	fn commits_once_another_connection_releases_the_lock() {
		let (directory, handle) = open_replica();
		let uuid = Uuid::new_v4();
		// The wait is rusqlite's default 5 s busy timeout, which TaskChampion's connection inherits
		// rather than sets. The hold is well under it, so only an engine that stops waiting fails.
		let hold = Duration::from_millis(250);
		let cli = Connection::open(directory.path().join(DATABASE_FILE)).unwrap();
		cli.execute_batch("BEGIN IMMEDIATE").unwrap();
		let held = Instant::now();
		let release = std::thread::spawn(move || {
			std::thread::sleep(hold);
			cli.execute_batch("COMMIT").unwrap();
		});

		create_task(&handle, uuid);
		let waited = held.elapsed();

		release.join().unwrap();
		assert!(waited >= hold, "committed after {waited:?}, before the lock was released");
		assert_eq!(description(&handle, uuid).as_deref(), Some("app"));
	}

	#[test]
	fn reports_an_undo_whose_confirming_read_fails_too_as_unconfirmed() {
		let (directory, handle) = open_replica();
		create_task(&handle, Uuid::new_v4());
		let operations = handle.get_undo_operations().unwrap();
		// TaskChampion reads under `BEGIN IMMEDIATE` too, so the lock fails both the reversal and the
		// read that would confirm it. The timeout covers the Replica's last read still rolling back.
		let cli = Connection::open(directory.path().join(DATABASE_FILE)).unwrap();
		cli.busy_timeout(Duration::from_secs(1)).unwrap();
		cli.execute_batch("BEGIN IMMEDIATE").unwrap();

		let undone = handle.commit_reversed_operations(operations);

		assert!(matches!(undone, Err(EngineError::UndoUnconfirmed { .. })));
	}
}
