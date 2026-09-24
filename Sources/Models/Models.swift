// Task decoding, Urgency, the blocked rule and the write planner: every Taskwarrior rule, in Swift.
public import Foundation

public struct Task: Equatable, Identifiable, Sendable {
	public var description: String
	/// The task's UUID, which holds still while the CLI renumbers `workingSetID`.
	public var id: UUID
	public var status: Status
	/// The ID `task` shows, absent when the task has left the working set.
	public var workingSetID: Int?

	public init(description: String, id: UUID, status: Status, workingSetID: Int?) {
		self.description = description
		self.id = id
		self.status = status
		self.workingSetID = workingSetID
	}
}

extension Task {
	/// Decodes a task from the properties TaskChampion stores, or nil when its UUID or status is
	/// one this app doesn't read.
	public init?(properties: [String: String], uuid: String, workingSetID: Int?) {
		guard
			let id = UUID(uuidString: uuid),
			let status = properties["status"].flatMap(Status.init(rawValue:))
		else {
			return nil
		}
		self.init(
			description: properties["description"] ?? "",
			id: id,
			status: status,
			workingSetID: workingSetID,
		)
	}
}

public enum Status: String, Sendable {
	case completed
	case deleted
	case pending
	case recurring
}
