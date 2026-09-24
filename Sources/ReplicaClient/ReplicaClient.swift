// The only importer of the engine: one actor per open Replica.
public import ComposableArchitecture
import Dispatch
import Engine
public import Foundation
public import Models

@DependencyClient
public struct ReplicaClient: Sendable {
	/// Opens the Replica in `directory` for one window, yielding its tasks at once and again
	/// whenever anything, the CLI included, commits to it. The Replica closes when iteration ends.
	public var tasks: @Sendable (_ directory: URL)
		-> AsyncThrowingStream<[Models.Task], any Error> = { _ in .finished() }

	/// Opens the Replica in `directory` and closes it again, so Open Replica… can refuse a folder
	/// before a window exists.
	public var validate: @Sendable (_ directory: URL) async throws -> Void
}

public enum ReplicaError: Equatable, LocalizedError {
	case failed(String)
	case notAReplica
	case unsupportedSchema

	public var errorDescription: String? {
		switch self {
		case let .failed(message):
			message

		case .notAReplica:
			"This folder isn't a Taskwarrior 3 Replica"

		case .unsupportedSchema:
			"This Replica needs a newer version of SimpleTaskWarrior"
		}
	}
}

/// How often a window checks whether anything has committed to its Replica.
private let pollInterval = Duration.milliseconds(500)

extension ReplicaClient: DependencyKey {
	public static let liveValue = Self(
		tasks: { directory in
			AsyncThrowingStream { continuation in
				let polling = _Concurrency.Task {
					do {
						let replica = try await Replica.open(directory: directory)
						while true {
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
	/// The `data_version` the last tasks were read at, nil before the first read.
	private var readVersion: Int64?

	nonisolated var unownedExecutor: UnownedSerialExecutor {
		queue.asUnownedSerialExecutor()
	}

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

	/// Yields every task when anything has committed since the last read.
	func publishTasksIfChanged(
		to continuation: AsyncThrowingStream<[Models.Task], any Error>.Continuation,
	) throws {
		guard try engine.dataVersion() != readVersion else { return }
		let snapshot = try engine.snapshot()
		readVersion = snapshot.dataVersion
		let workingSetIDs = Dictionary(
			snapshot.workingSet.map { ($0.uuid, Int($0.id)) },
			uniquingKeysWith: { first, _ in first },
		)
		let tasks = snapshot.tasks.compactMap { task in
			Models.Task(
				properties: task.properties,
				uuid: task.uuid,
				workingSetID: workingSetIDs[task.uuid],
			)
		}
		continuation.yield(tasks)
	}
}
