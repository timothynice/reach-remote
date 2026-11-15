import SwiftUI
import UIKit

/// A quiet, self-contained loading field. Only the dots redraw; the screen layout stays still.
struct ReachLoadingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let time: TimeInterval = reduceMotion ? 2.0 : timeline.date.timeIntervalSinceReferenceDate
                drawReachLoadingDots(context: &context, size: size, time: time, accent: ReachHomeStyle.cyan)
            }
        }
        .frame(width: 188, height: 100).accessibilityHidden(true)
    }
}

/// Explicit scalar types keep this renderer inexpensive for older Swift compilers to type-check.
private func drawReachLoadingDots(context: inout GraphicsContext, size: CGSize, time: TimeInterval, accent: Color) {
    let columns: Int = 13
    let rows: Int = 7
    let spacing: CGFloat = min(size.width / CGFloat(columns - 1), size.height / CGFloat(rows - 1))
    let originX: CGFloat = (size.width - CGFloat(columns - 1) * spacing) / 2
    let originY: CGFloat = (size.height - CGFloat(rows - 1) * spacing) / 2
    let headX: Double = (sin(time * 0.56) * 0.5 + 0.5) * Double(columns - 1)
    let headY: Double = (cos(time * 0.79) * 0.5 + 0.5) * Double(rows - 1)
    for row in 0..<rows {
        for column in 0..<columns {
            let distance: Double = hypot(Double(column) - headX, Double(row) - headY)
            let light: Double = exp(-distance * distance / 5.4)
            let wavePhase: Double = Double(column) * 0.57 - Double(row) * 0.42 + time * 1.1
            let wave: Double = (sin(wavePhase) + 1) / 2
            let opacity: Double = 0.09 + light * 0.65 + wave * 0.10
            let diameter: CGFloat = CGFloat(1.7 + light * 1.0)
            let pointX: CGFloat = originX + CGFloat(column) * spacing
            let pointY: CGFloat = originY + CGFloat(row) * spacing
            let rect = CGRect(x: pointX - diameter / 2, y: pointY - diameter / 2, width: diameter, height: diameter)
            let color: Color = light > 0.25 ? accent : .white
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))
        }
    }
}

struct ReachConnectionLoading: View {
    var title: String
    var failed: Bool
    var detail: String?
    var retry: () -> Void
    var disconnect: () -> Void
    var body: some View {
        VStack(spacing: 22) {
            ReachLoadingDots().padding(.bottom, 4)
            Text(failed ? "Taking a little longer" : title)
                .font(.subheadline).foregroundStyle(.white.opacity(0.8))
            if failed {
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.48))
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 18) {
                    Button("Retry", action: retry).buttonStyle(.bordered).tint(.white)
                    Button("Disconnect", action: disconnect).font(.subheadline).foregroundStyle(.white.opacity(0.65))
                }.padding(.top, 2)
            }
        }
        .padding(32).frame(maxWidth: 340)
        .animation(.easeInOut(duration: 0.2), value: failed)
    }
}

