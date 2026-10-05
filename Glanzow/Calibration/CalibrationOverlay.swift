import AppKit
import QuartzCore

/// Full-screen dot overlays for calibration (FR-CAL-01, 02) and validation (FR-CAL-05).
@MainActor public final class CalibrationOverlay {
    public struct Outcome {
        public var models: [DisplayModel]
        /// Displays where the face was seen too rarely to fit a model.
        public var failed: [DisplayInfo]
        public var spotChecks: [DisplayKey: SpotCheck] = [:]
    }

    /// How closely a gaze map finds the fixed spots, per axis, as a share of the screen: the map
    /// from the tour alone against the one that also learned from the spots.
    public struct SpotCheck: Sendable {
        public var tourOnly: SIMD2<Double>
        public var final: SIMD2<Double>
        public var spots: Int
    }

    private let source: PoseSource
    private var windows: [DisplayKey: OverlayWindow] = [:]
    private var cancelled = false
    private var samples: [PoseSample] = []
    private var collector: Task<Void, Never>?

    public init(source: PoseSource) { self.source = source }

    // MARK: Calibration

    /// "Trace the gleam": on each target display, a short rest at the centre, then the light
    /// glides once around the screen (every corner and shared edge, FR-CAL-01) and across the
    /// middle, at an easy pace for the eyes to follow. This is smooth-pursuit calibration
    /// (Pfeuffer et al., UIST 2013): every frame on the way is a training pair, many times more
    /// data than resting on a few dots. Then nine fixed spots, looked at as things are in real use;
    /// about 25 s a screen in all. Nil if the user pressed Escape.
    public func calibrate(_ targets: [DisplayInfo], among all: [DisplayInfo], cameraID: String) async -> Outcome? {
        open(all)
        var outcome = Outcome(models: [], failed: [])
        let ordered = targets.sorted(by: { $0.bounds.minX < $1.bounds.minX })
        for (i, d) in ordered.enumerated() {
            focus(on: d, title: "Follow the gleam", subtitle: "Watch it with your eyes as it glides around this screen. Your head can move as it likes.")
            let view = windows[d.key]!.dotView
            let path = Polyline(Self.pursuitPath(for: d, among: all))
            let centre = CGPoint(x: d.bounds.midX, y: d.bounds.midY)
            view.setProgress(ordered.count > 1 ? "Screen \(i + 1) of \(ordered.count)" : "")
            view.moveDot(to: view.local(centre, in: d), animated: false)
            guard await pause(1.8) else { return nil }
            view.setText(title: "", subtitle: "Keep your eyes on the gleam")
            samples.removeAll()
            // A short rest at the centre anchors the middle of the screen.
            view.hold(for: 1.2)
            let restStart = now()
            guard await pause(1.2) else { return nil }
            view.release()
            let restEnd = now()
            // Ease over to where the tour starts; not sampled.
            view.moveDot(to: view.local(path.position(at: 0), in: d), animated: true)
            guard await pause(0.5) else { return nil }
            // The tour, at a constant speed chosen so it takes about 12 s.
            let speed = max(path.length / 12, 1)
            let tourStart = now()
            while true {
                guard !cancelled else { return nil }
                let travelled = CGFloat(now() - tourStart) * speed
                if travelled >= path.length { break }
                view.moveDot(to: view.local(path.position(at: travelled), in: d), animated: false, trail: true)
                if ordered.count > 1 {
                    view.setProgress("Screen \(i + 1) of \(ordered.count), \(Int(travelled / path.length * 100))%")
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            view.clearTrail()
            let tourEnd = now()
            // Then the gleam jumps between fixed spots. A target that jumps is looked at the way
            // things are in real use, eyes first with the head following a little; one that glides
            // invites tracking it with the head, which teaches the map little about the eyes.
            view.setText(title: "", subtitle: "Now look at each spot as it appears")
            var spots: [(shown: ClosedRange<TimeInterval>, target: SIMD2<Double>)] = []
            for p in Self.fixedSpots(in: d) {
                view.moveDot(to: view.local(p, in: d), animated: false)
                view.hold(for: 0.9)
                let shown = now()
                guard await pause(0.9) else { return nil }
                spots.append(((shown + 0.35)...(shown + 0.9), Self.normalised(p, in: d))) // once eyes and head have settled
            }
            view.release()
            let pairs = Self.pursuitPairs(samples, rest: (restStart + 0.3)...restEnd, centre: centre,
                                          tour: tourStart...tourEnd, path: path, speed: speed, in: d)
            let fixed = Self.spotPairs(samples, spots)
            if var m = DisplayModel.fit(key: d.key, name: d.name, cameraID: cameraID, samples: pairs.map(\.sample)) {
                let all = fixed + pairs // spots first, so the cap below can never drop them
                m.gaze = GazeMap.fit(all) // FR-P2-01
                let stride = max(1, all.count / DisplayModel.maxGazePairs) // keep an even spread
                m.gazePairs = Swift.stride(from: 0, to: all.count, by: stride).prefix(DisplayModel.maxGazePairs).map { GazePair(all[$0].sample, target: all[$0].target) }
                outcome.models.append(m)
                if let tour = GazeMap.fit(pairs), let final = m.gaze, !fixed.isEmpty {
                    outcome.spotChecks[d.key] = SpotCheck(tourOnly: tour.rms(on: fixed), final: final.rms(on: fixed), spots: fixed.count)
                }
            } else {
                outcome.failed.append(d)
            }
        }
        return outcome
    }

    /// FR-CAL-02 for a moving target: pairs each pose with where the gleam was a moment before
    /// (the eyes trail a moving target by about 0.1 s), skipping the first 0.4 s of the tour,
    /// while the eyes catch up, and 0.25 s either side of each corner, where they cut it short.
    nonisolated static func pursuitPairs(_ samples: [PoseSample], rest: ClosedRange<TimeInterval>, centre: CGPoint,
                                         tour: ClosedRange<TimeInterval>, path: Polyline, speed: CGFloat,
                                         in d: DisplayInfo, lag: TimeInterval = 0.1) -> [(sample: PoseSample, target: SIMD2<Double>)] {
        let cornerGap = 0.25 * Double(speed)
        return samples.compactMap { s in
            if rest.contains(s.timestamp) { return (s, normalised(centre, in: d)) }
            let t = s.timestamp - lag
            guard t >= tour.lowerBound + 0.4, t <= tour.upperBound else { return nil }
            let travelled = CGFloat(t - tour.lowerBound) * speed
            guard path.corners.allSatisfy({ abs(Double($0 - travelled)) > cornerGap }) else { return nil }
            return (s, normalised(path.position(at: travelled), in: d))
        }
    }

    nonisolated static func normalised(_ p: CGPoint, in d: DisplayInfo) -> SIMD2<Double> {
        SIMD2(Double((p.x - d.bounds.minX) / d.bounds.width), Double((p.y - d.bounds.minY) / d.bounds.height))
    }

    /// A 3×3 grid, in an order where every move is a long jump (two of them the full height), so
    /// each spot is a fresh look rather than a small correction.
    nonisolated static func fixedSpots(in d: DisplayInfo) -> [CGPoint] {
        let order: [(x: CGFloat, y: CGFloat)] = [(0.1, 0.1), (0.9, 0.9), (0.9, 0.1), (0.1, 0.9), (0.5, 0.5),
                                                 (0.1, 0.5), (0.9, 0.5), (0.5, 0.1), (0.5, 0.9)]
        return order.map { CGPoint(x: d.bounds.minX + $0.x * d.bounds.width, y: d.bounds.minY + $0.y * d.bounds.height) }
    }

    /// Each sample taken while a spot was settled on, paired with that spot.
    nonisolated static func spotPairs(_ samples: [PoseSample], _ spots: [(shown: ClosedRange<TimeInterval>, target: SIMD2<Double>)])
        -> [(sample: PoseSample, target: SIMD2<Double>)] {
        samples.compactMap { s in spots.first { $0.shown.contains(s.timestamp) }.map { (s, $0.target) } }
    }

    /// The tour: the FR-CAL-01 points in order (every corner, and two points on each shared edge),
    /// back to the first corner, then across the middle left to right and top to bottom.
    nonisolated public static func pursuitPath(for d: DisplayInfo, among all: [DisplayInfo], inset: CGFloat = 60) -> [CGPoint] {
        let r = d.bounds.insetBy(dx: inset, dy: inset)
        let loop = Array(points(for: d, among: all, inset: inset).dropFirst()) // without the centre
        return loop + [loop[0], CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
                       CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY)]
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
    /// A calibration screen mid-tour, for design snapshots.
    public static func preview(size: CGSize) -> NSView {
        let v = DotView(frame: CGRect(origin: .zero, size: size))
        v.setText(title: "", subtitle: "Keep your eyes on the gleam")
        v.setProgress("Screen 2 of 3, 38%")
        for i in 0..<18 { v.moveDot(to: CGPoint(x: size.width - 60, y: 120 + CGFloat(i) * 14), animated: false, trail: true) }
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
        trail.fillColor = nil
        trail.strokeColor = Palette.gleam.withAlphaComponent(0.28).cgColor
        trail.lineWidth = 7
        trail.lineCap = .round
        trail.lineJoin = .round
        layer?.addSublayer(trail)
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

    private let trail = CAShapeLayer()
    private var trailPoints: [CGPoint] = []

    func moveDot(to p: CGPoint, animated: Bool, trail showTrail: Bool = false) {
        if showTrail {
            // A soft comet tail of the last ~0.3 s, so the motion reads as smooth and alive.
            trailPoints.append(p)
            if trailPoints.count > 18 { trailPoints.removeFirst(trailPoints.count - 18) }
            let path = CGMutablePath()
            path.addLines(between: trailPoints)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            trail.path = path
            dot.position = p
            CATransaction.commit()
            return
        }
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

    func clearTrail() {
        trailPoints.removeAll()
        trail.path = nil
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

/// A path through points, walked by distance along it.
struct Polyline {
    let points: [CGPoint]
    private let cumulative: [CGFloat]
    /// Distances along the path where it turns by more than 30°.
    let corners: [CGFloat]

    init(_ points: [CGPoint]) {
        self.points = points
        var c: [CGFloat] = [0]
        for (a, b) in zip(points, points.dropFirst()) { c.append(c.last! + hypot(b.x - a.x, b.y - a.y)) }
        cumulative = c
        var turns: [CGFloat] = []
        if points.count >= 3 {
            for i in 1..<(points.count - 1) {
                let u = CGPoint(x: points[i].x - points[i - 1].x, y: points[i].y - points[i - 1].y)
                let v = CGPoint(x: points[i + 1].x - points[i].x, y: points[i + 1].y - points[i].y)
                let nu = hypot(u.x, u.y), nv = hypot(v.x, v.y)
                guard nu > 0, nv > 0 else { continue }
                if (u.x * v.x + u.y * v.y) / (nu * nv) < cos(.pi / 6) { turns.append(c[i]) }
            }
        }
        corners = turns
    }

    var length: CGFloat { cumulative.last ?? 0 }

    func position(at distance: CGFloat) -> CGPoint {
        guard let first = points.first else { return .zero }
        guard distance > 0 else { return first }
        guard distance < length else { return points.last! }
        let i = cumulative.lastIndex { $0 <= distance }!
        let span = cumulative[i + 1] - cumulative[i]
        let f = span > 0 ? (distance - cumulative[i]) / span : 0
        return CGPoint(x: points[i].x + (points[i + 1].x - points[i].x) * f, y: points[i].y + (points[i + 1].y - points[i].y) * f)
    }
}
