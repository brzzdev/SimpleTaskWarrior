import App
import AppKit
import IssueReporting

@main
enum AppDriver {
	@MainActor
	static func main() {
		// Tests run hosted in the app, which then opens and restores no windows.
		let delegate = TestContext.current == nil ? AppDelegate() : nil
		// The application holds its delegate weakly.
		withExtendedLifetime(delegate) {
			NSApplication.shared.delegate = delegate
			NSApplication.shared.run()
		}
	}
}