struct DisplayBrowserOverlay: View {
    @ObservedObject var model: PhoneSession
    var dismiss: () -> Void
    @State private var page: UInt32?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                if model.orderedDisplays.isEmpty {
                    VStack(spacing: 22) {
                        ReachLoadingDots()
                        Text("Finding your displays").font(.subheadline).foregroundStyle(.white.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { DisplayBrowserTapLayer(dismiss: dismiss) }
                } else {
                    VStack(spacing: 0) {
                        TabView(selection: $page) {
                            ForEach(model.orderedDisplays) { display in
                                ZStack {
                                    if let preview = model.displayPreviews[display.id] {
                                        Image(uiImage: preview).resizable().scaledToFit()
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    } else {
                                        ReachLoadingDots()
                                    }
                                }
                                .frame(width: geometry.size.width)
                                .frame(maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .overlay { DisplayBrowserTapLayer(dismiss: dismiss) }
                                .tag(Optional(display.id))
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .padding(.top, max(16, geometry.safeAreaInsets.top))
                        VStack(spacing: 18) {
                            Text(model.orderedDisplays.first(where: { $0.id == page })?.name ?? "Display")
                                .font(.subheadline).foregroundStyle(.white.opacity(0.72))
                                .multilineTextAlignment(.center).lineLimit(2)
                                .frame(minHeight: 44)
                                .accessibilityLabel("\(model.orderedDisplays.first(where: { $0.id == page })?.name ?? "Display"), display \(selectedPageIndex + 1) of \(model.orderedDisplays.count)")
                                .accessibilityHint("Swipe up or down to change display. Double-tap to enter.")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { dismiss() }
                                .accessibilityAdjustableAction { direction in
                                    switch direction {
                                    case .increment: movePage(by: 1)
                                    case .decrement: movePage(by: -1)
                                    @unknown default: break
                                    }
                                }
                            pageDots
                            Text("Swipe to browse · tap to enter")
                                .font(.caption2).foregroundStyle(.white.opacity(0.35))
                        }
                        .padding(.horizontal, 24).padding(.top, 16)
                        .padding(.bottom, max(22, geometry.safeAreaInsets.bottom))
                        .frame(maxWidth: .infinity)
                        .overlay { DisplayBrowserTapLayer(dismiss: dismiss) }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { page = model.selectedDisplay ?? model.orderedDisplays.first?.id }
        .onChange(of: page) { _, selected in
            guard let selected, let display = model.orderedDisplays.first(where: { $0.id == selected }) else { return }
            model.select(display)
        }
        .onChange(of: model.selectedDisplay) { _, selected in
            if page == nil { page = selected }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Display browser")
        .accessibilityAction(named: "Enter selected display", dismiss)
    }
    private var selectedPageIndex: Int { model.orderedDisplays.firstIndex(where: { $0.id == page }) ?? 0 }
    private func movePage(by delta: Int) {
        let displays = model.orderedDisplays
        guard !displays.isEmpty else { return }
        page = displays[min(displays.count - 1, max(0, selectedPageIndex + delta))].id
    }
    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(model.orderedDisplays) { display in
                Circle().fill(display.id == page ? ReachHomeStyle.cyan : .white.opacity(0.23))
                    .frame(width: 5, height: 5)
            }
        }
        .frame(height: 8).accessibilityHidden(true)
    }
}

/// Tap recognizers are local to this overlay: no exit gesture reaches the remote Mac.
/// Parent paging pans can still recognize, while stationary taps with any of 1–3 fingers enter.
private struct DisplayBrowserTapLayer: UIViewRepresentable {
    var dismiss: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(dismiss) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        for fingers in 1...3 {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
            tap.numberOfTouchesRequired = fingers
            tap.cancelsTouchesInView = true
            tap.delegate = context.coordinator
            view.addGestureRecognizer(tap)
        }
        view.isAccessibilityElement = false
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.dismiss = dismiss }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var dismiss: () -> Void
        init(_ dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        @objc func tapped(_ gesture: UITapGestureRecognizer) { if gesture.state == .ended { dismiss() } }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }
}

/// Spring-centered speed control, rather than an absolute document-position scrollbar.
struct RemoteScrollRail: View {
    var scroll: (Double) -> Void
    var active: (Bool) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var touching = false
    @State private var dragging = false
    @State private var velocity = 0.0
    @State private var accumulator = ScrollRailAccumulator()
    @State private var displacement: CGFloat = 0
    var body: some View {
        GeometryReader { geometry in
            let travel = max(24, geometry.size.height / 2 - 62)
            ZStack {
                Capsule().fill(.ultraThinMaterial).frame(width: 38)
                    .overlay { Capsule().strokeBorder(.white.opacity(dragging ? 0.24 : 0.13), lineWidth: 0.7) }
                VStack {
                    Image(systemName: "chevron.up")
                    Spacer()
                    Image(systemName: "chevron.down")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(dragging ? 0.8 : 0.5)).padding(.vertical, 17)
                Capsule().fill(.white.opacity(0.15)).frame(width: 22, height: 1)
                Capsule().fill(dragging ? ReachHomeStyle.cyan : .white.opacity(0.78))
                    .frame(width: 12, height: 54).offset(y: displacement)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { value in
                    if !dragging { dragging = true; active(true) }
                    displacement = min(travel, max(-travel, value.location.y - geometry.size.height / 2))
                    velocity = ScrollRailDynamics.velocity(displacement: Double(displacement), travel: Double(travel))
                }
                .onEnded { _ in stop() })
        }
        .task(id: dragging && scenePhase == .active) {
            guard dragging, scenePhase == .active else { return }
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                guard dragging, touching, scenePhase == .active else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let delta = accumulator.step(velocity: velocity, elapsed: now - previous)
                previous = now
                if delta != 0 { scroll(delta) }
            }
        }
        .onChange(of: touching) { _, held in if !held { stop() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
        .onDisappear { stop() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scroll Mac window")
        .accessibilityHint("Drag the thumb up or down and hold. Farther from the center scrolls faster. Release to stop.")
        .accessibilityAdjustableAction { direction in
            active(true)
            switch direction { case .increment: scroll(240); case .decrement: scroll(-240); @unknown default: break }
            active(false)
        }
    }
    private func stop() {
        guard dragging else { return }
        dragging = false; velocity = 0; accumulator.reset()
        withAnimation(.easeOut(duration: 0.18)) { displacement = 0 }
        active(false)
    }
}
