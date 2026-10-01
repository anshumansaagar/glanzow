import AppKit
import QuartzCore

/// Full-screen dot overlays for calibration (FR-CAL-01, 02) and validation (FR-CAL-05).
@MainActor public final class CalibrationOverlay {
    public struct Outcome {
        public var models: [DisplayModel]
        /// Displays where the face was seen too rarely to fit a model.
        public var failed: [DisplayInfo]
    }

    private let source: PoseSource
    private var windows: [DisplayKey: OverlayWindow] = [:]
    private var cancelled = false
    private var samples: [PoseSample] = []
    private var collector: Task<Void, Never>?

    public init(source: PoseSource) { self.source = source }

    // MARK: Calibration

    /// Runs the dot path on each target display in turn. Nil if the user pressed Escape.
    public func calibrate(_ targets: [DisplayInfo], among all: [DisplayInfo], cameraID: String) async -> Outcome? {
        open(all)
        var outcome = Outcome(models: [], failed: [])
        for d in targets.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
            focus(on: d, message: "Turn your head to follow the dot on this screen")
            let view = windows[d.key]!.dotView
            let points = Self.points(for: d, among: all)
            view.moveDot(to: view.local(points[0], in: d), animated: false)
            guard await pause(1.5) else { return nil }
            view.setMessage("")
            // FR-CAL-01: about 20 s per display, split across its points.
            let hold = min(max(20 / Double(points.count) - 0.35, 1.6), 3.0)
            var windowsOfInterest: [ClosedRange<TimeInterval>] = []
            samples.removeAll()
            for p in points {
                view.moveDot(to: view.local(p, in: d), animated: true)
                guard await pause(0.35) else { return nil }
                let arrived = now()
                view.setHolding(true)
                guard await pause(hold) else { return nil }
                view.setHolding(false)
                // FR-CAL-02: only while the dot is still and a face is seen; skip the first 300 ms.
                windowsOfInterest.append((arrived + 0.3)...now())
            }
            let kept = samples.filter { s in windowsOfInterest.contains { $0.contains(s.timestamp) } }
            if let m = DisplayModel.fit(key: d.key, name: d.name, cameraID: cameraID, samples: kept) {
                outcome.models.append(m)
            } else {
                outcome.failed.append(d)
            }
        }
        return outcome
    }

    /// FR-CAL-01 dot path in global coordinates: centre, the four corners, and two points along
    /// every edge shared with a neighbouring display, in one tour around the screen.
    nonisolated public static func points(for d: DisplayInfo, among all: [DisplayInfo], inset: CGFloat = 60) -> [CGPoint] {
        let r = d.bounds.insetBy(dx: inset, dy: inset)
        let b = d.bounds
        let others = all.filter { $0.key != d.key }.map(\.bounds)
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 2 }
        func overlap(_ lo1: CGFloat, _ hi1: CGFloat, _ lo2: CGFloat, _ hi2: CGFloat) -> (CGFloat, CGFloat)? {
            let lo = max(lo1, lo2), hi = min(hi1, hi2)
            return hi - lo > 1 ? (lo, hi) : nil
        }
        func thirds(_ span: (CGFloat, CGFloat), lo: CGFloat, hi: CGFloat) -> [CGFloat] {
            [1.0 / 3, 2.0 / 3].map { min(max(span.0 + (span.1 - span.0) * $0, lo), hi) }
        }
        func shared(_ side: (CGRect) -> (CGFloat, CGFloat)?) -> [(CGFloat, CGFloat)] { others.compactMap(side) }

        let top = shared { near($0.maxY, b.minY) ? overlap(b.minX, b.maxX, $0.minX, $0.maxX) : nil }
        let right = shared { near($0.minX, b.maxX) ? overlap(b.minY, b.maxY, $0.minY, $0.maxY) : nil }
        let bottom = shared { near($0.minY, b.maxY) ? overlap(b.minX, b.maxX, $0.minX, $0.maxX) : nil }
        let left = shared { near($0.maxX, b.minX) ? overlap(b.minY, b.maxY, $0.minY, $0.maxY) : nil }

        var path = [CGPoint(x: r.midX, y: r.midY), CGPoint(x: r.minX, y: r.minY)]
        path += top.flatMap { thirds($0, lo: r.minX, hi: r.maxX) }.sorted().map { CGPoint(x: $0, y: r.minY) }
        path.append(CGPoint(x: r.maxX, y: r.minY))
        path += right.flatMap { thirds($0, lo: r.minY, hi: r.maxY) }.sorted().map { CGPoint(x: r.maxX, y: $0) }
        path.append(CGPoint(x: r.maxX, y: r.maxY))
        path += bottom.flatMap { thirds($0, lo: r.minX, hi: r.maxX) }.sorted(by: >).map { CGPoint(x: $0, y: r.maxY) }
        path.append(CGPoint(x: r.minX, y: r.maxY))
        path += left.flatMap { thirds($0, lo: r.minY, hi: r.maxY) }.sorted(by: >).map { CGPoint(x: r.minX, y: $0) }
        return path
    }

    // MARK: Validation

    /// FR-CAL-05: look at each display for 2 s; returns the fraction of samples classified to it.
    /// Nil if the user pressed Escape.
    public func validate(_ displays: [DisplayInfo], classifier: some DisplayClassifier) async -> [DisplayKey: Double]? {
        open(displays)
        var result: [DisplayKey: Double] = [:]
        for d in displays.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
            focus(on: d, message: "Look at this screen")
            let view = windows[d.key]!.dotView
            view.moveDot(to: CGPoint(x: d.bounds.width / 2, y: d.bounds.height / 2), animated: false)
            view.setHolding(true)
            guard await pause(0.8) else { return nil }
            samples.removeAll()
            guard await pause(2) else { return nil }
            view.setHolding(false)
            let hits = samples.filter { classifier.classify($0, current: nil) == .candidate(d.key) }.count
            result[d.key] = samples.count < 5 ? 0 : Double(hits) / Double(samples.count)
        }
        return result
    }

    // MARK: Windows

    private func open(_ displays: [DisplayInfo]) {
        cancelled = false
        if collector == nil {
            let events = source.events()
            collector = Task { [weak self] in
                for await e in events {
                    if case .pose(let s) = e { self?.samples.append(s) }
                }
            }
        }
        for d in displays where windows[d.key] == nil {
            let w = OverlayWindow(display: d) { [weak self] in self?.cancelled = true }
            windows[d.key] = w
        }
        NSApp.activate()
        for w in windows.values { w.orderFrontRegardless() }
        windows.values.first?.makeKey()
    }

    /// Dims every overlay except `d`, which shows the dot and `message`.
    private func focus(on d: DisplayInfo, message: String) {
        for (key, w) in windows {
            let active = key == d.key
            w.dotView.setDot(visible: active)
            w.dotView.setMessage(active ? message : "Look at the other screen")
            w.dotView.setDimmed(!active)
            if active { w.makeKey() }
        }
    }

    public func hide() {
        for w in windows.values { w.orderOut(nil) }
    }

    public func close() {
        collector?.cancel()
        collector = nil
        for w in windows.values { w.close() }
        windows.removeAll()
    }

    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !cancelled
    }
}

