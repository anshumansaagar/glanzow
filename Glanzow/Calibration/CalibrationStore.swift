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

    public func set(_ list: [DisplayModel]) {
        models.withLock { m in for x in list { m[x.key] = x } }
        save()
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
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(File(models: all.values.sorted { $0.key < $1.key })).write(to: url, options: .atomic)
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
            models.withLock { $0 = Dictionary(file.models.map { ($0.key, $0) }, uniquingKeysWith: { _, b in b }) }
        } catch {
            log.error("load: \(error.localizedDescription, privacy: .public)") // corrupt file → treated as uncalibrated
        }
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
