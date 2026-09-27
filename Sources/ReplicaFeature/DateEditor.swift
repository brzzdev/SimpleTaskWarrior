// A date or duration attribute's field in the inspector, previewing what its text resolves to.
import AppKit
import ComposableArchitecture
import Models
import Taskrc

/// Edits one date or duration attribute of the inspected task, in Taskwarrior's own syntax.
/// Unfocused,
/// a date shows in the Mac's locale format; focused, as ISO local time, which reads back as the
/// same
/// second. Beneath it, what the text resolves to as you type, or why it doesn't.
///
/// Text that doesn't resolve stays, with its error, writing nothing, until Escape restores the
/// saved
/// value or another task drops it. A date also has a calendar popover beside it.
final class DateEditor: NSStackView, NSPopoverDelegate, NSTextFieldDelegate {
	/// What the editor resolves text with, for the Taskrc the window runs on.
	struct Resolver {
		var dateInput: DateInput
		var planner: WritePlanner
	}

	/// Sends an edit of the attribute to the task it was made for.
	var onSubmit: @MainActor (Models.Task.ID, TaskEdit) -> Void = { _, _ in }

	/// Text that didn't resolve, kept after its edit ended.
	private var draft: String?
	/// The task an edit belongs to, from its first keystroke, so a click on another row writes it to
	/// the task it was typed for. Nil while the text is unchanged, which writes nothing.
	private var editingTask: Models.Task.ID?
	private let field = FocusField(string: "")
	private let kind: UDAType
	private let messageLabel = NSTextField(wrappingLabelWithString: "")
	@Dependency(\.date.now) private var now
	/// The task the popover was opened for, and the date it picks.
	private var picking: (task: Models.Task.ID, picker: CalendarPicker)?
	private let property: String
	private var resolver: Resolver?
	/// The value the field last showed, so a store change that leaves it alone keeps the field as it
	/// is.
	private var shownValue: String?
	private var task: Models.Task?

	/// An editor of `property`, a date, or a duration where `kind` says so.
	init(property: String, kind: UDAType) {
		self.kind = kind
		self.property = property
		super.init(frame: .zero)
		field.delegate = self
		field.lineBreakMode = .byTruncatingTail
		field.onFocus = { [weak self] in
			self?.fieldWillFocus()
		}
		field.placeholderString = String(localized: "None")
		field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		messageLabel.isHidden = true
		messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		let row = NSStackView(views: [field])
		if kind == .date {
			let button = NSButton(
				image: NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)!,
				target: self,
				action: #selector(calendarButtonClicked(_:)),
			)
			button.contentTintColor = .secondaryLabelColor
			button.isBordered = false
			button.setAccessibilityLabel(String(localized: "Choose Date"))
			button.setContentHuggingPriority(.required, for: .horizontal)
			row.addArrangedSubview(button)
		}
		alignment = .leading
		orientation = .vertical
		spacing = 4
		setViews([row, messageLabel], in: .top)
		for view in [row, messageLabel] {
			view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
		}
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	/// Escape restores the saved value, leaving the field as if untouched.
	func control(_: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
		guard selector == #selector(cancelOperation(_:)) else {
			return false
		}
		draft = nil
		editingTask = nil
		textView.string = editableText
		textView.selectAll(nil)
		showMessage(for: nil)
		return true
	}

	func controlTextDidChange(_: Notification) {
		editingTask = editingTask ?? task?.id
		showMessage(for: field.stringValue)
	}

	/// Writes the text to the task it was typed for, where it resolves; otherwise keeps it as the
	/// draft, beside its error.
	func controlTextDidEndEditing(_: Notification) {
		let id = editingTask
		editingTask = nil
		guard let id, let task, task.id == id, let resolver else {
			field.stringValue = draft ?? displayText
			return
		}
		let text = field.stringValue
		let stored: String?
		do {
			stored = try resolver.planner.resolve(text, for: property, of: task.properties, at: now)
		} catch {
			draft = text
			return
		}
		draft = nil
		showMessage(for: nil)
		field.stringValue = displayText(stored)
		onSubmit(id, .setInput(property, text))
	}

	func popoverDidClose(_: Notification) {
		defer { picking = nil }
		guard let picking, let date = picking.picker.pickedDate else {
			return
		}
		// The pick replaces any draft, as typing it would.
		draft = nil
		showMessage(for: nil)
		field.stringValue = displayText(UDAValue.date(date).stored)
		onSubmit(picking.task, .set(property, .date(date)))
	}

	/// Shows `task`'s value, unless you're editing it or a draft holds the field, so the CLI changing
	/// it doesn't interrupt you. Another task drops the edit and the draft, keeping the cursor here.
	func show(_ task: Models.Task, isAnotherTask: Bool, resolver: Resolver) {
		self.resolver = resolver
		self.task = task
		let value = task.properties[property]
		defer { shownValue = value }
		if isAnotherTask {
			draft = nil
			editingTask = nil
			showMessage(for: nil)
			guard field.currentEditor() != nil else {
				field.stringValue = displayText
				return
			}
			field.abortEditing()
			window?.makeFirstResponder(field)
			return
		}
		guard draft == nil, value != shownValue else {
			return
		}
		guard let editor = field.currentEditor() else {
			field.stringValue = displayText
			return
		}
		// Focused but untouched, as after Return commits, so it follows the value it just wrote.
		if editingTask == nil {
			editor.string = editableText
		}
	}

	@objc
	private func calendarButtonClicked(_ button: NSButton) {
		// Ends an edit first, writing it, so the popover starts from its value.
		window?.makeFirstResponder(nil)
		guard let task else {
			return
		}
		let picker = CalendarPicker(date: value.flatMap(\.date))
		picking = (task.id, picker)
		let popover = NSPopover()
		popover.behavior = .transient
		popover.contentViewController = picker
		popover.delegate = self
		popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
	}

	/// Shows the saved text to edit, unless a draft holds the field.
	private func fieldWillFocus() {
		guard draft == nil else {
			return
		}
		field.stringValue = editableText
	}

	/// Shows what `text` resolves to, or why it doesn't, or nothing for nil or empty text.
	private func showMessage(for text: String?) {
		guard let text, !text.isEmpty, let task, let resolver else {
			messageLabel.isHidden = true
			return
		}
		messageLabel.isHidden = false
		do {
			let stored = try resolver.planner.resolve(
				text,
				for: property,
				of: task.properties,
				at: now,
			)
			messageLabel.stringValue = stored.map { UDAValue($0, as: kind) }?.preview ?? ""
			messageLabel.textColor = .secondaryLabelColor
		} catch let .invalidInput(_, error) {
			messageLabel.stringValue = message(for: error)
			messageLabel.textColor = .systemRed
		} catch {
			messageLabel.stringValue = message(for: .invalid)
			messageLabel.textColor = .systemRed
		}
	}

	private func message(for error: DateInputError) -> String {
		switch error {
		case let .holiday(name):
			String(localized: "Holidays such as “\(name)” aren’t supported")

		case .invalid:
			if kind == .duration {
				String(localized: "Not a duration")
			} else {
				String(localized: "Not a date")
			}

		case .outOfRange:
			String(localized: "Dates run from 1980 to 9999")
		}
	}
}

