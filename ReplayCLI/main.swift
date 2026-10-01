import Foundation
import GlanzowKit

// §8 replay harness: runs a recorded pose stream through the same smoother, classifier and
// SwitchController as the app, with a FocusManager stand-in that only logs.

let usage = """
usage: ReplayCLI <recording.json> [options]
  --dwell <ms>          delay before switching (default 300)
  --head-turn <0-1>     hysteresis setting (default 0.5 = factor 1.2)
  --reject <d>          off-screen threshold, Mahalanobis (default 4.0)
  --typing <s>          typing pause, 0 = off (default 3)
  --mouse <s>           mouse quiet period (default 1.5)
  --min-cutoff <hz>     One Euro min cutoff (default 1.0)
  --beta <b>            One Euro beta (default 0.05)
  --d-cutoff <hz>       One Euro derivative cutoff (default 1.0)
  --quiet               summary only
"""

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first, !path.hasPrefix("-") else {
    print(usage)
    exit(2)
}
func option(_ name: String) -> Double? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    guard let v = Double(args[i + 1]) else {
        print("bad value for \(name): \(args[i + 1])")
        exit(2)
    }
    return v
}

var tuning = Tuning()
if let v = option("--dwell") { tuning.dwell = v / 1000 }
if let v = option("--head-turn") { tuning.hysteresisFactor = Tuning.hysteresisFactor(headTurn: v) }
if let v = option("--reject") { tuning.rejectThreshold = v }
if let v = option("--typing") { tuning.typingPause = v > 0 ? v : nil }
if let v = option("--mouse") { tuning.mouseQuiet = v }
var smoothing = SmoothingParams()
if let v = option("--min-cutoff") { smoothing.minCutoff = v }
if let v = option("--beta") { smoothing.beta = v }
if let v = option("--d-cutoff") { smoothing.dCutoff = v }
let quiet = args.contains("--quiet")

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let recording: Recording
do {
    recording = try decoder.decode(Recording.self, from: Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
} catch {
    print("cannot read \(path): \(error)")
    exit(1)
}
guard !recording.models.isEmpty else {
    print("recording has no calibration models; record after calibrating")
    exit(1)
}

final class ReplayInput: InputMonitor, @unchecked Sendable {
    var lastKeystroke = -Double.infinity
    var lastMouseActivity = -Double.infinity
}

actor LoggingFocus: FocusPerformer {
    func focus(display: DisplayKey) -> FocusOutcome { .focusedWindow }
    func focus(region: Region) -> FocusOutcome { .focusedWindow } // recordings carry no window layouts
}

final class Records: @unchecked Sendable { var list: [SwitchRecord] = [] }

let names = Dictionary(recording.models.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
let classifier = MahalanobisClassifier(models: recording.models, rejectThreshold: tuning.rejectThreshold,
                                       hysteresisFactor: tuning.hysteresisFactor)
let input = ReplayInput()
let records = Records()
let controller = SwitchController(classifier: classifier, tuning: tuning, focus: LoggingFocus(), input: input)
await controller.setOnSwitch { records.list.append($0) }
await controller.setPaused(false)

var smoother = PoseSmoother(smoothing)
var latest: PoseSample?
var poses = 0, offScreen = 0, lost = 0, clicks = 0, clickHits = 0
var share: [DisplayKey: Int] = [:]
let events = recording.events.sorted { $0.t < $1.t }
for e in events {
    switch e.kind {
    case .pose:
        guard let raw = e.pose else { continue }
        let s = smoother(raw)
        latest = s
        poses += 1
        switch classifier.classify(s, current: nil) {
        case .candidate(let d): share[d, default: 0] += 1
        default: offScreen += 1
        }
        let before = records.list.count
        await controller.handle(.pose(s))
        if !quiet, records.list.count > before, let r = records.list.last {
            let from = r.from.map { names[$0] ?? $0 } ?? "—"
            print(String(format: "%9.3fs  %@ → %@  settled %.3fs", r.time - events[0].t, from, names[r.to] ?? r.to, r.time - r.pendingSince))
        }
    case .noFace:
        lost += 1
        await controller.handle(.noFace(e.t))
    case .key:
        input.lastKeystroke = e.t
    case .mouse:
        input.lastMouseActivity = e.t
    case .click:
        input.lastMouseActivity = e.t
        if let d = e.display, let s = latest, e.t - s.timestamp < 0.25 {
            clicks += 1
            if classifier.classify(s, current: nil) == .candidate(d) { clickHits += 1 }
        }
    case .focus:
        await controller.setCurrent(e.display)
    }
}

let duration = max((events.last?.t ?? 0) - (events.first?.t ?? 0), 0.001)
print("")
print(String(format: "recording %.1f min, %d poses, %d no-face frames", duration / 60, poses, lost))
print(String(format: "off-screen %.1f%% of poses", 100 * Double(offScreen) / Double(max(poses, 1))))
for m in recording.models {
    print(String(format: "  %@: %.1f%% of poses", m.name, 100 * Double(share[m.key, default: 0]) / Double(max(poses, 1))))
}
print(String(format: "switches %d (%.1f per hour)", records.list.count, Double(records.list.count) / duration * 3600))
if clicks > 0 {
    print(String(format: "click agreement %d/%d (%.0f%%)", clickHits, clicks, 100 * Double(clickHits) / Double(clicks)))
}
