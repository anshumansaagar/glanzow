import XCTest
@testable import GlanzowKit

final class FakeInput: InputMonitor, @unchecked Sendable {
    var lastKeystroke = -Double.infinity
    var lastMouseActivity = -Double.infinity
}

actor FakeFocus: FocusPerformer {
    var calls: [DisplayKey] = []
    var outcome = FocusOutcome.focusedWindow
    func focus(display: DisplayKey) -> FocusOutcome {
        calls.append(display)
        return outcome
    }
    func focus(region: Region) -> FocusOutcome {
        calls.append("@" + region.id)
        return outcome
    }
    func set(_ o: FocusOutcome) { outcome = o }
}

/// §8 "Switch decision: table-driven tests over timelines of (pose, keystroke, mouse) events,
/// asserting exactly when focus is called." Two displays: C at yaw 0, R at yaw 30. Poses at 15 fps.
final class SwitchControllerTests: XCTestCase {
    enum Step {
        case look(from: Int, to: Int, yaw: Double, pitch: Double = 0) // frames [from, to) at 15 fps
        case lost(from: Int, to: Int)
        case key(Double)
        case mouse(Double)
        case confirm(Double)
    }

    /// C also has a gaze map: x = 0.5 + yaw/40, y = 0.5 + pitch/30 (head only).
    private static let classifier = MahalanobisClassifier(models: [
        DisplayModel(key: "C", name: "C", mean: SIMD2(0, 0), covariance: Cov2(xx: 36, xy: 0, yy: 36), meanFaceScale: 0.2, cameraID: "", sampleCount: 50,
                     gaze: GazeMap(head: [[0.5, 1.0 / 40, 0], [0.5, 0, 1.0 / 30]], eyes: nil, headError: 0.05, eyesError: nil)),
        DisplayModel(key: "R", name: "R", mean: SIMD2(30, 0), covariance: Cov2(xx: 36, xy: 0, yy: 36), meanFaceScale: 0.2, cameraID: "", sampleCount: 50),
    ])

    /// Runs the steps in time order; returns (time, display) for every focus call.
    fileprivate func run(_ steps: [Step], tuning: Tuning = Tuning(), outcome: FocusOutcome = .focusedWindow,
                     blocked: String? = nil, paused: Bool = false, layout: ScreenLayout? = nil) async -> [(t: Double, d: DisplayKey)] {
        let input = FakeInput()
        let focus = FakeFocus()
        await focus.set(outcome)
        let c = SwitchController(classifier: Self.classifier, tuning: tuning, focus: focus, input: input, systemBlock: { blocked })
        await c.setCurrent("C")
        await c.setPaused(paused)
        await c.update(layout: layout)

        var timeline: [(t: Double, order: Int, act: () async -> Void)] = []
        for (i, step) in steps.enumerated() {
            switch step {
            case let .look(from, to, yaw, pitch):
                for k in from..<to {
                    let t = Double(k) / 15
                    timeline.append((t, i, { await c.handle(.pose(PoseSample(timestamp: t, yaw: yaw, pitch: pitch))) }))
                }
            case let .lost(from, to):
                for k in from..<to {
                    let t = Double(k) / 15
                    timeline.append((t, i, { await c.handle(.noFace(t)) }))
                }
            case .key(let t): timeline.append((t, i, { input.lastKeystroke = t }))
            case .mouse(let t): timeline.append((t, i, { input.lastMouseActivity = t }))
            case .confirm(let t): timeline.append((t, i, { await c.confirm(at: t) }))
            }
        }
        var calls: [(Double, DisplayKey)] = []
        for e in timeline.sorted(by: { ($0.t, $0.order) < ($1.t, $1.order) }) {
            let before = await focus.calls.count
            await e.act()
            let after = await focus.calls
            if after.count > before { calls.append((e.t, after.last!)) }
        }
        return calls
    }

