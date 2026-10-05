import Foundation
import os

/// Display models keyed by display identity, persisted as JSON in Application Support (FR-CAL-03, 04).
public final class CalibrationStore: @unchecked Sendable {
    private struct File: Codable {
        var version = 1
        var models: [DisplayModel]
    }

    private let url: URL
    private let models = OSAllocatedUnfairLock(initialState: [DisplayKey: DisplayModel]())
    private let log = logger("calibration")

    public init(url: URL = Paths.appSupport.appending(path: "calibration.json")) {
        self.url = url
        load()
    }

    public var all: [DisplayKey: DisplayModel] { models.withLock { $0 } }

    public func model(_ key: DisplayKey) -> DisplayModel? { models.withLock { $0[key] } }

    /// `persist: false` for frequent small updates (click learning); call `save()` later.
    public func set(_ list: [DisplayModel], persist: Bool = true) {
        models.withLock { m in for x in list { m[x.key] = x } }
        if persist { save() }
    }

    /// A model is usable only for a connected display and the camera that made it: moving to
    /// another camera changes every angle.
    public func valid(for displays: [DisplayInfo], cameraID: String) -> [DisplayModel] {
        let m = all
        return displays.compactMap { d in m[d.key].flatMap { $0.cameraID == cameraID ? $0 : nil } }
    }

    public func uncalibrated(_ displays: [DisplayInfo], cameraID: String) -> [DisplayInfo] {
        let ok = Set(valid(for: displays, cameraID: cameraID).map(\.key))
        return displays.filter { !ok.contains($0.key) }
    }

    public func save() {
        do {
            try Paths.makePrivateDirectory(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(File(models: all.values.sorted { $0.key < $1.key })).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log.error("save: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let file = try decoder.decode(File.self, from: data)
            // The file is outside the app, so anything could be in it: keep only well-formed models.
            let usable = file.models.compactMap(Self.sanitized)
            if usable.count < file.models.count { log.error("load: dropped \(file.models.count - usable.count) malformed model(s)") }
            models.withLock { $0 = Dictionary(usable.map { ($0.key, $0) }, uniquingKeysWith: { _, b in b }) }
        } catch {
            log.error("load: \(error.localizedDescription, privacy: .public)") // corrupt file → treated as uncalibrated
        }
    }

    /// A model fit to use, or nil: every number finite and in a sane range, a valid covariance,
    /// and gaze-map rows of the right shape (a bad gaze map is dropped, the model kept).
    static func sanitized(_ m: DisplayModel) -> DisplayModel? {
        func ok(_ x: Double, _ limit: Double) -> Bool { x.isFinite && abs(x) <= limit }
        let c = m.covariance
        guard !m.key.isEmpty, m.key.count < 200, ok(m.mean.x, 180), ok(m.mean.y, 180),
              ok(c.xx, 1e5), ok(c.yy, 1e5), ok(c.xy, 1e5), c.xx >= 0, c.yy >= 0, c.determinant >= -1e-6,
              ok(m.meanFaceScale, 10), m.meanFaceScale >= 0 else { return nil }
        var model = m
        if let g = m.gaze {
            func rows(_ r: [[Double]], _ width: Int) -> Bool { r.count == 2 && r.allSatisfy { $0.count == width && $0.allSatisfy { ok($0, 1e4) } } }
            let headOK = rows(g.head, 3) && ok(g.headError, 100)
            let eyesOK = g.eyes.map { rows($0, 5) && ok(g.eyesError ?? .nan, 100) } ?? true
            if !(headOK && eyesOK) { model.gaze = nil }
        }
        return model
    }

    /// §6.1 mirror check: across displays that sit side by side, mean yaw must move in one
    /// direction as you go left to right (either sign is fine). False means a fit is suspect.
    public static func yawOrderConsistent(_ pairs: [(display: DisplayInfo, model: DisplayModel)]) -> Bool {
        let sorted = pairs.sorted { $0.display.bounds.midX < $1.display.bounds.midX }
        var directions = Set<Bool>()
        for (a, b) in zip(sorted, sorted.dropFirst())
        where b.display.bounds.midX - a.display.bounds.midX > min(a.display.bounds.width, b.display.bounds.width) / 2 {
            directions.insert(b.model.mean.x > a.model.mean.x)
        }
        return directions.count <= 1
    }
}
