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
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            nc.addObserver(forName: name, object: session, queue: nil) { [weak self] note in
                self?.queue.async {
                    guard let self, self.wanted else { return }
                    self.log.error("capture stopped: \(note.name.rawValue, privacy: .public)")
                    self.publish(.busy)
                    self.scheduleRetry()
                }
            }
        }
        nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { self?.configure() }
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

    /// FR-TRK-08 adaptive rate: 15 fps normally, 5 fps when the head has been still.
    public func setFrameRate(_ fps: Int) {
        tracker.setFrameRate(fps)
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
        if session.isRunning {
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

/// FR-TRK-08: drop to 5 fps after 30 s with no head movement over 2°, back to 15 fps on movement.
/// Movement is measured from an anchor pose, so a slow drift still counts once it adds up.
public struct FrameRateGovernor: Sendable {
    public static let active = 15
    public static let idle = 5
    public private(set) var fps = active
    private var anchor: SIMD2<Double>?
    private var anchorTime: TimeInterval?

    public init() {}

    /// The new frame rate when it should change, else nil. No face counts as no movement, so an
    /// empty chair also drops to 5 fps.
    public mutating func update(_ e: PoseEvent) -> Int? {
        let t = e.timestamp
        if case .pose(let s) = e, anchor.map({ max(abs(s.yaw - $0.x), abs(s.pitch - $0.y)) > 2 }) ?? true {
            anchor = s.angles
            anchorTime = t
            guard fps != Self.active else { return nil }
            fps = Self.active
            return fps
        }
        let since = anchorTime ?? t
        anchorTime = since
        guard fps == Self.active, t - since >= 30 else { return nil }
        fps = Self.idle
        return fps
    }
}
