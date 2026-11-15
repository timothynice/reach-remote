import AppKit
import ApplicationServices

/// Coordinates are normalized in the selected display, including non-main displays.
final class DesktopInput {
    var displayFrame = CGRect.zero
    private var dragging = false
    private var dragButton: CGMouseButton = .left
    private var lastPoint = CGPoint.zero
    private var heldKeys: Set<CGKeyCode> = []
    var allowed: Bool { AXIsProcessTrusted() }

    func pointer(action: String, x: Double, y: Double, button: Int = 0) {
        guard allowed, x.isFinite, y.isFinite, !displayFrame.isEmpty else { return }
        let point = CGPoint(x: displayFrame.minX + min(1, max(0, x)) * displayFrame.width,
                            y: displayFrame.minY + min(1, max(0, y)) * displayFrame.height)
        lastPoint = point
        let right = button == 1
        let mouseButton: CGMouseButton = right ? .right : .left
        switch action {
        case "click", "rightClick":
            let isRight = right || action == "rightClick"
            emit(isRight ? .rightMouseDown : .leftMouseDown, point, isRight ? .right : .left)
            emit(isRight ? .rightMouseUp : .leftMouseUp, point, isRight ? .right : .left)
        case "down": dragging = true; dragButton = mouseButton; emit(right ? .rightMouseDown : .leftMouseDown, point, mouseButton)
        case "up": dragging = false; emit(right ? .rightMouseUp : .leftMouseUp, point, mouseButton)
        case "move": emit(dragging ? (dragButton == .right ? .rightMouseDragged : .leftMouseDragged) : .mouseMoved, point, dragButton)
        default: break
        }
    }

    private func emit(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    }

    func scroll(dx: Double, dy: Double) {
        guard allowed, dx.isFinite, dy.isFinite else { return }
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: Int32(min(2000, max(-2000, dy))), wheel2: Int32(min(2000, max(-2000, dx))), wheel3: 0)?.post(tap: .cghidEventTap)
    }

    func text(_ string: String) {
        guard allowed, string.utf16.count <= 16_384 else { return }
        // CGEvent supports UTF-16; chunk at Character boundaries so surrogate pairs stay together.
        for character in string {
            let chars = Array(String(character).utf16)
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { continue }
            chars.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: $0.baseAddress) }
            event.post(tap: .cghidEventTap)
            event.type = .keyUp
            event.post(tap: .cghidEventTap)
        }
    }

    func key(code: UInt16, modifiers: UInt64, down: Bool?) {
        guard allowed else { return }
        let flags = CGEventFlags(rawValue: modifiers)
        func post(_ pressed: Bool) {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: pressed) else { return }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            if pressed { heldKeys.insert(code) } else { heldKeys.remove(code) }
        }
        if let down { post(down) } else { post(true); post(false) }
    }

    func releaseAll() {
        if dragging { emit(dragButton == .right ? .rightMouseUp : .leftMouseUp, lastPoint, dragButton); dragging = false }
        for code in heldKeys { CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap) }
        heldKeys.removeAll()
    }
}
