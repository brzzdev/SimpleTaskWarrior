// The Replica's content: banners over the task table, or why the window has no Replica.
import AppKit
import ComposableArchitecture
import SwiftNavigation
import Taskrc
import TaskrcClient

/// Stacks the banners over the task table, and shows why the window has no Replica in place of
/// both.
final class ReplicaContentController: NSViewController {
	private let bannerStack = NSStackView()
	/// Down the responder chain to the window.
	private let closeWindowButton = NSButton(
		title: String(localized: "Close Window"),
		target: nil,
		action: #selector(NSWindow.performClose(_:)),
	)
	/// Down the responder chain to the window's controller, which opens the panel.
	private let locateButton = NSButton(
		title: String(localized: "Locate…"),
		target: nil,
		action: #selector(ReplicaWindowController.locateReplica(_:)),
	)
	/// Down the responder chain to the window's controller, as the menu item's is.
	private let openReplacementButton = NSButton(
		title: String(localized: "Open Replacement"),
		target: nil,
		action: #selector(ReplicaWindowController.openReplacement(_:)),
	)
	private let store: StoreOf<ReplicaFeature>
	private let table: TaskTableController
	private let unavailableView = EmptyStateView(symbolName: "exclamationmark.triangle", title: "")

	init(autosaveName: String, store: StoreOf<ReplicaFeature>) {
		self.store = store
		table = TaskTableController(autosaveName: autosaveName, store: store)
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let view = NSView()
		addChild(table)
		bannerStack.alignment = .width
		bannerStack.orientation = .vertical
		bannerStack.spacing = 0
		for subview in [bannerStack, table.view, unavailableView] {
			subview.translatesAutoresizingMaskIntoConstraints = false
			view.addSubview(subview)
		}
		// Below the toolbar the window's content runs under.
		let safeArea = view.safeAreaLayoutGuide
		NSLayoutConstraint.activate([
			bannerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			bannerStack.topAnchor.constraint(equalTo: safeArea.topAnchor),
			bannerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			table.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			table.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			table.view.topAnchor.constraint(equalTo: bannerStack.bottomAnchor),
			table.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			unavailableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			unavailableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			unavailableView.topAnchor.constraint(equalTo: safeArea.topAnchor),
			unavailableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
		])
		self.view = view
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		observe { [weak self] in
			guard let self else {
				return
			}
			bannerStack.setViews(Self.banners(for: store, target: self), in: .top)
		}
		observe { [weak self] in
			guard let self else {
				return
			}
			let unavailable = store.unavailable
			bannerStack.isHidden = unavailable != nil
			unavailableView.isHidden = unavailable == nil
			guard let unavailable else {
				return
			}
			let path = store.directory?.path(percentEncoded: false)
			switch unavailable {
			case let .cantOpen(reason):
				unavailableView.title = String(localized: "Can't Open Replica")
				unavailableView.message = [reason, path].compactMap(\.self).joined(separator: "\n")
				unavailableView.actions = [locateButton, closeWindowButton]

			case .notFound:
				unavailableView.title = String(localized: "Replica Not Found")
				unavailableView.message = path.map { String(localized: "It was last at \($0).") }
				unavailableView.actions = [locateButton, closeWindowButton]

			case .openElsewhere:
				unavailableView.title = String(localized: "Replica Open in Another Window")
				unavailableView.message = path
					.map { String(localized: "Another window has \($0) open.") }
				unavailableView.actions = [closeWindowButton]

			case .replaced:
				unavailableView.title = String(localized: "This Replica Was Replaced")
				unavailableView.message = path.map { String(localized: "A different Replica is now at \($0).") }
				unavailableView.actions = [openReplacementButton, locateButton, closeWindowButton]
			}
		}
	}

