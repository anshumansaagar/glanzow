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
        let ordered = targets.sorted(by: { $0.bounds.minX < $1.bounds.minX })
        for (i, d) in ordered.enumerated() {
            focus(on: d, title: "Follow the light", subtitle: "Turn your head with it, the way you would naturally look at this screen.")
            let view = windows[d.key]!.dotView
            let points = Self.points(for: d, among: all)
            view.setProgress(ordered.count > 1 ? "Screen \(i + 1) of \(ordered.count)" : "")
            view.moveDot(to: view.local(points[0], in: d), animated: false)
            guard await pause(2.0) else { return nil }
            view.setText(title: "", subtitle: "Turn your head, not just your eyes")
            // FR-CAL-01: about 20 s per display, split across its points.
            let hold = min(max(20 / Double(points.count) - 0.45, 1.6), 3.0)
            var windowsOfInterest: [ClosedRange<TimeInterval>] = []
            samples.removeAll()
            for (j, p) in points.enumerated() {
                view.setProgress(ordered.count > 1 ? "Screen \(i + 1) of \(ordered.count), point \(j + 1) of \(points.count)"
                                                   : "Point \(j + 1) of \(points.count)")
                view.moveDot(to: view.local(p, in: d), animated: true)
                guard await pause(0.45) else { return nil }
                let arrived = now()
                view.hold(for: hold) // the ring closes in while samples are taken
                guard await pause(hold) else { return nil }
                view.release()
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
        let ordered = displays.sorted(by: { $0.bounds.minX < $1.bounds.minX })
        for (i, d) in ordered.enumerated() {
            focus(on: d, title: "Look here", subtitle: "Keep facing this screen for two seconds.")
            let view = windows[d.key]!.dotView
            view.setProgress("Checking screen \(i + 1) of \(ordered.count)")
            view.moveDot(to: CGPoint(x: d.bounds.width / 2, y: d.bounds.height / 2), animated: false)
            view.pulse()
            guard await pause(0.8) else { return nil }
            samples.removeAll()
            guard await pause(2) else { return nil }
            view.release()
            let hits = samples.filter { classifier.classify($0, current: nil) == .candidate(d.key) }.count
            result[d.key] = samples.count < 5 ? 0 : Double(hits) / Double(samples.count)
        }
        return result
    }

    #if DEBUG
    /// A calibration screen mid-hold, for design snapshots.
    public static func preview(size: CGSize) -> NSView {
        let v = DotView(frame: CGRect(origin: .zero, size: size))
        v.setText(title: "Follow the light", subtitle: "Turn your head with it, the way you would naturally look at this screen.")
        v.setProgress("Screen 2 of 3, point 3 of 7")
        v.moveDot(to: CGPoint(x: size.width - 60, y: 60), animated: false)
        return v
    }
    #endif

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

    /// Dims every overlay except `d`, which shows the light and the instructions.
    private func focus(on d: DisplayInfo, title: String, subtitle: String) {
        for (key, w) in windows {
            let active = key == d.key
            w.dotView.setDot(visible: active)
            w.dotView.setDimmed(!active)
            if active {
                w.makeKey() // before the text, so VoiceOver announces it from the key window
                w.dotView.setText(title: title, subtitle: subtitle)
            } else {
                w.dotView.setText(title: "", subtitle: "Look at the screen with the light")
                w.dotView.setProgress("")
            }
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

/// One screen's calibration surface: night ground, a soft vignette, and the gleam — a warm dot
/// whose ring closes in while it is collecting, so "hold still" needs no words.
final class DotView: NSView {
    private let vignette = CAGradientLayer()
    private let dot = CALayer()
    private let core = CALayer()
    private let ring = CAShapeLayer()
    private let title = DotView.label(Palette.headline(32), Palette.snow)
    private let subtitle = DotView.label(.systemFont(ofSize: 17), Palette.mist)
    private let progress = DotView.label(.systemFont(ofSize: 13, weight: .medium), Palette.mist)
    private let hint = DotView.label(.systemFont(ofSize: 12), Palette.mist.withAlphaComponent(0.7))

    override var isFlipped: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Palette.night.withAlphaComponent(0.95).cgColor

        vignette.type = .radial
        vignette.colors = [Palette.dusk.withAlphaComponent(0.6).cgColor, Palette.night.withAlphaComponent(0).cgColor]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1.15, y: 1.15)
        vignette.frame = bounds
        layer?.addSublayer(vignette)

        dot.bounds = CGRect(x: 0, y: 0, width: 72, height: 72)
        core.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        core.position = CGPoint(x: 36, y: 36)
        core.cornerRadius = 9
        core.backgroundColor = Palette.gleam.cgColor
        core.shadowColor = Palette.gleam.cgColor
        core.shadowOpacity = 0.95
        core.shadowRadius = 16
        core.shadowOffset = .zero
        ring.frame = dot.bounds
        ring.path = CGPath(ellipseIn: dot.bounds.insetBy(dx: 3, dy: 3), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = Palette.gleam.withAlphaComponent(0.55).cgColor
        ring.lineWidth = 2
        dot.addSublayer(ring)
        dot.addSublayer(core)
        layer?.addSublayer(dot)

        let w = frame.width
        title.frame = CGRect(x: 40, y: frame.height * 0.28, width: w - 80, height: 44)
        subtitle.frame = CGRect(x: 40, y: frame.height * 0.28 + 52, width: w - 80, height: 24)
        progress.frame = CGRect(x: 40, y: frame.height - 56, width: w - 80, height: 18)
        hint.frame = CGRect(x: 40, y: frame.height - 32, width: w - 80, height: 16)
        hint.stringValue = "Press Esc to cancel"
        [title, subtitle, progress, hint].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func label(_ font: NSFont, _ color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = font
        l.textColor = color
        l.alignment = .center
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    /// Global display coordinates → this view's (flipped) coordinates.
    func local(_ p: CGPoint, in d: DisplayInfo) -> CGPoint { CGPoint(x: p.x - d.bounds.minX, y: p.y - d.bounds.minY) }

    func moveDot(to p: CGPoint, animated: Bool) {
        release()
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.45)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        dot.position = p
        CATransaction.commit()
    }

    /// The ring closes from full size to the core over `seconds`: progress for the hold.
    func hold(for seconds: Double) {
        guard !Palette.reduceMotion else {
            ring.strokeColor = Palette.gleam.cgColor
            return
        }
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1
        a.toValue = 0.3
        a.duration = seconds
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        ring.add(a, forKey: "hold")
    }

    /// Validation: a slow breathing ring on a still light.
    func pulse() {
        guard !Palette.reduceMotion else { return }
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1
        a.toValue = 1.35
        a.duration = 0.9
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.add(a, forKey: "pulse")
    }

    func release() {
        ring.removeAllAnimations()
        ring.strokeColor = Palette.gleam.withAlphaComponent(0.55).cgColor
    }

    func setDot(visible: Bool) { dot.isHidden = !visible }

    func setText(title t: String, subtitle s: String) {
        title.stringValue = t
        subtitle.stringValue = s
        let spoken = [t, s].filter { !$0.isEmpty }.joined(separator: ". ")
        setAccessibilityLabel(spoken)
        if !spoken.isEmpty, window?.isKeyWindow ?? false { // VoiceOver hears each new instruction
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    func setProgress(_ s: String) { progress.stringValue = s }

    func setDimmed(_ dimmed: Bool) {
        layer?.backgroundColor = Palette.night.withAlphaComponent(dimmed ? 0.82 : 0.95).cgColor
        vignette.isHidden = dimmed
    }
}
