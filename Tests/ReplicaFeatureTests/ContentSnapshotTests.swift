import AppKit
import ComposableArchitecture
import Foundation
@testable import ReplicaFeature
import SnapshotTesting
import Taskrc
import TaskrcClient
import Testing
import TestSupport

/// Image snapshots of the Replica window's leaf content views, in light and dark, at 2x whatever
/// the
/// screen. The CI runner's rendering is the reference: a Mac's differs in sub-pixel text positions
/// and in how controls draw, so the suite runs only on CI. There a missing or failing snapshot is
/// recorded afresh and uploaded as the run's `snapshots` artifact, whose images are committed once
/// the change they show is intended.
@MainActor
@Suite(.enabled(
	if: ProcessInfo.processInfo.environment["CI"] != nil,
	"The CI runner's rendering is the reference",
))
struct ContentSnapshotTests {
	@Test
	func dataLocationBanner() {
		var state = ReplicaFeature.State(bookmark: Data())
		state.directory = replicaDirectory
		let taskrc = Taskrc(path: taskrcFile.path(), environment: .fixture) { path, _ in
			Taskrc.File(contents: "data.location=~/Sync/task", realPath: path)
		}
		state.taskrc = TaskrcClient.Loaded(taskrc: taskrc, url: taskrcFile)
		assertBannerSnapshots(of: state)
	}

	@Test
	func failure() {
		let view = EmptyStateView(
			symbolName: "exclamationmark.triangle",
			title: String(localized: "Can't Open Replica"),
		)
		view.message = "The folder “.task” couldn’t be opened because it doesn’t exist."
		assertAppearanceSnapshots(of: view, size: CGSize(width: 560, height: 320))
	}

	@Test
	func inspector() {
		var state = ReplicaFeature.State(bookmark: Data())
		state.directory = URL(
			filePath: "/Users/paul/Library/Mobile Documents/com~apple~CloudDocs/Taskwarrior/replica",
			directoryHint: .isDirectory,
		)
		let inspector = InspectorController(store: Store(initialState: state) { ReplicaFeature() })
		assertAppearanceSnapshots(of: inspector.view, size: CGSize(width: 270, height: 420))
	}

	@Test
	func narrowFailure() {
		let view = EmptyStateView(
			symbolName: "exclamationmark.triangle",
			title: String(localized: "Can't Open Replica"),
		)
		view.message = "The folder “.task” couldn’t be opened because it doesn’t exist."
		assertAppearanceSnapshots(of: view, size: CGSize(width: 220, height: 320))
	}

	@Test
	func problemBanner() {
		// No folder, so TW's default data.location doesn't add its own banner.
		var state = ReplicaFeature.State(bookmark: Data())
		let include = Taskrc.Include(file: taskrcFile.path(), line: "include ~/.config/task/secrets.rc")
		state.taskrc = TaskrcClient.Loaded(
			problem: Taskrc.Problem(
				.unreadable(path: "/Users/paul/.config/task/secrets.rc", unsetVariables: []),
				at: Taskrc.Location(file: taskrcFile.path(), line: 12),
				include: include,
			),
			taskrc: .defaults,
			url: taskrcFile,
		)
		assertBannerSnapshots(of: state)
	}

	@Test
	func saveFailureBanner() {
		var state = ReplicaFeature.State(bookmark: Data())
		state.taskrcSaveFailure = ReplicaFeature.TaskrcSaveFailure(
			message: "The file “.taskrc” couldn’t be opened.",
			retry: .taskrc,
		)
		assertBannerSnapshots(of: state)
	}

	@Test
	func taskrcHintBanner() {
		var state = ReplicaFeature.State(bookmark: Data())
		state.isTaskrcHintPresented = true
		assertBannerSnapshots(of: state)
	}
}

/// Snapshots the one banner `state` calls for, at a fixed width and the height it takes there.
@MainActor
private func assertBannerSnapshots(
	of state: ReplicaFeature.State,
	fileID: StaticString = #fileID,
	filePath: StaticString = #filePath,
	testName: String = #function,
	line: UInt = #line,
	column: UInt = #column,
) {
	let banners = ReplicaContentController.banners(
		for: Store(initialState: state) { ReplicaFeature() },
		target: nil,
	)
	#expect(banners.count == 1)
	guard let banner = banners.first else {
		return
	}
	let width = banner.widthAnchor.constraint(equalToConstant: bannerWidth)
	width.isActive = true
	// Laid out until it settles, as a window would, so its label wraps at the banner's width.
	var height: CGFloat = 0
	for _ in 1 ... 3 {
		banner.frame.size = CGSize(width: bannerWidth, height: height)
		banner.layoutSubtreeIfNeeded()
		height = banner.fittingSize.height
	}
	width.isActive = false
	assertAppearanceSnapshots(
		of: banner,
		size: CGSize(width: bannerWidth, height: height),
		fileID: fileID,
		filePath: filePath,
		testName: testName,
		line: line,
		column: column,
	)
}

/// Snapshots `view` at `size` in the light and the dark appearance, over the window background.
@MainActor
private func assertAppearanceSnapshots(
	of view: NSView,
	size: CGSize,
	fileID: StaticString = #fileID,
	filePath: StaticString = #filePath,
	testName: String = #function,
	line: UInt = #line,
	column: UInt = #column,
) {
	for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
		assertSnapshot(
			of: render(view, size: size, appearance: appearance),
			as: .image(perceptualPrecision: perceptualPrecision),
			named: name,
			fileID: fileID,
			file: filePath,
			testName: testName,
			line: line,
			column: column,
		)
	}
}

/// `view` laid out at `size` over the window background, drawn at `renderScale`.
@MainActor
private func render(_ view: NSView, size: CGSize, appearance: NSAppearance.Name) -> NSImage {
	let container = NSBox(frame: CGRect(origin: .zero, size: size))
	container.appearance = NSAppearance(named: appearance)
	container.borderWidth = 0
	container.boxType = .custom
	container.contentViewMargins = .zero
	container.fillColor = .windowBackgroundColor
	container.titlePosition = .noTitle
	container.contentView = view
	container.layoutSubtreeIfNeeded()
	let bitmap = NSBitmapImageRep(
		bitmapDataPlanes: nil,
		pixelsWide: Int(size.width * renderScale),
		pixelsHigh: Int(size.height * renderScale),
		bitsPerSample: 8,
		samplesPerPixel: 4,
		hasAlpha: true,
		isPlanar: false,
		colorSpaceName: .deviceRGB,
		bytesPerRow: 0,
		bitsPerPixel: 0,
	)!
	bitmap.size = size
	container.cacheDisplay(in: container.bounds, to: bitmap)
	container.contentView = nil
	let image = NSImage(size: size)
	image.addRepresentation(bitmap)
	return image
}

private let bannerWidth: CGFloat = 640

/// Loose enough for antialiasing to differ between the Mac that records and the CI runner.
private let perceptualPrecision: Float = 0.98

private let renderScale: CGFloat = 2

private let replicaDirectory = URL(filePath: "/Users/paul/.task", directoryHint: .isDirectory)

private let taskrcFile = URL(filePath: "/Users/paul/.taskrc")