	/// The banners `store` calls for, top to bottom, whose buttons send to `target`.
	static func banners(for store: StoreOf<ReplicaFeature>, target: AnyObject?) -> [BannerView] {
		var banners: [BannerView] = []
		if store.isReadFailureBannerPresented, let reason = store.readFailure {
			banners.append(
				BannerView(
					symbolName: "exclamationmark.triangle.fill",
					message: String(localized: "Can't read the Replica: \(reason)"),
					actions: [],
				),
			)
		}
		if store.isTaskrcHintPresented {
			let close = NSButton(
				image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
				target: target,
				action: #selector(Self.taskrcHintCloseButtonClicked(_:)),
			)
			close.isBordered = false
			close.setAccessibilityLabel(String(localized: "Close"))
			banners.append(
				BannerView(
					symbolName: "gearshape",
					message: String(
						localized: "Choose your Taskrc to use its UDAs, Urgency coefficients and Context.",
					),
					actions: [
						NSButton(
							title: String(localized: "Choose Taskrc…"),
							target: target,
							action: #selector(Self.chooseTaskrcButtonClicked(_:)),
						),
						close,
					],
				),
			)
		}
		if let problem = store.taskrc?.problem {
			let chooseTaskrc = NSButton(
				title: String(localized: "Choose Taskrc…"),
				target: target,
				action: #selector(Self.chooseTaskrcButtonClicked(_:)),
			)
			banners.append(
				BannerView(
					symbolName: "exclamationmark.triangle.fill",
					message: message(for: problem),
					actions: store.hasUnreachableFile ? [chooseTaskrc] : [],
				),
			)
		}
		if let failure = store.taskrcSaveFailure {
			let tryAgain = NSButton(
				title: String(localized: "Try Again…"),
				target: target,
				action: #selector(Self.tryAgainButtonClicked(_:)),
			)
			banners.append(
				BannerView(
					symbolName: "exclamationmark.triangle.fill",
					message: String(
						localized: "SimpleTaskWarrior couldn't keep access to the file: \(failure.message)",
					),
					actions: failure.canRetry ? [tryAgain] : [],
				),
			)
		}
		if let location = store.otherDataLocation {
			banners.append(
				BannerView(
					symbolName: "info.circle",
					message: String(localized: "The Taskrc's data.location is \(location), not this Replica."),
					actions: [],
				),
			)
		}
		return banners
	}

	@objc
	func chooseTaskrcButtonClicked(_: Any?) {
		store.send(.chooseTaskrcButtonTapped)
	}

	@objc
	func taskrcHintCloseButtonClicked(_: Any?) {
		store.send(.taskrcHintCloseButtonTapped)
	}

	@objc
	func tryAgainButtonClicked(_: Any?) {
		store.send(.tryAgainButtonTapped)
	}
}

/// A strip across the top of the task list: a symbol, a message and the buttons that act on it.
final class BannerView: NSView {
	init(symbolName: String, message: String, actions: [NSButton]) {
		super.init(frame: .zero)
		let background = NSVisualEffectView()
		background.blendingMode = .withinWindow
		background.material = .headerView
		let symbol = NSImageView()
		symbol.contentTintColor = .secondaryLabelColor
		symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
		let label = WrappingLabel(wrappingLabelWithString: message)
		label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		label.setContentHuggingPriority(.defaultLow, for: .horizontal)
		let stack = NSStackView(views: [symbol, label] + actions)
		stack.alignment = .centerY
		let separator = NSBox()
		separator.boxType = .separator
		for subview in [background, stack, separator] {
			subview.translatesAutoresizingMaskIntoConstraints = false
			addSubview(subview)
		}
		NSLayoutConstraint.activate([
			background.bottomAnchor.constraint(equalTo: bottomAnchor),
			background.leadingAnchor.constraint(equalTo: leadingAnchor),
			background.topAnchor.constraint(equalTo: topAnchor),
			background.trailingAnchor.constraint(equalTo: trailingAnchor),
			separator.bottomAnchor.constraint(equalTo: bottomAnchor),
			separator.leadingAnchor.constraint(equalTo: leadingAnchor),
			separator.trailingAnchor.constraint(equalTo: trailingAnchor),
			// In constraints, since a stack aligned on centre lines leaves its edge insets out of its
			// height.
			stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
			stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
		])
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
}

extension NSTableView {
	/// A cell the table can reuse, or a new one from `make`.
	func reusedCell<Cell: NSView>(_ make: () -> Cell) -> Cell {
		let identifier = NSUserInterfaceItemIdentifier(String(describing: Cell.self))
		if let cell = makeView(withIdentifier: identifier, owner: nil) as? Cell {
			return cell
		}
		let cell = make()
		cell.identifier = identifier
		return cell
	}
}

/// A caption-sized label, as the table's and the inspector's markers are.
@MainActor
func captionLabel(_ string: String, color: NSColor) -> NSTextField {
	let label = NSTextField(labelWithString: string)
	label.font = .preferredFont(forTextStyle: .caption1)
	label.textColor = color
	return label
}

/// A label that tail-truncates.
@MainActor
func truncatingLabel() -> NSTextField {
	let label = NSTextField(labelWithString: "")
	label.lineBreakMode = .byTruncatingTail
	label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
	return label
}

/// A label that wraps at whatever width it's laid out at. An `NSTextField` otherwise reports its
/// height for the width it was last told, so its container sizes itself for too few lines.
final class WrappingLabel: NSTextField {
	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		guard preferredMaxLayoutWidth != newSize.width else {
			return
		}
		preferredMaxLayoutWidth = newSize.width
		invalidateIntrinsicContentSize()
	}
}