extension DateEditor {
	/// The saved value as it shows unfocused.
	private var displayText: String {
		displayText(task?.properties[property])
	}

	/// The saved value as ISO local time, or a duration as it displays, to edit.
	private var editableText: String {
		switch value {
		case let .date(date): resolver?.dateInput.isoLocal(date) ?? ""
		case let .duration(duration): duration.description
		case let .string(text): text
		case nil, .numeric, .uuid: ""
		}
	}

	private var value: UDAValue? {
		task?.properties[property].map { UDAValue($0, as: kind) }
	}

	/// `stored` as it shows unfocused: a date in the Mac's locale format, without a time at midnight,
	/// and a duration in its largest exact unit.
	private func displayText(_ stored: String?) -> String {
		switch stored.map({ UDAValue($0, as: kind) }) {
		case let .date(date):
			let isMidnight = Calendar.current.startOfDay(for: date) == date
			return date.formatted(date: .abbreviated, time: isMidnight ? .omitted : .shortened)

		case let .duration(duration):
			return duration.description

		case let .string(text):
			return text

		case nil, .numeric, .uuid:
			return ""
		}
	}
}

extension UDAValue {
	fileprivate var date: Date? {
		guard case let .date(date) = self else {
			return nil
		}
		return date
	}

	/// The value in full, as the editor previews it.
	fileprivate var preview: String {
		switch self {
		case let .date(date): date.formatted(date: .complete, time: .shortened)
		case let .duration(duration): duration.description
		case let .numeric(number): number.formatted()
		case let .string(text): text
		case let .uuid(uuid): uuid.uuidString.lowercased()
		}
	}
}

/// A calendar with an optional time of day, which picks midnight without one, as the CLI resolves a
/// date alone.
private final class CalendarPicker: NSViewController {
	/// The date picked, or nil where nothing changed.
	private(set) var pickedDate: Date?

	private let dayPicker = NSDatePicker()
	private let initialDate: Date?
	private let timeCheckbox = NSButton(
		checkboxWithTitle: String(localized: "Time"),
		target: nil,
		action: nil,
	)
	private let timePicker = NSDatePicker()

	/// Starts at `date`, or today without a time.
	init(date: Date?) {
		initialDate = date
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		let date = initialDate ?? Calendar.current.startOfDay(for: .now)
		dayPicker.datePickerElements = .yearMonthDay
		dayPicker.datePickerStyle = .clockAndCalendar
		dayPicker.dateValue = date
		timeCheckbox.state = Calendar.current.startOfDay(for: date) == date ? .off : .on
		timePicker.datePickerElements = .hourMinute
		timePicker.datePickerStyle = .textFieldAndStepper
		timePicker.dateValue = date
		timePicker.isEnabled = timeCheckbox.state == .on
		for control in [dayPicker, timeCheckbox, timePicker] {
			control.action = #selector(controlChanged(_:))
			control.target = self
		}

		let time = NSStackView(views: [timeCheckbox, timePicker])
		let stack = NSStackView(views: [dayPicker, time])
		stack.alignment = .leading
		stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
		stack.orientation = .vertical
		view = stack
	}

	@objc
	private func controlChanged(_: Any?) {
		timePicker.isEnabled = timeCheckbox.state == .on
		let calendar = Calendar.current
		var components = calendar.dateComponents([.day, .month, .year], from: dayPicker.dateValue)
		if timeCheckbox.state == .on {
			let time = calendar.dateComponents([.hour, .minute], from: timePicker.dateValue)
			components.hour = time.hour
			components.minute = time.minute
		}
		pickedDate = calendar.date(from: components)
	}
}

/// A single-line field that says when it takes focus, before its editor copies its text.
private final class FocusField: NSTextField {
	var onFocus: @MainActor () -> Void = {}

	override func becomeFirstResponder() -> Bool {
		onFocus()
		return super.becomeFirstResponder()
	}
}
