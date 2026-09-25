// PROTOTYPE — throwaway, never shipped. Answers #55's question: does an AppKit window shell give a
// title bar whose long Replica path tail-truncates, stretches with the window, never overlaps the
// inspector, and shows the full path on hover?
//
// Opens one window per variant, side by side:
//   native — NSWindow.title + NSWindow.subtitle, laid out by AppKit's titlebar sections
//   custom — a flexible NSToolbarItem holding two truncating labels, with a tooltip
//
// Run: `just prototype-title-bar` (interactive) or `just prototype-title-bar --sweep`, which resizes
// each window through a range of widths, logs the title's frame against the inspector's, and quits.

import AppKit

let path =
	"/private/var/folders/hx/bw5k_1sn2v1_ym14wdwy3kpw0000gp/T/issue55/a-rather-long-replica-folder-name/nested/deeper/replica"
let name = "replica"
let sweep = CommandLine.arguments.contains("--sweep")

enum Variant: String, CaseIterable {
	case custom
	case native
}

extension NSToolbarItem.Identifier {
	static let title = Self("title")
}

func placeholder(_ label: String, _ color: NSColor) -> NSViewController {
	let controller = NSViewController()
	let view = NSView()
	view.wantsLayer = true
	view.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
	let text = NSTextField(labelWithString: label)
	text.translatesAutoresizingMaskIntoConstraints = false
	view.addSubview(text)
	NSLayoutConstraint.activate([
		text.centerXAnchor.constraint(equalTo: view.centerXAnchor),
		text.centerYAnchor.constraint(equalTo: view.centerYAnchor),
	])
	controller.view = view
	return controller
}

final class Controller: NSWindowController, NSToolbarDelegate {
	let variant: Variant
	let split = NSSplitViewController()
	let inspector = placeholder("Inspector", .systemOrange)
	var titleField: NSTextField?

	/// The label AppKit (native) or we (custom) put the path in.
	var pathField: NSTextField? {
		if let titleField { return titleField }
		func find(_ view: NSView) -> NSTextField? {
			if let field = view as? NSTextField, field.stringValue == path { return field }
			for subview in view.subviews {
				if let found = find(subview) { return found }
			}
			return nil
		}
		return window?.contentView?.superview.flatMap(find)
	}

	init(variant: Variant, origin: NSPoint) {
		self.variant = variant
		let window = NSWindow(
			contentRect: NSRect(origin: origin, size: NSSize(width: 1_000, height: 500)),
			styleMask: [.closable, .fullSizeContentView, .miniaturizable, .resizable, .titled],
			backing: .buffered,
			defer: false,
		)
		super.init(window: window)

		let sidebar = NSSplitViewItem(sidebarWithViewController: placeholder("Sidebar", .systemBlue))
		let content = NSSplitViewItem(
			viewController: placeholder("Task table — variant: \(variant.rawValue)", .systemGreen),
		)
		let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
		inspectorItem.minimumThickness = 250
		split.splitViewItems = [sidebar, content, inspectorItem]

		window.contentViewController = split
		window.setContentSize(NSSize(width: 1_000, height: 500))
		window.setFrameOrigin(origin)
		// Named either way, so the Window menu and Mission Control still read it.
		window.title = name
		window.toolbarStyle = .unified
		switch variant {
		case .custom:
			window.titleVisibility = .hidden

		case .native:
			window.subtitle = path
		}

		let toolbar = NSToolbar(identifier: "prototype-\(variant.rawValue)")
		toolbar.delegate = self
		toolbar.displayMode = .iconOnly
		// Hides the right-click "Icon and Text / Icon Only / Text Only" menu.
		toolbar.allowsDisplayModeCustomization = false
		window.toolbar = toolbar

		NotificationCenter.default.addObserver(
			forName: NSWindow.didResizeNotification,
			object: window,
			queue: .main,
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.log("resize") }
		}
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		var items: [NSToolbarItem.Identifier] = [.toggleSidebar, .sidebarTrackingSeparator]
		if variant == .custom {
			items.append(.title)
		}
		items += [.flexibleSpace, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
		return items
	}

