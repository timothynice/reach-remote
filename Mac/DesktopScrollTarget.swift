import Foundation
import ApplicationServices
import CoreGraphics

/// Click-triggered AX probes are debounced, serial, and bounded. Pointer movement invalidates
/// the result because CG scroll events follow the current Mac pointer rather than AX focus.
@MainActor
final class DesktopScrollTarget {
    var onState: ((ScrollTargetState) -> Void)?
    private let queue = DispatchQueue(label: "reach.scroll-target", qos: .userInitiated)
    private var epoch = UUID()
    private var delay: Task<Void, Never>?
    private var running = false
    private var pending: (CGPoint, UUID)?
    private var hasSelection = false
    private var state = ScrollTargetState.unknown

    func reset() {
        cancel()
        onState?(.unknown)
    }

    func cancel() {
        epoch = UUID()
        delay?.cancel()
        delay = nil
        pending = nil
        hasSelection = false
        state = .unknown
    }

    func pointerMoved(x: Double, y: Double, display: CGRect) {
        guard hasSelection, let point = screenPoint(x: x, y: y, display: display) else { return }
        // Preserve a confirmed negative while the pointer travels across non-scrollable chrome.
        // Recheck only after movement settles; custom/unsupported content falls back to unknown.
        if state != .notScrollable { publish(.unknown) }
        schedule(point, settleNanoseconds: 200_000_000)
    }

    func clicked(x: Double, y: Double, display: CGRect) {
        guard let point = screenPoint(x: x, y: y, display: display) else { return }
        hasSelection = true
        publish(.unknown)
        schedule(point, settleNanoseconds: 80_000_000)
    }

    private func screenPoint(x: Double, y: Double, display: CGRect) -> CGPoint? {
        guard x.isFinite, y.isFinite, display.width > 0, display.height > 0 else { return nil }
        return CGPoint(x: display.minX + min(1, max(0, x)) * display.width,
                       y: display.minY + min(1, max(0, y)) * display.height)
    }

    private func schedule(_ point: CGPoint, settleNanoseconds: UInt64) {
        epoch = UUID()
        let generation = epoch
        delay?.cancel()
        pending = nil
        delay = Task { [weak self] in
            try? await Task.sleep(nanoseconds: settleNanoseconds)
            guard !Task.isCancelled, let self, self.epoch == generation else { return }
            self.enqueue(point, generation: generation)
        }
    }

    private func enqueue(_ point: CGPoint, generation: UUID) {
        guard !running else { pending = (point, generation); return }
        running = true
        queue.async { [weak self] in
            let result = ScrollTargetReader.read(at: point)
            Task { @MainActor in
                guard let self else { return }
                self.running = false
                if self.epoch == generation && self.hasSelection { self.publish(result) }
                if let (point, generation) = self.pending {
                    self.pending = nil
                    if self.epoch == generation { self.enqueue(point, generation: generation) }
                }
            }
        }
    }

    private func publish(_ value: ScrollTargetState) {
        guard value != state else { return }
        state = value
        onState?(value)
    }
}

/// Kept separate from AX so conservative classification can be tested without permissions.
struct ScrollTargetEvidence {
    var confirmedVerticalOverflow = false
    var uncertainContainer = false
    var incompleteAncestry = false
    var reachedWindowOrRoot = false
    var state: ScrollTargetState {
        if confirmedVerticalOverflow { return .scrollable }
        if reachedWindowOrRoot && !uncertainContainer && !incompleteAncestry { return .notScrollable }
        return .unknown
    }
}

private enum ScrollTargetReader {
    static func read(at point: CGPoint) -> ScrollTargetState {
        guard AXIsProcessTrusted() else { return .unknown }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.012)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return .unknown }
        var current = hit
        var evidence = ScrollTargetEvidence()
        var visited: [AXUIElement] = []
        for _ in 0..<12 {
            guard remaining(deadline) > 0 else { evidence.incompleteAncestry = true; break }
            if visited.contains(where: { CFEqual($0, current) }) { evidence.incompleteAncestry = true; break }
            visited.append(current)
            AXUIElementSetMessagingTimeout(current, min(0.012, remaining(deadline)))
            let keys = [kAXRoleAttribute, kAXParentAttribute, kAXVerticalScrollBarAttribute,
                        kAXEnabledAttribute, kAXSizeAttribute, kAXContentsAttribute, kAXOrientationAttribute]
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(current, keys as CFArray, [], &raw) == .success,
                  let values = raw as? [Any], values.count == keys.count,
                  let role = values[0] as? String else { evidence.incompleteAncestry = true; break }
            if role == "AXWebArea" || role == kAXUnknownRole || role == "AXCanvas" {
                evidence.uncertainContainer = true
            }
            if let bar = element(values[2]) {
                guard remaining(deadline) > 0 else { evidence.incompleteAncestry = true; break }
                AXUIElementSetMessagingTimeout(bar, min(0.012, remaining(deadline)))
                var enabled: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(bar, kAXEnabledAttribute as CFString, &enabled)
                if status == .success, (enabled as? Bool) == true { return .scrollable }
                if status != .success { evidence.uncertainContainer = true }
            }
            if role == kAXScrollBarRole,
               values[6] as? String == kAXVerticalOrientationValue, values[3] as? Bool == true { return .scrollable }
            if role == kAXScrollAreaRole {
                let viewport = size(values[4])
                let contents = elements(values[5])
                var measuredContents = false
                if let viewport, viewport.height > 0 {
                    for content in contents.prefix(4) {
                        guard remaining(deadline) > 0 else { evidence.incompleteAncestry = true; break }
                        AXUIElementSetMessagingTimeout(content, min(0.012, remaining(deadline)))
                        var rawSize: CFTypeRef?
                        if AXUIElementCopyAttributeValue(content, kAXSizeAttribute as CFString, &rawSize) == .success,
                           let rawSize, let dimensions = size(rawSize) {
                            measuredContents = true
                            if dimensions.height > viewport.height + 2 { return .scrollable }
                        }
                    }
                }
                // A custom scroll container without measurable overflow cannot support a firm negative.
                if !measuredContents { evidence.uncertainContainer = true }
            }
            if [kAXWindowRole, kAXApplicationRole, kAXSystemWideRole].contains(role) {
                evidence.reachedWindowOrRoot = true
                break
            }
            guard let parent = element(values[1]) else { evidence.incompleteAncestry = true; break }
            current = parent
        }
        return evidence.state
    }

    private static func remaining(_ deadline: TimeInterval) -> Float {
        Float(max(0, deadline - ProcessInfo.processInfo.systemUptime))
    }
    private static func element(_ value: Any) -> AXUIElement? {
        let object = value as CFTypeRef
        guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        return (object as! AXUIElement)
    }
    private static func elements(_ value: Any) -> [AXUIElement] {
        if let list = value as? [Any] { return list.compactMap(element) }
        return element(value).map { [$0] } ?? []
    }
    private static func size(_ value: Any) -> CGSize? {
        let object = value as CFTypeRef
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        let ax = object as! AXValue
        guard AXValueGetType(ax) == .cgSize else { return nil }
        var result = CGSize.zero
        guard AXValueGetValue(ax, .cgSize, &result), result.width.isFinite, result.height.isFinite else { return nil }
        return result
    }
}
