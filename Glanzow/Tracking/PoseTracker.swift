import AVFoundation
import os
import Vision

/// One head-pose measurement (FR-TRK-05). Angles in degrees, as Vision reports their sign (§6.1).
public struct PoseSample: Codable, Sendable, Equatable {
    public var timestamp: TimeInterval
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    /// Face bounding-box width in normalised image coordinates; grows as the user leans in.
    public var faceScale: Double
    /// Where the eyes point within their sockets, in eye widths: the iris centre relative to the
    /// middle of the corner-to-corner line, averaged over open eyes (FR-TRK-03; IrisLocator).
    public var pupilOffset: SIMD2<Double>?
    public var confidence: Double
    /// Other faces turned toward the screens, besides the user's (privacy guard).
    public var watchers: Int?

    public init(timestamp: TimeInterval, yaw: Double, pitch: Double, roll: Double = 0, faceScale: Double = 0.2,
                pupilOffset: SIMD2<Double>? = nil, confidence: Double = 1, watchers: Int? = nil) {
        self.timestamp = timestamp; self.yaw = yaw; self.pitch = pitch; self.roll = roll
        self.faceScale = faceScale; self.pupilOffset = pupilOffset; self.confidence = confidence; self.watchers = watchers
    }

    public var angles: SIMD2<Double> { SIMD2(yaw, pitch) }
}

/// What the tracker emits per processed frame: a confident pose, or nothing usable.
public enum PoseEvent: Sendable {
    case pose(PoseSample)
    case noFace(TimeInterval)

    public var timestamp: TimeInterval {
        switch self {
        case .pose(let s): s.timestamp
        case .noFace(let t): t
        }
    }
}

public protocol PoseSource: AnyObject, Sendable {
    /// A new subscription; each subscriber gets every event.
    func events() -> AsyncStream<PoseEvent>
}

/// Fan-out of one producer to many AsyncStream subscribers. Slow subscribers keep only the newest
/// events instead of growing without bound.
public final class Broadcast<T: Sendable>: @unchecked Sendable {
    private let subscribers = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<T>.Continuation]())

    public init() {}

    public func stream() -> AsyncStream<T> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<T>.makeStream(bufferingPolicy: .bufferingNewest(30))
        continuation.onTermination = { [weak self] _ in self?.subscribers.withLock { $0[id] = nil } }
        subscribers.withLock { $0[id] = continuation }
        return stream
    }

    public func send(_ value: T) {
        for c in subscribers.withLock({ Array($0.values) }) { c.yield(value) }
    }
}

