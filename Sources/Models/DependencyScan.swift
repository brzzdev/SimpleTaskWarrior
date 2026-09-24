public import Foundation

/// TW's blocked rule over one Replica's tasks: a task is blocked while it depends on another and
/// neither is completed or deleted. TaskChampion's own rule counts only a pending dependency, so
/// there a Recurrence template never blocks.
public struct DependencyScan: Equatable, Sendable {
	public var blocked: Set<Task.ID> = []
	public var blocking: Set<Task.ID> = []

	/// The open tasks that depend on each task, which `urgency.inherit` reads.
	var dependents: [Task.ID: [Task.ID]] = [:]

	public init(_ tasks: some Collection<Task>) {
		let statuses = Dictionary(
			tasks.map { ($0.id, $0.status) },
			uniquingKeysWith: { first, _ in first },
		)
		for task in tasks where task.status.isOpen {
			for dependency in task.dependencies {
				dependents[dependency, default: []].append(task.id)
				guard statuses[dependency]?.isOpen == true else {
					continue
				}
				blocked.insert(task.id)
				blocking.insert(dependency)
			}
		}
	}
}
