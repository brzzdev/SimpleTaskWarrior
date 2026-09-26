// The inspector: the Replica's full path, over what's selected.
import AppKit
import ComposableArchitecture
import SwiftNavigation

/// Shows the Replica's full path, which the window's subtitle cuts short, and what's selected.
final class InspectorController: NSViewController {
	private let noSelectionView = EmptyStateView(
		symbolName: "sidebar.trailing",
		title: String(localized: "No Selection"),
	)
	private let pathField = NSTextField(wrappingLabelWithString: "")
	private let pathSection = NSStackView()
	private let store: StoreOf<ReplicaFeature>

	init(store: StoreOf<ReplicaFeature>) {
		self.store = store
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let view = NSView()
		let heading = NSTextField(labelWithString: String(localized: "Replica"))
		heading.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
		heading.textColor = .secondaryLabelColor
		// A path has few spaces to break at.
		pathField.lineBreakMode = .byCharWrapping
		pathField.isSelectable = true
		let reveal = NSButton(
			title: String(localized: "Reveal in Finder"),
			target: self,
			action: #selector(revealInFinderButtonClicked(_:)),
		)
		reveal.controlSize = .small
		pathSection.alignment = .leading
		pathSection.orientation = .vertical
		pathSection.setViews([heading, pathField, reveal], in: .top)
		pathSection.setCustomSpacing(4, after: heading)
		for subview in [pathSection, noSelectionView] {
			subview.translatesAutoresizingMaskIntoConstraints = false
			view.addSubview(subview)
		}
		let safeArea = view.safeAreaLayoutGuide
		NSLayoutConstraint.activate([
			noSelectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			noSelectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			noSelectionView.topAnchor.constraint(equalTo: pathSection.bottomAnchor),
			noSelectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			pathField.widthAnchor.constraint(equalTo: pathSection.widthAnchor),
			pathSection.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
			pathSection.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 16),
			pathSection.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
		])
		self.view = view
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		observe { [weak self] in
			guard let self else {
				return
			}
			let path = store.directory?.path(percentEncoded: false)
			pathField.stringValue = path ?? ""
			pathSection.isHidden = path == nil
			noSelectionView.isHidden = !store.selection.isEmpty
		}
	}

	@objc
	func revealInFinderButtonClicked(_: Any?) {
		guard let directory = store.directory else {
			return
		}
		NSWorkspace.shared.activateFileViewerSelecting([directory])
	}
}