	func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		toolbarDefaultItemIdentifiers(toolbar)
	}

	func toolbar(
		_ toolbar: NSToolbar,
		itemForItemIdentifier identifier: NSToolbarItem.Identifier,
		willBeInsertedIntoToolbar flag: Bool,
	) -> NSToolbarItem? {
		guard identifier == .title else { return nil }

		let title = NSTextField(labelWithString: name)
		title.font = .preferredFont(forTextStyle: .headline)
		let subtitle = NSTextField(labelWithString: path)
		subtitle.font = .preferredFont(forTextStyle: .subheadline)
		subtitle.textColor = .secondaryLabelColor
		for label in [title, subtitle] {
			label.lineBreakMode = .byTruncatingTail
			label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		}
		let stack = NSStackView(views: [title, subtitle])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 0
		stack.toolTip = path
		// Flexible: a hard minimum, and a weak pull towards "as wide as possible", so the toolbar
		// hands it whatever space the section has left.
		let grow = stack.widthAnchor.constraint(equalToConstant: 10_000)
		grow.priority = NSLayoutConstraint.Priority(1)
		NSLayoutConstraint.activate([
			grow,
			stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
		])
		titleField = subtitle

		let item = NSToolbarItem(itemIdentifier: identifier)
		item.view = stack
		item.label = "Title"
		item.isBordered = false
		return item
	}

	func log(_ event: String) {
		guard let window else { return }
		let width = Int(window.frame.width)
		let inspectorCollapsed = split.splitViewItems[2].isCollapsed
		let inspectorMinX = Int(inspector.view.convert(inspector.view.bounds, to: nil).minX)
		let visible = window.toolbar?.visibleItems?.map(\.itemIdentifier.rawValue) ?? []
		let hidden = (window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [])
			.filter { !visible.contains($0) && !$0.contains("Space") }
		guard let field = pathField else {
			print("[\(variant)] \(event) window=\(width) path label NOT FOUND (hidden: \(hidden))")
			return
		}
		let frame = field.convert(field.bounds, to: nil)
		let natural = Int(field.cell?.cellSize.width ?? 0)
		let overlap = !inspectorCollapsed && frame.maxX > CGFloat(inspectorMinX)
		print(
			"[\(variant)] \(event) window=\(width) path x=\(Int(frame.minX))…\(Int(frame.maxX)) "
				+ "(w=\(Int(frame.width)), natural=\(natural), truncated=\(natural > Int(frame.width))) "
				+ "inspector=\(inspectorCollapsed ? "collapsed" : "x=\(inspectorMinX)") "
				+ "overlap=\(overlap) overflowed=\(hidden)",
		)
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	var controllers: [Controller] = []

	func applicationDidFinishLaunching(_ notification: Notification) {
		controllers = Variant.allCases.enumerated().map { index, variant in
			let controller = Controller(
				variant: variant,
				origin: NSPoint(x: 40 + index * 60, y: 80 + index * 560),
			)
			controller.showWindow(nil)
			return controller
		}
		NSApp.activate()
		guard sweep else { return }

		Task { @MainActor in
			try? await Task.sleep(for: .seconds(1))
			for sidebarCollapsed in [false, true] {
				for controller in controllers {
					controller.split.splitViewItems[0].isCollapsed = sidebarCollapsed
				}
				for width in [1_600, 1_300, 1_100, 950, 850, 750, 650] {
					for controller in controllers {
						guard let window = controller.window else { continue }
						var frame = window.frame
						frame.size.width = CGFloat(width)
						window.setFrame(frame, display: true)
					}
					try? await Task.sleep(for: .milliseconds(300))
					for controller in controllers {
						controller.log("sweep sidebar=\(sidebarCollapsed ? "collapsed" : "shown")")
					}
				}
			}
			NSApp.terminate(nil)
		}
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
