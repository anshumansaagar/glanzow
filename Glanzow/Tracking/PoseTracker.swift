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
    /// Pupil centre minus eye-contour centroid, over eye width, averaged across eyes (FR-TRK-03).
    public var pupilOffset: SIMD2<Double>?
    public var confidence: Double

    public init(timestamp: TimeInterval, yaw: Double, pitch: Double, roll: Double = 0, faceScale: Double = 0.2,
                pupilOffset: SIMD2<Double>? = nil, confidence: Double = 1) {
        self.timestamp = timestamp; self.yaw = yaw; self.pitch = pitch; self.roll = roll
        self.faceScale = faceScale; self.pupilOffset = pupilOffset; self.confidence = confidence
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
    private let handler = VNSequenceRequestHandler()
    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3 // continuous yaw, pitch and roll (§6.1)
        return r
    }()
    private let landmarkRequest = VNDetectFaceLandmarksRequest()

    public func events() -> AsyncStream<PoseEvent> { output.stream() }

    public func configure(smoothing: SmoothingParams, trackPupils: Bool) {
        config.withLock { $0.smoothing = smoothing; $0.trackPupils = trackPupils }
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
        let raw = detect(pixels, at: t, pupils: cfg.trackPupils, minConfidence: cfg.minConfidence)
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

    private func detect(_ pixels: CVPixelBuffer, at t: TimeInterval, pupils: Bool, minConfidence: Double) -> PoseEvent {
        guard (try? handler.perform([faceRequest], on: pixels, orientation: .up)) != nil,
              let face = pick(faceRequest.results ?? []),
              let yaw = face.yaw?.doubleValue, let pitch = face.pitch?.doubleValue, let roll = face.roll?.doubleValue,
              Double(face.confidence) >= minConfidence // §7: glasses, poor light, backlight → no face
        else { return .noFace(t) }
        let deg = 180 / Double.pi
        // SPEC: §7 asks for "roll-compensated yaw; if roll > 30°, ignore sample". Vision already
        // returns yaw, pitch and roll as separate Euler angles, so rotating yaw by roll again would
        // count the tilt twice; only the 30° gate is applied. An ignored sample counts as no face,
        // so a long tilt reads as "No face" and nothing switches.
        guard abs(roll * deg) <= 30 else { return .noFace(t) }
        var sample = PoseSample(timestamp: t, yaw: yaw * deg, pitch: pitch * deg, roll: roll * deg,
                                faceScale: Double(face.boundingBox.width), confidence: Double(face.confidence))
        if pupils { sample.pupilOffset = pupilOffset(face, pixels) }
        return .pose(sample)
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

    /// §6.1: pupil centre minus eye-contour centroid, normalised by eye width, averaged over both eyes.
    private func pupilOffset(_ face: VNFaceObservation, _ pixels: CVPixelBuffer) -> SIMD2<Double>? {
        landmarkRequest.inputFaceObservations = [face]
        guard (try? handler.perform([landmarkRequest], on: pixels, orientation: .up)) != nil,
              let marks = landmarkRequest.results?.first?.landmarks else { return nil }
        let eyes = [(marks.leftPupil, marks.leftEye), (marks.rightPupil, marks.rightEye)].compactMap { pupil, eye -> SIMD2<Double>? in
            guard let p = pupil?.normalizedPoints.first, let contour = eye?.normalizedPoints, !contour.isEmpty else { return nil }
            let xs = contour.map { Double($0.x) }, ys = contour.map { Double($0.y) }
            let width = xs.max()! - xs.min()!
            guard width > 0 else { return nil }
            let centroid = SIMD2(xs.reduce(0, +), ys.reduce(0, +)) / Double(contour.count)
            return (SIMD2(Double(p.x), Double(p.y)) - centroid) / width
        }
        return eyes.isEmpty ? nil : eyes.reduce(.zero, +) / Double(eyes.count)
    }
}
