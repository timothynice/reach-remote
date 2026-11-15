import Foundation
import ApplicationServices
import CoreGraphics

/// Only one bounded worker read can be outstanding; AX XPC never blocks input or video delivery.
@MainActor
final class DesktopFocusTracker {
    var onFocus: ((RemoteFocus) -> Void)?
    var onGeometryAvailable: ((Bool) -> Void)?
    private var reportedGeometry = false
    private var reportedCaret = false
    private var display = CGRect.zero
    private var timer: Timer?
    private var lastFocus: RemoteFocus?
    private var epoch = UUID()
    private var polling = false
    private let queue = DispatchQueue(label: "reach.focus", qos: .userInitiated)
    private(set) var enabled = false

    func setDisplay(_ frame: CGRect) {
        display = frame
        epoch = UUID()
        lastFocus = nil
        if enabled { poll(force: true) }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        reportedGeometry = false
        reportedCaret = false
        epoch = UUID()
        timer?.invalidate()
        timer = nil
        lastFocus = nil
        guard value else { return }
        poll(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func poll(force: Bool = false) {
        guard enabled, !polling, !display.isEmpty else { return }
        polling = true
        let generation = epoch
        let bounds = display
        queue.async { [weak self] in
            let focus = FocusReader.read(within: bounds)
            Task { @MainActor in
                guard let self else { return }
                self.polling = false
                guard self.enabled else { return }
                guard self.epoch == generation else { self.poll(force: true); return }
                guard let focus else { self.lastFocus = nil; return }
                let hasCaret = focus.caret != nil
                if !self.reportedGeometry || (hasCaret && !self.reportedCaret) {
                    self.reportedGeometry = true
                    self.reportedCaret = self.reportedCaret || hasCaret
                    self.onGeometryAvailable?(hasCaret)
                }
                if force || FocusGeometry.differs(focus, from: self.lastFocus, display: bounds) {
                    self.lastFocus = focus
                    self.onFocus?(focus)
                }
            }
        }
    }
}

/// Geometry only: never requests AXValue, selected text, or document text.
private enum FocusReader {
    static func read(within display: CGRect) -> RemoteFocus? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let element = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.05)
        guard let role = attribute(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              let position = point(attribute(element, kAXPositionAttribute)),
              let dimensions = size(attribute(element, kAXSizeAttribute)) else { return nil }
        let fieldBounds = CGRect(origin: position, size: dimensions)
        guard let normalizedField = FocusGeometry.normalize(fieldBounds, within: display) else { return nil }
        var normalizedCaret: RemoteRect?
        if let selection = range(attribute(element, kAXSelectedTextRangeAttribute)),
           selection.location >= 0, selection.length >= 0,
           selection.location <= Int.max - selection.length {
            // A zero-length range at the selection end asks for the insertion point, never text.
            var insertion = CFRange(location: selection.location + selection.length, length: 0)
            if let value = AXValueCreate(.cfRange, &insertion) {
                var bounds: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &bounds) == .success,
                   let rect = rect(bounds) {
                    normalizedCaret = FocusGeometry.normalizeCaret(rect, field: fieldBounds, display: display)
                }
            }
        }
        return RemoteFocus(field: normalizedField, caret: normalizedCaret)
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
    private static func axValue(_ object: CFTypeRef?, type: AXValueType) -> AXValue? {
        guard let object, CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        let value = object as! AXValue
        return AXValueGetType(value) == type ? value : nil
    }
    private static func point(_ object: CFTypeRef?) -> CGPoint? {
        guard let value = axValue(object, type: .cgPoint) else { return nil }
        var result = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &result) ? result : nil
    }
    private static func size(_ object: CFTypeRef?) -> CGSize? {
        guard let value = axValue(object, type: .cgSize) else { return nil }
        var result = CGSize.zero
        return AXValueGetValue(value, .cgSize, &result) ? result : nil
    }
    private static func rect(_ object: CFTypeRef?) -> CGRect? {
        guard let value = axValue(object, type: .cgRect) else { return nil }
        var result = CGRect.zero
        return AXValueGetValue(value, .cgRect, &result) ? result : nil
    }
    private static func range(_ object: CFTypeRef?) -> CFRange? {
        guard let value = axValue(object, type: .cfRange) else { return nil }
        var result = CFRange()
        return AXValueGetValue(value, .cfRange, &result) ? result : nil
    }
}

/// CGDisplayBounds and Accessibility geometry use the main display's top-left global origin.
enum FocusGeometry {
    static func normalize(_ bounds: CGRect, within display: CGRect) -> RemoteRect? {
        guard finite(bounds), finite(display), bounds.width > 0, bounds.height > 0,
              display.width > 0, display.height > 0 else { return nil }
        let intersection = bounds.intersection(display)
        guard !intersection.isNull, !intersection.isEmpty else { return nil }
        return RemoteRect(x: (intersection.minX - display.minX) / display.width,
                          y: (intersection.minY - display.minY) / display.height,
                          width: intersection.width / display.width, height: intersection.height / display.height)
    }

    static func normalizeCaret(_ caret: CGRect, field: CGRect, display: CGRect) -> RemoteRect? {
        guard finite(caret), finite(field), caret.height > 0, field.width > 0, field.height > 0 else { return nil }
        var insertion = caret
        insertion.size.width = max(1, caret.width)
        // Some AX providers report a zero-width insertion point at the field's right boundary.
        // Keep its one-pixel line inside the field while preserving the text line height.
        insertion.origin.x = min(max(caret.minX, field.minX), max(field.minX, field.maxX - insertion.width))
        return normalize(insertion.intersection(field), within: display)
    }

    static func differs(_ focus: RemoteFocus, from previous: RemoteFocus?, display: CGRect) -> Bool {
        guard let previous else { return true }
        func changed(_ a: RemoteRect, _ b: RemoteRect) -> Bool {
            abs(a.x - b.x) * display.width > 2 || abs(a.y - b.y) * display.height > 2 ||
            abs(a.width - b.width) * display.width > 2 || abs(a.height - b.height) * display.height > 2
        }
        if changed(focus.field, previous.field) { return true }
        switch (focus.caret, previous.caret) {
        case (.none, .none): return false
        case let (.some(a), .some(b)): return changed(a, b)
        default: return true
        }
    }
    private static func finite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
    }
}
