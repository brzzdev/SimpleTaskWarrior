// The only importer of the engine: one actor per open Replica.
public import ComposableArchitecture
import Dispatch
import Engine
public import Foundation
public import Models
import Synchronization

@DependencyClient
public struct ReplicaClient: Sendable {
	/// Commits `plan` as one Undo point to the Replica a `tasks` stream has open in `directory`,
	/// unless a value it read has changed since, then reads every task again. That read doesn't
	/// reach the stream, which yields only what changes after it.
	public var apply: @Sendable (_ plan: WritePlan, _ directory: URL) async throws -> ApplyOutcome

	/// Opens the Replica in `directory` for one window, yielding its tasks at once and again
	/// whenever anything, the CLI included, commits to it. Holds the directory's security scope
	/// while it reads. Ending iteration closes the Replica once any open or read in flight returns.
	public var tasks: @Sendable (_ directory: URL)
		-> AsyncThrowingStream<TaskSnapshot, any Error> = { _ in .finished() }

	/// Opens the Replica in `directory` and closes it again, so Open Replica… can refuse a folder
	/// before a window exists.
	public var validate: @Sendable (_ directory: URL) async throws -> Void
}

public struct ApplyOutcome: Equatable, Sendable {
	/// False where nothing was committed, because a value the plan read had changed.
	public var isCommitted: Bool
	/// Every task, read after the commit, or in place of it.
	public var snapshot: TaskSnapshot

	public init(isCommitted: Bool, snapshot: TaskSnapshot) {
		self.isCommitted = isCommitted
		self.snapshot = snapshot
	}
}

/// Every task in a Replica, as one read found them.
public struct TaskSnapshot: Equatable, Sendable {
	/// Counts the Replica's reads from 0. `apply` and the `tasks` stream each read, and deliver
	/// separately, so a read can arrive after a later one.
	public var readIndex: Int
	public var tasks: [StoredTask]

	public init(readIndex: Int, tasks: [StoredTask]) {
		self.readIndex = readIndex
		self.tasks = tasks
	}
}

public enum ReplicaError: Equatable, LocalizedError {
	case failed(String)
	case notAReplica
	/// No window has the Replica open.
	case notOpen
	case unsupportedSchema

	public var errorDescription: String? {
		switch self {
		case let .failed(message):
			message

		case .notAReplica:
			"This folder isn't a Taskwarrior 3 Replica"

		case .notOpen:
			"The Replica isn't open"

		case .unsupportedSchema:
			"This Replica needs a newer version of SimpleTaskWarrior"
		}
	}
}

/// Each window's Replica, by the folder its `tasks` stream opened, which `apply` writes through.
private let openReplicas = Mutex<[URL: Replica]>([:])

/// How often a window checks whether anything has committed to its Replica.
private let pollInterval = Duration.milliseconds(500)

extension ReplicaClient: DependencyKey {
	public static let liveValue = Self(
		apply: { plan, directory in
			guard let replica = openReplicas.withLock({ $0[directory] }) else {
				throw ReplicaError.notOpen
			}
			return try await replica.apply(plan)
		},
		tasks: { directory in
			AsyncThrowingStream { continuation in
				let polling = _Concurrency.Task {
					// Held here rather than by the caller, because cancelling doesn't interrupt an
					// engine call blocked on the lock, and the scope must outlast it.
					let isAccessing = directory.startAccessingSecurityScopedResource()
					defer {
						if isAccessing {
							directory.stopAccessingSecurityScopedResource()
						}
					}
					do {
						let replica = try await Replica.open(directory: directory)
						// Cancelled while `open` waited, the window has closed, and one reopened on the
						// folder may have registered its own already. Checked under the lock, since a
						// window can only reopen once this one is cancelled.
						let isRegistered = openReplicas.withLock { replicas in
							guard !_Concurrency.Task.isCancelled else {
								return false
							}
							replicas[directory] = replica
							return true
						}
						guard isRegistered else {
							throw CancellationError()
						}
						defer {
							// A window reopened on the folder may have registered its own by now.
							openReplicas.withLock { replicas in
								if replicas[directory] === replica {
									replicas[directory] = nil
								}
							}
						}
						while true {
							// Before every read too: cancelling doesn't interrupt a blocked `open`, and
							// once it returns, a read would start a fresh wait on the lock.
							try _Concurrency.Task.checkCancellation()
							// A failed read keeps the last tasks on screen and retries next tick.
							try? await replica.publishTasksIfChanged(to: continuation)
							try await _Concurrency.Task.sleep(for: pollInterval)
						}
					} catch is CancellationError {
						continuation.finish()
					} catch {
						continuation.finish(throwing: error)
					}
				}
				continuation.onTermination = { _ in polling.cancel() }
			}
		},
		validate: { directory in
			_ = try await Replica.open(directory: directory)
		},
	)

