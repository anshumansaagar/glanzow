import AVFoundation
import os

/// Camera device selection and capture-session lifecycle (FR-TRK-01, 07, 08; §7 camera cases).
/// Frames go straight to the PoseTracker's queue and are never copied or written anywhere.
public final class CameraCapture: NSObject, @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case running(id: String, name: String)
        /// No usable camera, e.g. lid closed with no external camera (§7).
        case noCamera
        /// The camera exists but will not start, e.g. another app holds it exclusively (§7).
        case busy
    }

    /// Called on the main thread when the state changes.
    public var onState: (@MainActor (State) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "dev.glanzow.camera")
    private let tracker: PoseTracker
    private let log = logger("camera")
    // Confined to `queue`.
    private var wanted = false
    private var preferredID: String?
    private var fps = 15
    private var device: AVCaptureDevice?
    private var retry: DispatchSourceTimer?
    private var state = State.stopped
    /// AVCaptureSession.isInterrupted is unavailable on macOS; track it from the notifications.
    private var interrupted = false

    public init(tracker: PoseTracker) {
        self.tracker = tracker
        super.init()
        output.alwaysDiscardsLateVideoFrames = true // FR-TRK-01
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(tracker, queue: tracker.queue)

        let nc = NotificationCenter.default
        nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.configure() }
        }
        nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            let gone = (note.object as? AVCaptureDevice)?.uniqueID
            self?.queue.async {
                guard let self, gone == self.device?.uniqueID else { return }
                self.log.info("camera unplugged")
                self.detach()
                self.configure() // falls back to built-in, else reports .noCamera
            }
        }
        nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async {
                guard let self, self.wanted else { return }
                self.log.error("capture runtime error")
                // Often just the unplug the disconnect handler already dealt with: try again
                // first, and report busy only if the camera really won't run.
                self.configure()
            }
        }
        nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async {
                guard let self, self.wanted else { return }
                self.log.error("capture interrupted")
                self.interrupted = true
                self.publish(.busy)
                self.scheduleRetry()
            }
        }
        nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async {
                self?.interrupted = false
                self?.configure()
            }
        }
    }

    public static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    /// FR-TRK-07: the saved camera by unique ID, else the built-in one, else any camera.
    public static func pick(preferred: String?, from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        if let preferred, let d = devices.first(where: { $0.uniqueID == preferred }) { return d }
        return devices.first { $0.deviceType == .builtInWideAngleCamera } ?? devices.first
    }

    public func start(preferredID: String?) {
        queue.async {
            let changed = preferredID != self.preferredID
            self.wanted = true
            self.preferredID = preferredID
            if changed { self.detach() }
            self.configure()
        }
    }

    public func stop() {
        queue.async {
            self.wanted = false
            self.cancelRetry()
            if self.session.isRunning { self.session.stopRunning() }
            self.publish(.stopped)
        }
    }

    /// The camera's own rate. The tracker can analyse fewer of the frames (PoseTracker.setFrameRate).
    public func setFrameRate(_ fps: Int) {
        queue.async {
            self.fps = fps
            self.applyFrameRate()
        }
    }

    private func detach() {
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
        device = nil
    }

    private func configure() {
        guard wanted else { return }
        guard let pick = Self.pick(preferred: preferredID, from: Self.devices()) else {
            if session.isRunning { session.stopRunning() }
            detach()
            publish(.noCamera)
            return // wasConnectedNotification brings us back
        }
        if pick.uniqueID != device?.uniqueID {
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            do {
                let input = try AVCaptureDeviceInput(device: pick)
                if session.canAddInput(input) { session.addInput(input) }
            } catch {
                session.commitConfiguration()
                log.error("camera input: \(error.localizedDescription, privacy: .public)")
                publish(.busy)
                scheduleRetry()
                return
            }
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 } // FR-TRK-01
            if session.outputs.isEmpty, session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            device = pick
        }
        if !session.isRunning { session.startRunning() }
        applyFrameRate()
        if session.isRunning && !interrupted {
            cancelRetry()
            publish(.running(id: pick.uniqueID, name: pick.localizedName))
        } else {
            publish(.busy)
            scheduleRetry()
        }
    }

    /// Caps the device at `fps` when its format supports that rate; PoseTracker's software cap
    /// covers cameras that cannot go that low.
    private func applyFrameRate() {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let rate = Double(fps)
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= rate && rate <= $0.maxFrameRate })
        else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    /// §7: "Another app takes the camera exclusively → pause, retry every 10 s".
    private func scheduleRetry() {
        guard retry == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.detach()
            self.configure()
        }
        timer.resume()
        retry = timer
    }

    private func cancelRetry() {
        retry?.cancel()
        retry = nil
    }

    private func publish(_ s: State) {
        guard s != state else { return }
        state = s
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onState?(s) } }
    }
}

/// FR-TRK-08, extended: how many frames a second are worth analysing. 15 while the head moves,
/// 8 once it has held still for 1.5 s (reading, typing), 5 after 30 s without movement (or with
/// nobody there). A turn shows up within one steady frame (≤ 125 ms) and restores 15 at once.
/// Movement is measured from an anchor pose, so a slow drift still counts once it adds up.
public struct FrameRateGovernor: Sendable {
    public static let active = 15
    public static let steady = 8
    public static let idle = 5
    public var steadyAfter: TimeInterval = 1.5
    public var idleAfter: TimeInterval = 30
    public private(set) var fps = active
    private var anchor: SIMD2<Double>?
    private var anchorTime: TimeInterval?

    public init() {}

    /// The new rate when it should change, else nil.
    public mutating func update(_ e: PoseEvent) -> Int? {
        let t = e.timestamp
        if case .pose(let s) = e, anchor.map({ max(abs(s.yaw - $0.x), abs(s.pitch - $0.y)) > 2 }) ?? true {
            anchor = s.angles
            anchorTime = t
            return set(Self.active)
        }
        let since = anchorTime ?? t
        anchorTime = since
        let still = t - since
        return set(still >= idleAfter ? Self.idle : still >= steadyAfter ? Self.steady : Self.active)
    }

    private mutating func set(_ rate: Int) -> Int? {
        guard rate != fps else { return nil }
        fps = rate
        return rate
    }
}
