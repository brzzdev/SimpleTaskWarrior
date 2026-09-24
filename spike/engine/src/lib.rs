use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use rusqlite::{Connection, OpenFlags};
use taskchampion::storage::AccessMode;
use taskchampion::{Operation, Operations, Replica, SqliteStorage, Status, Uuid};
use tokio::runtime::Runtime;

uniffi::setup_scaffolding!();

const DATABASE_FILE: &str = "taskchampion.sqlite3";

#[derive(Debug, uniffi::Error)]
#[uniffi(flat_error)]
pub enum EngineError {
	Failed(String),
}

impl std::fmt::Display for EngineError {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		let EngineError::Failed(message) = self;
		f.write_str(message)
	}
}

impl<E: std::error::Error> From<E> for EngineError {
	fn from(error: E) -> Self {
		EngineError::Failed(error.to_string())
	}
}

// SqliteStorage runs its own thread and runtime; this one only awaits its channels.
fn runtime() -> &'static Runtime {
	static RUNTIME: OnceLock<Runtime> = OnceLock::new();
	RUNTIME.get_or_init(|| {
		tokio::runtime::Builder::new_current_thread().build().expect("tokio runtime")
	})
}

#[derive(uniffi::Object)]
pub struct Engine {
	database: PathBuf,
	replica: Mutex<Replica<SqliteStorage>>,
	// `PRAGMA data_version` only moves for other connections' commits, so it gets its own.
	watcher: Mutex<Connection>,
}

#[uniffi::export]
impl Engine {
	#[uniffi::constructor]
	pub fn open(directory: String) -> Result<Self, EngineError> {
		let storage = runtime().block_on(SqliteStorage::new(
			&directory,
			AccessMode::ReadWrite,
			false,
		))?;
		let database = PathBuf::from(&directory).join(DATABASE_FILE);
		let watcher = Connection::open_with_flags(&database, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
		Ok(Self {
			database,
			replica: Mutex::new(Replica::new(storage)),
			watcher: Mutex::new(watcher),
		})
	}

	pub fn add_task(&self, description: String) -> Result<String, EngineError> {
		let mut replica = self.replica.lock().unwrap();
		runtime().block_on(async {
			let mut ops = Operations::new();
			ops.push(Operation::UndoPoint);
			let now = taskchampion::chrono::Utc::now();
			let mut task = replica.create_task(Uuid::new_v4(), &mut ops).await?;
			task.set_description(description, &mut ops)?;
			task.set_entry(Some(now), &mut ops)?;
			task.set_modified(now, &mut ops)?;
			task.set_status(Status::Pending, &mut ops)?;
			replica.commit_operations(ops).await?;
			Ok(task.get_uuid().to_string())
		})
	}

	pub fn data_version(&self) -> Result<i64, EngineError> {
		let watcher = self.watcher.lock().unwrap();
		Ok(watcher.query_row("PRAGMA data_version", [], |row| row.get(0))?)
	}

	/// Spike only: hold a write lock the way another writer would, to make the CLI wait on us.
	pub fn hold_write_lock(&self, seconds: f64) -> Result<(), EngineError> {
		let connection = Connection::open(&self.database)?;
		connection.execute_batch("BEGIN IMMEDIATE")?;
		std::thread::sleep(Duration::from_secs_f64(seconds));
		connection.execute_batch("COMMIT")?;
		Ok(())
	}

	pub fn pending_descriptions(&self) -> Result<Vec<String>, EngineError> {
		let mut replica = self.replica.lock().unwrap();
		runtime().block_on(async {
			let tasks = replica.pending_tasks().await?;
			Ok(tasks.iter().map(|task| task.get_description().to_string()).collect())
		})
	}

	pub fn sqlite_version(&self) -> Result<String, EngineError> {
		let watcher = self.watcher.lock().unwrap();
		Ok(watcher.query_row("SELECT sqlite_version()", [], |row| row.get(0))?)
	}
}