/// A symbol, a title, an optional message and the buttons that act on it, centred in the space it's
/// given.
final class EmptyStateView: NSView {
	/// In a row under the message.
	var actions: [NSButton] = [] {
		didSet {
			actionStack.setViews(actions, in: .center)
			actionStack.isHidden = actions.isEmpty
		}
	}

	/// Under the title, where there's something to explain.
	var message: String? {
		didSet {
			messageLabel.isHidden = message == nil
			messageLabel.stringValue = message ?? ""
		}
	}

	private let actionStack = NSStackView()
	private let messageLabel = WrappingLabel(wrappingLabelWithString: "")
	private let titleLabel = NSTextField(labelWithString: "")

	var title: String {
		get { titleLabel.stringValue }
		set { titleLabel.stringValue = newValue }
	}

	init(symbolName: String, title: String) {
		super.init(frame: .zero)
		let symbol = NSImageView()
		symbol.contentTintColor = .tertiaryLabelColor
		symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
		symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
		titleLabel.stringValue = title
		titleLabel.font = .boldSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize)
		titleLabel.textColor = .secondaryLabelColor
		messageLabel.alignment = .center
		messageLabel.isHidden = true
		messageLabel.textColor = .secondaryLabelColor
		actionStack.isHidden = true
		let stack = NSStackView(views: [symbol, titleLabel, messageLabel, actionStack])
		stack.orientation = .vertical
		stack.setCustomSpacing(16, after: messageLabel)
		stack.spacing = 8
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		// Short enough lines to read where the view is wide, and as wide as that where it's not, since
		// a wrapping label would otherwise keep whatever narrow width it first wrapped at.
		let readableWidth = messageLabel.widthAnchor.constraint(equalToConstant: readableMessageWidth)
		readableWidth.priority = NSLayoutConstraint.Priority(500)
		NSLayoutConstraint.activate([
			messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: readableMessageWidth),
			readableWidth,
			stack.centerXAnchor.constraint(equalTo: centerXAnchor),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
			stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
			stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
		])
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}
}

/// The widest an empty state's message runs, for lines short enough to read.
private let readableMessageWidth: CGFloat = 360

/// The banner's text for `problem`: where it is, what's wrong, and, when the window keeps running
/// on an earlier parse, what that risks.
private func message(for problem: Taskrc.Problem) -> String {
	let error =
		switch problem.kind {
		case let .includeNestedTooDeeply(path):
			"\(path) is included more than \(Taskrc.maximumIncludeDepth) levels deep."

		case let .invalidUDAType(uda, type):
			"UDA \(uda) has type \(type), which Taskwarrior doesn't know."

		case let .invalidWeekstart(day):
			"weekstart is \(day), which isn't Sunday or Monday."

		case let .malformedLine(line):
			"“\(line)” isn't a key=value line or an include."

		case let .notFound(path, variables):
			"\(path) doesn't exist." + unsetVariablesNote(variables)

		case let .unreadable(path, variables):
			"SimpleTaskWarrior needs access to \(path)." + unsetVariablesNote(variables)

		case let .unsetVariables(variables, key):
			"\(key) is missing variables." + unsetVariablesNote(variables)
		}
	let location = problem.location.map { "\($0.file), line \($0.line): " } ?? ""
	let stale =
		problem.kind.isFatal
			? " Running on the last Taskrc that loaded, or Taskwarrior's defaults, so the Context's"
				+ " defaults for new tasks may be out of date."
			: ""
	return location + error + stale
}

/// Names `variables`, which expanded to nothing.
private func unsetVariablesNote(_ variables: [String]) -> String {
	guard !variables.isEmpty else {
		return ""
	}
	let names = ListFormatter.localizedString(byJoining: variables.map { "$\($0)" })
	return " \(names) \(variables.count == 1 ? "isn't" : "aren't") set for SimpleTaskWarrior."
}
