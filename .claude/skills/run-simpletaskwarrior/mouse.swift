// Posts real mouse events, which header menus, column drags and resizes need: System Events'
// `click` can't right-click or drag, and the table exposes no AX columns to act on instead.
// Usage: mouse click|rclick X Y, or mouse drag X1 Y1 X2 Y2. Points, global, top-left origin.
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
let start = CGPoint(x: Double(arguments[2])!, y: Double(arguments[3])!)

func post(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton = .left) {
	CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)!
		.post(tap: .cghidEventTap)
	usleep(60_000)
}

switch arguments[1] {
case "click":
	post(.mouseMoved, start)
	post(.leftMouseDown, start)
	post(.leftMouseUp, start)

case "drag":
	// Stepped, since AppKit starts a column drag or resize only after several dragged events.
	let end = CGPoint(x: Double(arguments[4])!, y: Double(arguments[5])!)
	post(.mouseMoved, start)
	post(.leftMouseDown, start)
	for step in 1 ... 20 {
		let fraction = Double(step) / 20
		post(
			.leftMouseDragged,
			CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction),
		)
	}
	post(.leftMouseUp, end)

case "rclick":
	post(.mouseMoved, start)
	post(.rightMouseDown, start, .right)
	post(.rightMouseUp, start, .right)

default:
	FileHandle.standardError.write(Data("unknown command \(arguments[1])\n".utf8))
	exit(64)
}
