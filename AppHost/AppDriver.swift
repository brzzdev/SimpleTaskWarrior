import App
import IssueReporting
import SwiftUI

@main
enum AppDriver {
	static func main() {
		if TestContext.current == nil {
			SimpleTaskWarriorApp.main()
		} else {
			TestApp.main()
		}
	}
}

private struct TestApp: App {
	var body: some Scene {
		WindowGroup {}
	}
}
