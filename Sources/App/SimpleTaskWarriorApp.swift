public import SwiftUI

public struct SimpleTaskWarriorApp: App {
	public var body: some Scene {
		WindowGroup {
			ContentUnavailableView("SimpleTaskWarrior", systemImage: "checklist")
		}
	}

	public init() {}
}