	public static let testValue = Self()
}

extension DependencyValues {
	public var replicaClient: ReplicaClient {
		get { self[ReplicaClient.self] }
		set { self[ReplicaClient.self] = newValue }
	}
}

/// One open Replica. Engine calls block for up to TaskChampion's 5 s lock timeout, so the
/// actor runs on its own serial queue rather than the cooperative pool, and its methods are
/// synchronous, so none of them interleave. The engine handle never leaves it.
actor Replica {
	private let engine: EngineHandle
	private let queue: DispatchSerialQueue
	private var readCount = 0
	/// The `data_version` the last tasks were read at, nil before the first read.
	private var readVersion: Int64?

	nonisolated var unownedExecutor: UnownedSerialExecutor {
		queue.asUnownedSerialExecutor()
	}

	/// Releasing the engine blocks too, while TaskChampion joins its storage thread, so the
	/// last reference is dropped on the actor's queue rather than wherever it happens to go.
	isolated deinit {}

	private init(directory: URL, queue: DispatchSerialQueue) throws(ReplicaError) {
		self.queue = queue
		do {
			engine = try EngineHandle.open(directory: directory.path(percentEncoded: false))
		} catch EngineError.NotAReplica {
			throw .notAReplica
		} catch EngineError.UnsupportedSchema {
			throw .unsupportedSchema
		} catch let EngineError.Failed(message) {
			throw .failed(message)
		} catch {
			throw .failed(error.localizedDescription)
		}
	}

	/// Opens on the actor's queue, since opening waits on a held lock like any other call. The
	/// whole actor is built there, so only it crosses back to the caller, never the engine handle.
	static func open(directory: URL) async throws(ReplicaError) -> Replica {
		let queue = DispatchSerialQueue(label: "dev.brzz.SimpleTaskWarrior.Replica")
		let replica = await withCheckedContinuation { continuation in
			queue.async {
				continuation.resume(returning: Result { () throws(ReplicaError) in
					try Replica(directory: directory, queue: queue)
				})
			}
		}
		return try replica.get()
	}

	/// Commits `plan` unless the engine refuses it as stale, then reads every task again.
	func apply(_ plan: WritePlan) throws -> ApplyOutcome {
		let outcome = try engine.apply(
			operations: plan.operations.map(PlannedOperation.init),
			expectations: plan.expectations.map(Expectation.init),
		)
		return try ApplyOutcome(isCommitted: outcome == .committed, snapshot: readTasks())
	}

	/// Yields every task when anything has committed since the last read.
	func publishTasksIfChanged(
		to continuation: AsyncThrowingStream<TaskSnapshot, any Error>.Continuation,
	) throws {
		guard try engine.dataVersion() != readVersion else { return }
		// Decoded by the window, with its Taskrc's UDAs.
		try continuation.yield(readTasks())
	}

	/// Every task, recording the `data_version` they were read at.
	private func readTasks() throws -> TaskSnapshot {
		let snapshot = try engine.snapshot()
		readVersion = snapshot.dataVersion
		let workingSetIDs = Dictionary(
			snapshot.workingSet.map { ($0.uuid, Int($0.id)) },
			uniquingKeysWith: { first, _ in first },
		)
		let tasks = snapshot.tasks.map { task in
			StoredTask(
				properties: task.properties,
				uuid: task.uuid,
				workingSetID: workingSetIDs[task.uuid],
			)
		}
		defer {
			readCount += 1
		}
		return TaskSnapshot(readIndex: readCount, tasks: tasks)
	}
}

extension Engine.Status {
	fileprivate init(_ status: Models.Status) {
		switch status {
		case .completed: self = .completed
		case .deleted: self = .deleted
		case .pending: self = .pending
		case .recurring: self = .recurring
		}
	}
}

extension Expectation {
	fileprivate init(_ expectation: WritePlan.Expectation) {
		self.init(
			uuid: expectation.uuid.uuidString.lowercased(),
			property: expectation.property,
			value: expectation.value,
		)
	}
}

extension PlannedOperation {
	fileprivate init(_ operation: WritePlan.Operation) {
		switch operation {
		case let .create(uuid):
			self = .create(uuid: uuid.uuidString.lowercased())

		case let .setStatus(uuid, status):
			self = .setStatus(uuid: uuid.uuidString.lowercased(), status: Engine.Status(status))

		case let .setValue(uuid, property, value):
			self = .setValue(uuid: uuid.uuidString.lowercased(), property: property, value: value)
		}
	}
}
