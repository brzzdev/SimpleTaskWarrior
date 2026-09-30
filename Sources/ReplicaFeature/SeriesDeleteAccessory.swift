import AppKit
import Models

/// The controls under the sheet asking whether a Delete takes each Series: a pop-up for each, then
/// the chains the answer breaks, which change as the choices do.
final class SeriesDeleteAccessory: NSStackView {
	private let chainsCheckbox = NSButton(
		checkboxWithTitle: String(localized: "Repair Dependency Chains"),
		target: nil,
		action: nil,
	)
	private let chainsLabel = WrappingLabel(wrappingLabelWithString: "")
	private let send: (ReplicaFeature.Action) -> Void
	/// Each pop-up's template, by its tag's index.
	private let templates: [Models.Task.ID]

	init(prompt: ReplicaFeature.SeriesDeletePrompt, send: @escaping (ReplicaFeature.Action) -> Void) {
		self.send = send
		templates = prompt.choices.map(\.id)
		super.init(frame: NSRect(origin: .zero, size: NSSize(width: accessoryWidth, height: 0)))
		orientation = .vertical
		alignment = .leading

		let grid = NSGridView(views: prompt.choices.enumerated().map { index, choice in
			let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
			popUp.addItems(withTitles: [
				String(localized: "Delete This Task"),
				String(localized: "Delete All Tasks in Series"),
			])
			popUp.action = #selector(seriesPopUpChanged(_:))
			popUp.selectItem(at: choice.deletesSeries ? deleteSeriesItem : deleteTaskItem)
			popUp.tag = index
			popUp.target = self
			let label = NSTextField(labelWithString: "“\(choice.description)”")
			label.lineBreakMode = .byTruncatingTail
			return [label, popUp]
		})
		grid.column(at: 0).xPlacement = .trailing
		grid.rowAlignment = .firstBaseline
		addArrangedSubview(grid)

		chainsCheckbox.action = #selector(chainsCheckboxChanged(_:))
		chainsCheckbox.target = self
		addArrangedSubview(chainsCheckbox)
		chainsLabel.textColor = .secondaryLabelColor
		addArrangedSubview(chainsLabel)
		chainsLabel.widthAnchor.constraint(equalToConstant: accessoryWidth).isActive = true
		update(prompt)
	}

	@available(*, unavailable)
	required init(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	/// Shows the chains `prompt` asks about, where it asks about any, and fits itself to them.
	func update(_ prompt: ReplicaFeature.SeriesDeletePrompt) {
		chainsCheckbox.isHidden = prompt.chainRepairMessage == nil
		chainsCheckbox.state = prompt.repairsChains ? .on : .off
		chainsLabel.isHidden = prompt.chainRepairMessage == nil
		chainsLabel.stringValue = prompt.chainRepairMessage ?? ""
		setFrameSize(NSSize(width: accessoryWidth, height: fittingSize.height))
	}

	@objc
	private func chainsCheckboxChanged(_ checkbox: NSButton) {
		send(.repairChainsCheckboxChanged(repairsChains: checkbox.state == .on))
	}

	@objc
	private func seriesPopUpChanged(_ popUp: NSPopUpButton) {
		let deletesSeries = popUp.indexOfSelectedItem == deleteSeriesItem
		send(.seriesChoiceChanged(templates[popUp.tag], deletesSeries: deletesSeries))
	}
}

/// As wide as an alert's text.
private let accessoryWidth: CGFloat = 300

/// The pop-up items' indices, in the order it lists them.
private let deleteSeriesItem = 1
private let deleteTaskItem = 0