/// Vision face pose per camera frame (FR-TRK-02, 03), smoothing (FR-TRK-04), confidence gating.
/// Runs entirely on its own serial queue, never the main thread. Frames never leave memory.
public final class PoseTracker: NSObject, PoseSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let queue = DispatchQueue(label: "dev.glanzow.vision", qos: .userInteractive)

    private struct Config {
        var smoothing = SmoothingParams()
        var trackPupils = false
        /// Landmarks on every n-th frame; the last pupil reading is reused in between.
        var pupilStride = 2
        var minInterval = 1.0 / 15
        var minConfidence = 0.6
        var rawTap: (@Sendable (PoseEvent) -> Void)?
    }
    private let config = OSAllocatedUnfairLock(initialState: Config())
    private let output = Broadcast<PoseEvent>()

    // Confined to `queue`.
    private var smoother = PoseSmoother()
    private var smootherParams = SmoothingParams()
    private var previousCenter: CGPoint?
    private var lastProcessed = -Double.infinity
    private var frameIndex = 0
    private var lastPupil: (t: TimeInterval, offset: SIMD2<Double>)?
    private let handler = VNSequenceRequestHandler()
    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3 // continuous yaw, pitch and roll (§6.1)
        return r
    }()
    private let landmarkRequest = VNDetectFaceLandmarksRequest()

    public func events() -> AsyncStream<PoseEvent> { output.stream() }

    /// `pupilStride` 1 measures pupils on every frame (calibration); 2 halves the landmark cost.
    public func configure(smoothing: SmoothingParams, trackPupils: Bool, pupilStride: Int = 2) {
        config.withLock { $0.smoothing = smoothing; $0.trackPupils = trackPupils; $0.pupilStride = max(pupilStride, 1) }
    }

    /// Software cap that backs up the camera's own frame-rate setting (some cameras ignore it).
    public func setFrameRate(_ fps: Int) { config.withLock { $0.minInterval = 1 / Double(max(fps, 1)) } }

    /// Debug-build pose recorder hook: sees raw, unsmoothed events.
    public func setRawTap(_ tap: (@Sendable (PoseEvent) -> Void)?) { config.withLock { $0.rawTap = tap } }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let t = Self.captureTime(sampleBuffer)
        let cfg = config.withLock { $0 }
        guard t - lastProcessed >= cfg.minInterval * 0.9, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastProcessed = t
        if cfg.smoothing != smootherParams {
            smootherParams = cfg.smoothing
            smoother = PoseSmoother(cfg.smoothing)
        }
        frameIndex += 1
        let measurePupils = cfg.trackPupils && frameIndex % cfg.pupilStride == 0
        let wall = PerfMeter.clock(), thread = PerfMeter.threadClock()
        let (detected, eyeNs) = detect(pixels, at: t, pupils: measurePupils, minConfidence: cfg.minConfidence)
        var raw = detected
        let found: Bool = { if case .pose = detected { return true }; return false }()
        PerfMeter.shared.frame(face: found, visionWall: PerfMeter.clock() - wall, visionThread: PerfMeter.threadClock() - thread, eyeWall: eyeNs)
        if case .pose(var s) = raw, cfg.trackPupils {
            // ponytail: half-rate landmarks (NFR-04 CPU); the in-between frame reuses a reading
            // under 0.25 s old. Every frame if within-screen focus ever needs it faster.
            if let p = s.pupilOffset { lastPupil = (t, p) } else if let last = lastPupil, t - last.t < 0.25 { s.pupilOffset = last.offset }
            raw = .pose(s)
        }
        cfg.rawTap?(raw)
        switch raw {
        case .pose(let s): self.output.send(.pose(smoother(s)))
        case .noFace: self.output.send(raw)
        }
    }

    /// Frame capture time on the host clock. Falls back to arrival time if the camera's clock is odd.
    static func captureTime(_ buffer: CMSampleBuffer) -> TimeInterval {
        let age = (CMClockGetTime(CMClockGetHostTimeClock()) - CMSampleBufferGetPresentationTimeStamp(buffer)).seconds
        return now() - ((0...0.5).contains(age) ? age : 0)
    }

    /// The event, plus how long the eye landmarks took when they ran (for PerfMeter).
    private func detect(_ pixels: CVPixelBuffer, at t: TimeInterval, pupils: Bool, minConfidence: Double) -> (PoseEvent, UInt64?) {
        guard (try? handler.perform([faceRequest], on: pixels, orientation: .up)) != nil,
              let face = pick(faceRequest.results ?? []),
              let yaw = face.yaw?.doubleValue, let pitch = face.pitch?.doubleValue, let roll = face.roll?.doubleValue,
              Double(face.confidence) >= minConfidence // §7: glasses, poor light, backlight → no face
        else { return (.noFace(t), nil) }
        let deg = 180 / Double.pi
        // SPEC: §7 asks for "roll-compensated yaw; if roll > 30°, ignore sample". Only the 30° gate
        // is applied. Whether tilt leaks into Vision's yaw and pitch depends on the order it
        // composes the three angles, which Apple doesn't document; a guessed correction could add
        // error rather than remove it. Measure first: record one session facing a single screen
        // with the head tilted, replay it, and add the rotation only if yaw/pitch drift with roll.
        // An ignored sample counts as no face, so a long tilt reads as "No face" and nothing switches.
        guard abs(roll * deg) <= 30 else { return (.noFace(t), nil) }
        var sample = PoseSample(timestamp: t, yaw: yaw * deg, pitch: pitch * deg, roll: roll * deg,
                                faceScale: Double(face.boundingBox.width), confidence: Double(face.confidence),
                                watchers: Self.watchers(besides: face, in: faceRequest.results ?? []))
        guard pupils else { return (.pose(sample), nil) }
        let start = PerfMeter.clock()
        sample.pupilOffset = pupilOffset(face, pixels)
        return (.pose(sample), PerfMeter.clock() - start)
    }

    /// Privacy guard: other confident faces, not tiny next to the user's, looking toward the
    /// screens (the camera sits at them). Costs nothing extra: the detector found them anyway.
    static func watchers(besides user: VNFaceObservation, in faces: [VNFaceObservation]) -> Int {
        let area = user.boundingBox.width * user.boundingBox.height
        let limit = 25 * Double.pi / 180
        return faces.filter { f in
            f !== user && f.confidence >= 0.7 && f.boundingBox.width * f.boundingBox.height >= area * 0.15
                && abs(f.yaw?.doubleValue ?? 1) <= limit && abs(f.pitch?.doubleValue ?? 1) <= limit
        }.count
    }

    /// §2, §7: with several faces, follow the largest, preferring the one nearest the last tracked face.
    private func pick(_ faces: [VNFaceObservation]) -> VNFaceObservation? {
        func area(_ f: VNFaceObservation) -> CGFloat { f.boundingBox.width * f.boundingBox.height }
        func distance(_ f: VNFaceObservation, _ p: CGPoint) -> CGFloat { hypot(f.boundingBox.midX - p.x, f.boundingBox.midY - p.y) }
        guard let largest = faces.max(by: { area($0) < area($1) }) else { return nil }
        let reference = previousCenter ?? CGPoint(x: 0.5, y: 0.5)
        let face = faces.filter { area($0) >= 0.5 * area(largest) }.min { distance($0, reference) < distance($1, reference) } ?? largest
        previousCenter = CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY)
        return face
    }

    /// FR-TRK-03, FR-P2-01: where the eyes point, in eye widths. Vision's eye contours give each
    /// eye's corners and how open it is; the iris itself is found in the camera image by
    /// IrisLocator, because Vision's own pupil points mostly follow the shape of the eye rather
    /// than the gaze. Blinks and half-closed eyes give no reading; two open eyes are averaged.
    private func pupilOffset(_ face: VNFaceObservation, _ pixels: CVPixelBuffer) -> SIMD2<Double>? {
        landmarkRequest.inputFaceObservations = [face]
        guard (try? handler.perform([landmarkRequest], on: pixels, orientation: .up)) != nil,
              let result = landmarkRequest.results?.first, let marks = result.landmarks else { return nil }
        let w = Double(CVPixelBufferGetWidth(pixels)), h = Double(CVPixelBufferGetHeight(pixels))
        let box = result.boundingBox
        // Landmarks are normalised to the face box with the origin bottom-left; pixels are top-left.
        func inImage(_ p: CGPoint) -> SIMD2<Double> {
            SIMD2((Double(box.minX) + Double(p.x) * Double(box.width)) * w,
                  (1 - (Double(box.minY) + Double(p.y) * Double(box.height))) * h)
        }
        let eyes = [marks.leftEye, marks.rightEye].compactMap { region -> SIMD2<Double>? in
            guard let points = region?.normalizedPoints, points.count >= 4 else { return nil }
            let contour = points.map(inImage)
            guard let a = contour.min(by: { $0.x < $1.x }), let b = contour.max(by: { $0.x < $1.x }) else { return nil }
            let width = ((b - a) * (b - a)).sum().squareRoot()
            let ys = contour.map(\.y)
            guard width > 0, (ys.max()! - ys.min()!) / width > 0.12 else { return nil } // a blink
            guard let patch = IrisLocator.patch(fromLuma: pixels, corners: a, b), let c = IrisLocator.centre(of: patch) else { return nil }
            return IrisLocator.eyeOffset(iris: c, width: patch.width, height: patch.height)
        }
        guard !eyes.isEmpty else { return nil }
        // Both eyes point the same way; a large disagreement means one reading went wrong.
        if eyes.count == 2, ((eyes[0] - eyes[1]) * (eyes[0] - eyes[1])).sum().squareRoot() > 0.25 { return nil }
        return eyes.reduce(.zero, +) / Double(eyes.count)
    }
}