/// Borderless full-screen window that can take key focus so Escape cancels.
final class OverlayWindow: NSWindow {
    let dotView: DotView
    private let onCancel: () -> Void

    @MainActor init(display: DisplayInfo, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        dotView = DotView(frame: CGRect(origin: .zero, size: display.bounds.size))
        super.init(contentRect: cocoaRect(display.bounds), styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = dotView
        setAccessibilityLabel("Glanzow calibration. Press Escape to cancel.")
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() } else { super.keyDown(with: event) }
    }
}

final class DotView: NSView {
    private let dot = CALayer()
    private let label = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        dot.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        dot.cornerRadius = 14
        dot.backgroundColor = NSColor.systemOrange.cgColor
        dot.borderColor = NSColor.white.cgColor
        dot.borderWidth = 3
        layer?.addSublayer(dot)
        label.font = .systemFont(ofSize: 24, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: frame.height * 0.3, width: frame.width, height: 40)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Global display coordinates → this view's (flipped) coordinates.
    func local(_ p: CGPoint, in d: DisplayInfo) -> CGPoint { CGPoint(x: p.x - d.bounds.minX, y: p.y - d.bounds.minY) }

    func moveDot(to p: CGPoint, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.35)
        dot.position = p
        CATransaction.commit()
    }

    /// Shrinks the dot while samples are collected: the cue to hold still.
    func setHolding(_ holding: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        dot.transform = holding ? CATransform3DMakeScale(0.55, 0.55, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    func setDot(visible: Bool) { dot.isHidden = !visible }
    func setMessage(_ s: String) {
        label.stringValue = s
        setAccessibilityLabel(s)
    }
    func setDimmed(_ dimmed: Bool) {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(dimmed ? 0.6 : 0.85).cgColor
    }
}
