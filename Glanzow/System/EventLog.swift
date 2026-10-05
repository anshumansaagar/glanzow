import Foundation

/// Append-only JSON-lines log of switches and blocked switches, for NFR-01 latency and NFR-03
/// false-switch review. Numbers and display keys only — never images (NFR-08).
public final class EventLog: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "dev.glanzow.eventlog", qos: .utility)
    private let maxBytes = 5_000_000

    public init(url: URL = Paths.appSupport.appending(path: "events.jsonl")) { self.url = url }

    public func append(_ event: String, _ fields: [String: Any]) {
        var line = fields
        line["event"] = event
        line["at"] = ISO8601DateFormatter().string(from: Date())
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        queue.async { [url, maxBytes] in
            let fm = FileManager.default
            try? Paths.makePrivateDirectory(url.deletingLastPathComponent())
            // ponytail: one rotation; keeps the last ~10 MB, plenty for a 3-workday NFR-03 review.
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxBytes {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                // The throwing API: the old write(_:) raises an uncatchable exception on a full disk.
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            } else {
                try? data.write(to: url)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) // this user only
            }
        }
    }
}