    private func assertCalls(_ got: [(t: Double, d: DisplayKey)], _ want: [(Double, DisplayKey)], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, want.count, "calls: \(got)", file: file, line: line)
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g.t, w.0, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(g.d, w.1, file: file, line: line)
        }
    }

    // Frame k is at k/15 s. Facing R from frame 15 (1.0 s) means dwell 0.3 s completes at frame 20 (1.333 s).

    func test_FR_CLS_04_turnAndHoldSwitchesOnceAfterDwell() async {
        assertCalls(await run([.look(from: 0, to: 15, yaw: 0), .look(from: 15, to: 45, yaw: 30)]), [(20.0 / 15, "R")])
    }

    func test_FR_CLS_04_glanceShorterThanDwellDoesNotSwitch() async {
        assertCalls(await run([.look(from: 0, to: 15, yaw: 0), .look(from: 15, to: 19, yaw: 30), .look(from: 19, to: 45, yaw: 0)]), [])
    }

    func test_FR_CLS_04_dwellIsConfigurable() async {
        var t = Tuning()
        t.dwell = 0.6
        assertCalls(await run([.look(from: 15, to: 45, yaw: 30)], tuning: t), [(24.0 / 15, "R")])
    }

    func test_FR_CLS_03_nearBoundaryStaysOnCurrent() async {
        assertCalls(await run([.look(from: 0, to: 60, yaw: 16)]), [])
    }

    func test_FR_CLS_02_offScreenRestartsDwell() async {
        // R for 3 frames, phone (pitch −40) for 3, then R again from frame 21 → switch at frame 26.
        assertCalls(await run([.look(from: 15, to: 18, yaw: 30), .look(from: 18, to: 21, yaw: 0, pitch: -40),
                               .look(from: 21, to: 45, yaw: 30)]), [(26.0 / 15, "R")])
    }

    func test_FR_SAF_01_typingBlocksUntilASustainedOneSecondTurn() async {
        // Typed at 0.9 s; facing R from 1.0 s. Typing guard lasts until 3.9 s, but holding the
        // turn for 1 s overrides it at 2.0 s (frame 30).
        assertCalls(await run([.key(0.9), .look(from: 15, to: 60, yaw: 30)]), [(30.0 / 15, "R")])
    }

    func test_FR_SAF_01_glanceWhileTypingDoesNotSwitch() async {
        assertCalls(await run([.key(0.9), .key(1.4), .look(from: 15, to: 27, yaw: 30), .look(from: 27, to: 60, yaw: 0)]), [])
    }

    func test_FR_SAF_01_typingGuardOffSwitchesAtDwell() async {
        var t = Tuning()
        t.typingPause = nil
        assertCalls(await run([.key(0.9), .look(from: 15, to: 45, yaw: 30)], tuning: t), [(20.0 / 15, "R")])
    }

    func test_FR_SAF_02_mouseUseBlocksUntilQuietPeriodEnds() async {
        // Mouse at 1.2 s; quiet period 1.5 s → first frame at or after 2.7 s is frame 41.
        assertCalls(await run([.mouse(1.2), .look(from: 15, to: 60, yaw: 30)]), [(41.0 / 15, "R")])
    }

    func test_FR_SAF_02_mouseGuardOutranksTypingOverride() async {
        // Typing override would allow 2.0 s, but the mouse moved at 1.5 s: wait for 3.0 s (frame 45).
        assertCalls(await run([.key(0.9), .mouse(1.5), .look(from: 15, to: 75, yaw: 30)]), [(45.0 / 15, "R")])
    }

    func test_FR_CLS_04_anyFaceDropoutRestartsDwell() async {
        // Lost for two frames: the dwell restarts when the face returns at frame 19 → switch at frame 24.
        assertCalls(await run([.look(from: 15, to: 17, yaw: 30), .lost(from: 17, to: 19), .look(from: 19, to: 45, yaw: 30)]),
                    [(24.0 / 15, "R")])
        // Lost for 1.2 s: dwell restarts when the face returns at frame 36 → switch at frame 41.
        assertCalls(await run([.look(from: 15, to: 18, yaw: 30), .lost(from: 18, to: 36), .look(from: 36, to: 60, yaw: 30)]),
                    [(41.0 / 15, "R")])
    }

    func test_FR_SAF_06_systemUIBlocksSwitching() async {
        assertCalls(await run([.look(from: 15, to: 45, yaw: 30)], blocked: "menu open"), [])
    }

    func test_FR_SAF_04_pausedNeverSwitches() async {
        assertCalls(await run([.look(from: 15, to: 45, yaw: 30)], paused: true), [])
    }

    func test_FR_SAF_08_confirmModeSwitchesOnlyOnFnDoubleTap() async {
        var t = Tuning()
        t.confirmMode = true
        assertCalls(await run([.look(from: 15, to: 45, yaw: 30)], tuning: t), [])
        assertCalls(await run([.key(1.4), .look(from: 15, to: 45, yaw: 30), .confirm(1.5)], tuning: t), [(1.5, "R")])
    }

    func test_FR_FOC_04_skippedFocusRetriesAfterOneSecond() async {
        // Skipped at frame 20; next attempt no earlier than 1 s later (frame 35).
        assertCalls(await run([.look(from: 15, to: 40, yaw: 30)], outcome: .skipped("excluded app")),
                    [(20.0 / 15, "R"), (35.0 / 15, "R")])
    }
}

