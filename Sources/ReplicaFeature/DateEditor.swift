// A date or duration attribute's field in the inspector, previewing what its text resolves to.
import AppKit
import ComposableArchitecture
import Models
import Taskrc

/// Edits one date or duration attribute of the inspected task, in Taskwarrior's own syntax.
/// Unfocused, a date shows in the Mac's locale format; focused, as ISO local time, which reads back
/// as the same second. Beneath it, what the text resolves to as you type, or why it doesn't.
///
/// Text that doesn't resolve stays, with its error, writing nothing, until Escape restores the
/// saved value or another task drops it. A date also has a calendar popover beside it.
final class DateEditor: NSStackView, NSPopoverDelegate, NSTextFieldDelegate {
	private let field = FocusField(string: "")
	/// Whether the field holds text that didn't resolve, kept after its edit ended.
	private var hasDraft = false
	/// Whether you've typed since the field last showed the saved value, since untouched text
	/// writes nothing.
	private var isEdited = false
	private let kind: UDAType
	private let messageLabel = NSTextField(wrappingLabelWithString: "")
	@Dependency(\.date.now) private var now
	/// Sends an edit of the attribute to the task it was made for.
	private let onSubmit: @MainActor (Models.Task.ID, TaskEdit) -> Void
	/// The task the popover was opened for, and the date it picks.
	private var picking: (task: Models.Task.ID, picker: CalendarPicker)?
	/// Resolves text for the Taskrc the window runs on.
	private var planner: WritePlanner?
	private let property: String
	private var task: Models.Task?
	@Dependency(\.timeZone) private var timeZone

	/// An editor of `property`, a date, or a duration where `kind` says so.
	init(
		property: String,
		kind: UDAType,
		onSubmit: @escaping @MainActor (Models.Task.ID, TaskEdit) -> Void,
	) {
		self.kind = kind
		self.onSubmit = onSubmit
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
		clearDraft()
		textView.string = editableText
		textView.selectAll(nil)
		return true
	}

	func controlTextDidChange(_: Notification) {
		isEdited = true
		showMessage(for: field.stringValue)
	}

	/// Writes the text, where it resolves; otherwise keeps it as the draft, beside its error.
	/// Editing ends before a click on another row selects it, so the text goes to its own task.
	func controlTextDidEndEditing(_: Notification) {
		guard isEdited, let task, let planner else {
			if !hasDraft {
				field.stringValue = displayText(saved)
			}
			return
		}
		isEdited = false
		let text = field.stringValue
		let stored: String?
		do {
			stored = try planner.resolve(text, for: property, of: task.properties, at: now)
		} catch {
			hasDraft = true
			return
		}
		clearDraft()
		field.stringValue = displayText(stored)
		onSubmit(task.id, .setInput(property, text: text))
	}

	func popoverDidClose(_: Notification) {
		defer { picking = nil }
		guard let picking, let date = picking.picker.pickedDate else {
			return
		}
		// The pick replaces any draft, as typing it would.
		clearDraft()
		field.stringValue = displayText(UDAValue.date(date).stored)
		onSubmit(picking.task, .set(property, .date(date)))
	}

	/// Shows `task`'s value, unless you're editing it or a draft holds the field, so the CLI changing
	/// it doesn't interrupt you. Another task drops the edit and the draft, keeping the cursor here.
	func show(_ task: Models.Task, isAnotherTask: Bool, planner: WritePlanner) {
		let previous = saved
		self.planner = planner
		self.task = task
		if isAnotherTask {
			clearDraft()
			guard field.currentEditor() != nil else {
				field.stringValue = displayText(saved)
				return
			}
			field.abortEditing()
			window?.makeFirstResponder(field)
			return
		}
		guard !hasDraft, saved != previous else {
			return
		}
		guard let editor = field.currentEditor() else {
			field.stringValue = displayText(saved)
			return
		}
		// Focused but untouched, as after Return commits, so it follows the value it just wrote.
		if !isEdited {
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
		var date: Date?
		if case let .date(saved) = saved.map({ UDAValue($0, as: kind) }) {
			date = saved
		}
		let picker = CalendarPicker(date: date)
		picking = (task.id, picker)
		let popover = NSPopover()
		popover.behavior = .transient
		popover.contentViewController = picker
		popover.delegate = self
		popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
	}

	/// Forgets the typed text and its message, leaving the field as if untouched.
	private func clearDraft() {
		hasDraft = false
		isEdited = false
		showMessage(for: nil)
	}

	/// Shows the saved text to edit, unless a draft holds the field.
	private func fieldWillFocus() {
		guard !hasDraft else {
			return
		}
		field.stringValue = editableText
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

	/// Shows what `text` resolves to, in full, or why it doesn't, or nothing for nil or empty text.
	private func showMessage(for text: String?) {
		guard let text, !text.isEmpty, let task, let planner else {
			messageLabel.isHidden = true
			return
		}
		messageLabel.isHidden = false
		do {
			let stored = try planner.resolve(text, for: property, of: task.properties, at: now)
			messageLabel.stringValue = self.text(stored) {
				// With seconds where there are any, so the preview is what's stored.
				$0.formatted(date: .complete, time: $0.hasSeconds ? .standard : .shortened)
			}
			messageLabel.textColor = .secondaryLabelColor
		} catch {
			messageLabel.stringValue = message(for: error)
			messageLabel.textColor = .systemRed
		}
	}
}

extension DateEditor {
	/// The saved value as ISO local time, or a duration as it displays, to edit.
	private var editableText: String {
		text(saved) { [timeZone] in $0.isoLocal(in: timeZone) }
	}

	private var saved: String? {
		task?.properties[property]
	}

	/// `stored` as it shows unfocused: a date in the Mac's locale format, without a time at midnight.
	private func displayText(_ stored: String?) -> String {
		text(stored) { $0.formatted(date: .abbreviated, time: $0.isMidnight ? .omitted : .shortened) }
	}

	/// `stored` as text, a date as `format` writes it and a duration in its largest exact unit. A
	/// value that doesn't read as the attribute's type shows as stored.
	private func text(_ stored: String?, date format: (Date) -> String) -> String {
		switch stored.map({ UDAValue($0, as: kind) }) {
		case let .date(date): format(date)
		case let .duration(duration): duration.description
		case let .string(text): text
		case nil, .numeric, .uuid: ""
		}
	}
}

extension Date {
	fileprivate var hasSeconds: Bool {
		Calendar.current.component(.second, from: self) != 0
	}

	/// Whether the date is the start of its day, as a date without a time resolves.
	fileprivate var isMidnight: Bool {
		Calendar.current.startOfDay(for: self) == self
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
		timeCheckbox.state = date.isMidnight ? .off : .on
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
