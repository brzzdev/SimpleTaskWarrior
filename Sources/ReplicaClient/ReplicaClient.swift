// The only importer of the engine: one actor per open Replica.
import Dispatch
import Engine

/// One open Replica. Engine calls block for up to TaskChampion's 5 s lock timeout, so the
/// actor runs on its own serial queue rather than the cooperative pool, and its methods are
/// synchronous, so none of them interleave. The engine handle never leaves it.
actor Replica {
	private let engine: EngineHandle
	private let queue = DispatchSerialQueue(label: "dev.brzz.SimpleTaskWarrior.Replica")

	nonisolated var unownedExecutor: UnownedSerialExecutor {
		queue.asUnownedSerialExecutor()
	}

	init(directory: String) throws {
		engine = try EngineHandle.open(directory: directory)
	}

	func dataVersion() throws -> Int64 {
		try engine.dataVersion()
	}

	func snapshot() throws -> Snapshot {
		try engine.snapshot()
	}
}
