import SwiftUI
import UIKit
import AVFoundation
// Older SDKs omit Sendable annotations for immutable CIImage and thread-safe CIContext.
@preconcurrency import CoreImage

final class VideoSurface: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    override init(frame: CGRect) { super.init(frame: frame); displayLayer.videoGravity = .resizeAspect; backgroundColor = .black }
    required init?(coder: NSCoder) { fatalError() }
}

enum ViewportMode { case focus, fit, width, height }

final class DesktopScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pinchGestureRecognizer && gestureRecognizer.numberOfTouches != 2 { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

struct DesktopViewport: UIViewRepresentable {
    let model: PhoneSession
    var precision: Bool
    var mode: ViewportMode
    var resetID: Int
    var bottomOcclusion: CGFloat
    var topOcclusion: CGFloat
    var browserActive: Bool
    var onOpenDisplayBrowser: () -> Void
    var onManualZoom: () -> Void
    var onInteraction: () -> Void
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = DesktopScrollView()
        scroll.backgroundColor = .black
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 0.1; scroll.maximumZoomScale = 6
        scroll.bouncesZoom = true; scroll.showsHorizontalScrollIndicator = true; scroll.showsVerticalScrollIndicator = true
        scroll.indicatorStyle = .white
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.addSubview(context.coordinator.surface)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:))); double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:))); hold.minimumPressDuration = 0.35; hold.allowableMovement = 30; hold.numberOfTouchesRequired = 1
        let browserTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.openBrowser(_:)))
        browserTap.numberOfTouchesRequired = 3
        tap.require(toFail: browserTap); double.require(toFail: browserTap)
        let precisionPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.precisionPan(_:))); precisionPan.maximumNumberOfTouches = 1
        precisionPan.isEnabled = precision
        scroll.panGestureRecognizer.maximumNumberOfTouches = 2
        scroll.panGestureRecognizer.require(toFail: hold)
        [tap, double, hold, precisionPan, browserTap].forEach { scroll.addGestureRecognizer($0) }
        context.coordinator.observeKeyboard()
        context.coordinator.scroll = scroll
        context.coordinator.precisionGesture = precisionPan
        model.decoder.onFrame = { [weak coordinator = context.coordinator] sample in
            guard let coordinator else { return }
            if coordinator.surface.displayLayer.status == .failed { coordinator.surface.displayLayer.flush() }
            guard coordinator.parent.model.acceptsFrames else { return }
            coordinator.surface.displayLayer.enqueue(sample)
            coordinator.cachePreview(sample)
            coordinator.parent.model.didPresentFrame()
        }
        scroll.onLayout = { [weak coordinator = context.coordinator] in coordinator?.configure() }
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.precisionGesture?.isEnabled = precision
        scroll.panGestureRecognizer.minimumNumberOfTouches = precision ? 2 : 1
        scroll.panGestureRecognizer.maximumNumberOfTouches = 2
        coordinator.configure()
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: DesktopViewport
        let surface = VideoSurface()
        weak var scroll: UIScrollView?
        weak var precisionGesture: UIPanGestureRecognizer?
        var placements: [UInt32: ViewportPlacement] = [:]
        var displayedID: UInt32?
        let previewContext = CIContext(options: [.cacheIntermediates: false])
        let previewQueue = DispatchQueue(label: "reach.previews", qos: .utility)
        var lastPreview: TimeInterval = 0
        var previewBusy = false
        var remoteSize = CGSize.zero
        var previousBounds = CGSize.zero
        var previousMode: ViewportMode?
        var previousReset = -1
        var cursor = CGPoint(x: 0.5, y: 0.5)
        var holdStart = CGPoint.zero
        var previousHoldLocation = CGPoint.zero
        var dragging = false
        var keyboardFrame: CGRect?
        var keyboardAnimationDeadline: TimeInterval = 0
        var configuring = false
        var lastFocusRevision = -1
        var lastSafe = CGRect.null
        var lastKeyboardPresented = false
        var manualInteractionUntil: TimeInterval = 0
        init(_ parent: DesktopViewport) { self.parent = parent }
        func observeKeyboard() {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        }
        @objc func keyboardChanged(_ notification: Notification) {
            keyboardFrame = notification.name == UIResponder.keyboardWillHideNotification ? nil : (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            keyboardAnimationDeadline = Date.timeIntervalSinceReferenceDate + duration
            // SwiftUI may resize its safe area in the same update; intersect the final UIKit bounds.
            DispatchQueue.main.async { [weak self] in self?.configure() }
        }
        func configure() {
            guard !configuring, let scroll else { return }
            let nextID = parent.model.selectedDisplay
            let changingDisplay = displayedID != nextID
            if changingDisplay { savePlacement() }
            guard !parent.model.isSwitchingDisplay else { return }
            let size = parent.model.desktopSize
            guard size.width > 0, size.height > 0, scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
            configuring = true
            defer { configuring = false }
            let reset = changingDisplay || remoteSize != size || previousMode != parent.mode || previousReset != parent.resetID
            let resized = previousBounds != scroll.bounds.size
            if reset || resized {
                let restored = changingDisplay ? nextID.flatMap { placements[$0] } : nil
                let oldZoom = scroll.zoomScale
                let oldOffset = scroll.contentOffset
                if changingDisplay { lastPreview = 0; surface.displayLayer.flushAndRemoveImage() }
                displayedID = nextID
                remoteSize = size; previousBounds = scroll.bounds.size; previousMode = parent.mode; previousReset = parent.resetID
                let widthScale = scroll.bounds.width / size.width
                let heightScale = scroll.bounds.height / size.height
                let fit = min(widthScale, heightScale)
                if reset {
                    scroll.zoomScale = 1
                    surface.frame = CGRect(origin: .zero, size: size)
                    scroll.contentSize = size
                }
                scroll.minimumZoomScale = fit
                scroll.maximumZoomScale = max(4, fit * 8)
                let zoom: CGFloat
                if reset {
                    switch parent.mode { case .focus: zoom = max(widthScale, heightScale); case .fit: zoom = fit; case .width: zoom = widthScale; case .height: zoom = heightScale }
                } else { zoom = min(scroll.maximumZoomScale, max(fit, oldZoom)) }
                scroll.setZoomScale(min(scroll.maximumZoomScale, max(fit, restored?.zoom ?? zoom)), animated: false)
                center()
                if let restored {
                    scroll.contentOffset = clampedOffset(restored.offset(viewport: scroll.bounds.size, desktop: size, zoom: scroll.zoomScale))
                } else if reset { scroll.contentOffset = CGPoint(x: max(0, (scroll.contentSize.width - scroll.bounds.width) / 2), y: -scroll.contentInset.top) }
                else { scroll.contentOffset = clampedOffset(oldOffset) }
            } else { center() }
            followTypingFocus(force: reset || resized)
        }
        func savePlacement() {
            guard let scroll, let displayedID, remoteSize.width > 0, remoteSize.height > 0 else { return }
            placements[displayedID] = ViewportPlacement(zoom: scroll.zoomScale, offset: scroll.contentOffset, viewport: scroll.bounds.size, desktop: remoteSize)
        }
        func cachePreview(_ sample: CMSampleBuffer) {
            let now = Date.timeIntervalSinceReferenceDate
            guard !previewBusy, now - lastPreview > (parent.browserActive ? 0.25 : 2),
                  let id = parent.model.selectedDisplay, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
            lastPreview = now; previewBusy = true
            let model = parent.model
            // CIImage is immutable and retains the decoded buffer for this asynchronous render.
            let image = CIImage(cvPixelBuffer: buffer)
            // Read the actor-owned reference here. CIContext supports concurrent rendering;
            // this worker uses its own serial queue and never accesses UIKit state.
            let context = previewContext
            previewQueue.async { [weak self] in
                let scale = min(1, 720 / max(image.extent.width, image.extent.height))
                let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let cg = context.createCGImage(scaled, from: scaled.extent)
                DispatchQueue.main.async { [weak self] in
                    self?.previewBusy = false
                    if let cg { model.storePreview(UIImage(cgImage: cg), for: id) }
                }
            }
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { surface }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            center()
            if scrollView.pinchGestureRecognizer?.state == .changed {
                manualInteractionUntil = Date.timeIntervalSinceReferenceDate + 0.4
                parent.onManualZoom()
            }
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { manualInteractionUntil = Date.timeIntervalSinceReferenceDate + 0.4 }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if scrollView.isDragging || scrollView.isDecelerating { manualInteractionUntil = Date.timeIntervalSinceReferenceDate + 0.4 }
        }
        func keyboardVisibleHeight() -> CGFloat {
            guard let scroll, let window = scroll.window, let keyboardFrame else { return scroll?.bounds.height ?? 0 }
            let inWindow = window.convert(keyboardFrame, from: nil)
            let inScroll = scroll.convert(inWindow, from: window)
            return ViewportGeometry.unobscuredHeight(viewport: scroll.bounds, keyboard: inScroll)
        }
        func center() {
            guard let scroll else { return }
            let typing = parent.model.keyboardPresented
            let overlap = typing ? max(0, scroll.bounds.height - keyboardVisibleHeight()) : 0
            let top = max(max(0, (scroll.bounds.height - scroll.contentSize.height) / 2), typing ? parent.topOcclusion + 12 : 0)
            let inset = UIEdgeInsets(top: top, left: max(0, (scroll.bounds.width - scroll.contentSize.width) / 2), bottom: typing ? overlap + parent.bottomOcclusion + 16 : 0, right: 0)
            if scroll.contentInset != inset { scroll.contentInset = inset }
        }
        func clampedOffset(_ point: CGPoint) -> CGPoint {
            guard let scroll else { return point }
            return CGPoint(x: min(max(-scroll.contentInset.left, point.x), max(-scroll.contentInset.left, scroll.contentSize.width - scroll.bounds.width + scroll.contentInset.right)),
                           y: min(max(-scroll.contentInset.top, point.y), max(-scroll.contentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.contentInset.bottom)))
        }
        func followTypingFocus(force: Bool = false) {
            guard let scroll else { return }
            let typing = parent.model.keyboardPresented
            let available = keyboardVisibleHeight()
            let safe = CGRect(x: 18, y: parent.topOcclusion + 10, width: max(1, scroll.bounds.width - 36), height: max(1, available - parent.topOcclusion - parent.bottomOcclusion - 26))
            let changed = force || lastFocusRevision != parent.model.focusRevision || safe != lastSafe || typing != lastKeyboardPresented
            lastFocusRevision = parent.model.focusRevision; lastSafe = safe; lastKeyboardPresented = typing
            guard typing, changed, !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating, !dragging,
                  Date.timeIntervalSinceReferenceDate >= manualInteractionUntil,
                  scroll.pinchGestureRecognizer?.state != .began, scroll.pinchGestureRecognizer?.state != .changed else { return }
            func convert(_ rect: RemoteRect) -> CGRect {
                surface.convert(CGRect(x: rect.x * surface.bounds.width, y: rect.y * surface.bounds.height, width: rect.width * surface.bounds.width, height: rect.height * surface.bounds.height), to: scroll)
            }
            let fallback = parent.model.lastInteractionPoint.map { surface.convert(CGPoint(x: $0.x * surface.bounds.width, y: $0.y * surface.bounds.height), to: scroll) }
            let field: CGRect
            let caret: CGRect?
            if let focus = parent.model.remoteFocus, focus.isValid { field = convert(focus.field); caret = focus.caret.map(convert) }
            else if let fallback { field = CGRect(x: fallback.x - 18, y: fallback.y - 18, width: 36, height: 36); caret = nil }
            else { return }
            let minimum = CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top)
            let maximum = CGPoint(x: max(minimum.x, scroll.contentSize.width - scroll.bounds.width + scroll.contentInset.right), y: max(minimum.y, scroll.contentSize.height - scroll.bounds.height + scroll.contentInset.bottom))
            let target = ViewportGeometry.offsetForFocus(field: field, caret: caret, fallback: fallback, current: scroll.contentOffset, safe: safe, minimum: minimum, maximum: maximum)
            guard hypot(target.x - scroll.contentOffset.x, target.y - scroll.contentOffset.y) > 0.75 else { return }
            let remaining = keyboardAnimationDeadline - Date.timeIntervalSinceReferenceDate
            if remaining > 0.02 {
                UIView.animate(withDuration: min(0.3, remaining), delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]) { scroll.contentOffset = target }
            } else { scroll.setContentOffset(target, animated: false) }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        func point(_ gesture: UIGestureRecognizer) -> CGPoint {
            if parent.precision { return cursor }
            let location = gesture.location(in: surface)
            return CGPoint(x: min(1, max(0, location.x / max(1, surface.bounds.width))), y: min(1, max(0, location.y / max(1, surface.bounds.height))))
        }
        func send(_ kind: String, at point: CGPoint) { parent.model.send(RemoteInput(kind: kind, x: point.x, y: point.y)) }
        func keepCursorVisible() {
            guard parent.precision, let scroll else { return }
            // UIKit applies the current zoom transform when converting into scroll-content coordinates.
            let point = surface.convert(CGPoint(x: cursor.x * surface.bounds.width, y: cursor.y * surface.bounds.height), to: scroll)
            let target: CGPoint
            if parent.model.keyboardPresented {
                let safe = CGRect(x: 24, y: parent.topOcclusion + 10, width: max(1, scroll.bounds.width - 48), height: max(1, keyboardVisibleHeight() - parent.topOcclusion - parent.bottomOcclusion - 26))
                let minimum = CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top)
                let maximum = CGPoint(x: max(minimum.x, scroll.contentSize.width - scroll.bounds.width + scroll.contentInset.right), y: max(minimum.y, scroll.contentSize.height - scroll.bounds.height + scroll.contentInset.bottom))
                target = ViewportGeometry.offsetForFocus(field: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24), caret: nil, fallback: nil, current: scroll.contentOffset, safe: safe, minimum: minimum, maximum: maximum)
            } else {
                target = ViewportGeometry.offsetKeepingVisible(point, current: scroll.contentOffset, viewport: scroll.bounds.size, content: scroll.contentSize, minimum: CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top))
            }
            if hypot(target.x - scroll.contentOffset.x, target.y - scroll.contentOffset.y) > 0.25 {
                // Match each input update directly. Queued scroll animations would trail behind the finger.
                scroll.setContentOffset(target, animated: false)
            }
        }
        @objc func tap(_ gesture: UITapGestureRecognizer) { parent.onInteraction(); send("click", at: point(gesture)) }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            parent.onInteraction(); parent.onManualZoom()
            guard let scroll else { return }
            if scroll.zoomScale > scroll.minimumZoomScale * 1.2 { scroll.setZoomScale(scroll.minimumZoomScale, animated: true) }
            else {
                let scale = min(scroll.maximumZoomScale, scroll.minimumZoomScale * 3)
                let location = gesture.location(in: surface)
                scroll.zoom(to: CGRect(x: location.x - scroll.bounds.width / scale / 2, y: location.y - scroll.bounds.height / scale / 2, width: scroll.bounds.width / scale, height: scroll.bounds.height / scale), animated: true)
            }
        }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            parent.onInteraction()
            var current = point(gesture)
            switch gesture.state {
            case .began: holdStart = current; previousHoldLocation = gesture.location(in: scroll?.superview); dragging = false
            case .changed:
                if parent.precision {
                    let location = gesture.location(in: scroll?.superview)
                    cursor.x = min(1, max(0, cursor.x + (location.x - previousHoldLocation.x) / max(1, remoteSize.width) * 2))
                    cursor.y = min(1, max(0, cursor.y + (location.y - previousHoldLocation.y) / max(1, remoteSize.height) * 2))
                    previousHoldLocation = location; current = cursor
                }
                if !dragging && hypot(current.x - holdStart.x, current.y - holdStart.y) > 0.006 { dragging = true; send("down", at: holdStart) }
                if dragging { send("move", at: current); keepCursorVisible() }
            case .ended:
                send(dragging ? "up" : "rightClick", at: current); dragging = false
            case .cancelled, .failed:
                if dragging { send("up", at: current) }; dragging = false
            default: break
            }
        }
        @objc func openBrowser(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            savePlacement()
            parent.onOpenDisplayBrowser()
        }
        @objc func precisionPan(_ gesture: UIPanGestureRecognizer) {
            parent.onInteraction()
            let delta = gesture.translation(in: scroll)
            cursor.x = min(1, max(0, cursor.x + delta.x / max(1, remoteSize.width) * 2))
            cursor.y = min(1, max(0, cursor.y + delta.y / max(1, remoteSize.height) * 2))
            send("move", at: cursor)
            keepCursorVisible()
            gesture.setTranslation(.zero, in: scroll)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
        }
    }
}
