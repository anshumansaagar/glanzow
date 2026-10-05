import Foundation
import os

/// A recorded session for ReplayCLI: numbers only — pose angles, timestamps and display keys.
/// Never images (NFR-08, §8 replay harness).
public struct Recording: Codable, Sendable {
    public var version = 1
    public var recordedAt = Date()
    public var cameraID: String
    public var models: [DisplayModel]
    public var events: [RecordedEvent] = []

    public init(cameraID: String, models: [DisplayModel]) {
        self.cameraID = cameraID
        self.models = models
    }
}

public struct RecordedEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case pose, noFace, key, mouse, click
        /// The user (or Glanzow) focused a window on `display`.
        case focus
    }

    public var t: Double
    public var kind: Kind
    public var pose: PoseSample?
    public var display: DisplayKey?

    public init(t: Double, kind: Kind, pose: PoseSample? = nil, display: DisplayKey? = nil) {
        self.t = t; self.kind = kind; self.pose = pose; self.display = display
    }
}

/// Collects raw pose and input-timing events in memory and writes them as JSON on stop.
public final class PoseRecorder: @unchecked Sendable {
    private struct State {
        var recording: Recording?
        var lastMouse = -Double.infinity
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    // ponytail: in-memory buffer, ~8 MB per hour at 15 fps; capped at 2 h. Stream to disk if longer runs matter.
    private let maxEvents = 15 * 3600 * 2 * 2

    public init() {}

    public static var directory: URL { Paths.appSupport.appending(path: "Recordings", directoryHint: .isDirectory) }

    public var isRecording: Bool { state.withLock { $0.recording != nil } }

    public func start(cameraID: String, models: [DisplayModel]) {
        state.withLock { $0 = State(recording: Recording(cameraID: cameraID, models: models)) }
    }

    public func record(_ e: PoseEvent) {
        switch e {
        case .pose(let s): append(RecordedEvent(t: s.timestamp, kind: .pose, pose: s))
        case .noFace(let t): append(RecordedEvent(t: t, kind: .noFace))
        }
    }

    public func record(_ kind: RecordedEvent.Kind, at t: Double, display: DisplayKey? = nil) {
        append(RecordedEvent(t: t, kind: kind, display: display))
    }

    private func append(_ e: RecordedEvent) {
        state.withLock { s in
            guard s.recording != nil, s.recording!.events.count < maxEvents else { return }
            if e.kind == .mouse { // pointer moves arrive at ~100 Hz; 10 Hz is plenty for guard replay
                guard e.t - s.lastMouse >= 0.1 else { return }
                s.lastMouse = e.t
            }
            s.recording!.events.append(e)
        }
    }

    /// Stops and writes the recording; returns its file URL.
    public func stop() throws -> URL? {
        guard let rec = state.withLock({ s -> Recording? in defer { s.recording = nil }; return s.recording }) else { return nil }
        try Paths.makePrivateDirectory(Self.directory)
        let stamp = ISO8601DateFormatter().string(from: rec.recordedAt).replacingOccurrences(of: ":", with: "-")
        let url = Self.directory.appending(path: "pose-\(stamp).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(rec).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