/// FR-P2-01…04 timelines: two windows side by side on display C (1000×1000), left one focused.
final class RegionSwitchTests: XCTestCase {
    private let left = Region(id: "w1", windowID: 1, pid: 1, frame: CGRect(x: 0, y: 0, width: 500, height: 1000), isPane: false)
    private let right = Region(id: "w2", windowID: 2, pid: 2, frame: CGRect(x: 500, y: 0, width: 500, height: 1000), isPane: false)
    private var layout: ScreenLayout {
        ScreenLayout(display: "C", bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), regions: [left, right], focused: "w1")
    }
    private let harness = SwitchControllerTests()

    // Yaw 8 → gaze x 700: well inside the right window. Region dwell 0.45 s from frame 15 → frame 22.

    func test_FR_P2_01_lookingAtTheOtherWindowFocusesIt() async {
        let calls = await harness.runForTests([.look(from: 0, to: 15, yaw: -8), .look(from: 15, to: 45, yaw: 8)], layout: layout)
        XCTAssertEqual(calls.map(\.d), ["@w2"])
        XCTAssertEqual(calls.first?.t ?? 0, 22.0 / 15, accuracy: 1e-9)
    }

    func test_FR_P2_01_nearTheBorderStaysOnTheFocusedWindow() async {
        // Yaw 0.8 → x 520: inside the left window's 50 px hysteresis margin.
        let calls = await harness.runForTests([.look(from: 0, to: 60, yaw: 0.8)], layout: layout)
        XCTAssertTrue(calls.isEmpty, "\(calls)")
    }

    func test_FR_P2_04_typingHoldsWindowsWithNoOverride() async {
        // Typed at 0.9 s: nothing moves until the 3 s typing pause ends (3.9 s → frame 59).
        let calls = await harness.runForTests([.key(0.9), .look(from: 15, to: 75, yaw: 8)], layout: layout)
        XCTAssertEqual(calls.map(\.d), ["@w2"])
        XCTAssertEqual(calls.first?.t ?? 0, 59.0 / 15, accuracy: 1e-9)
    }

    func test_FR_P2_01_offWhenTheSettingIsOff() async {
        var t = Tuning()
        t.focusWithinScreen = false
        let calls = await harness.runForTests([.look(from: 15, to: 45, yaw: 8)], tuning: t, layout: layout)
        XCTAssertTrue(calls.isEmpty)
    }
}

extension SwitchControllerTests {
    func runForTests(_ steps: [Step], tuning: Tuning = Tuning(), layout: ScreenLayout? = nil) async -> [(t: Double, d: DisplayKey)] {
        await run(steps, tuning: tuning, layout: layout)
    }
}
