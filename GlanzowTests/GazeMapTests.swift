import XCTest
@testable import GlanzowKit

/// FR-P2-01: per-display 2D regression from calibration points.
final class GazeMapTests: XCTestCase {
    /// Calibration-like data: 9 dot positions, 30 noisy samples each. True mapping:
    /// x = 0.5 + yaw/40 + 2·pupilX, y = 0.5 + pitch/30 + 2·pupilY; the head carries most of it.
    private func pairs(pupils: Bool, seed: UInt64 = 7) -> [(sample: PoseSample, target: SIMD2<Double>)] {
        var rng = SplitMix(seed)
        var out: [(sample: PoseSample, target: SIMD2<Double>)] = []
        for tx in [0.1, 0.5, 0.9] {
            for ty in [0.1, 0.5, 0.9] {
                for _ in 0..<30 {
                    let pupil = SIMD2(rng.noise(0.02), rng.noise(0.02))
                    let headX = tx - 0.5 - (pupils ? 2 * pupil.x : 0), headY = ty - 0.5 - (pupils ? 2 * pupil.y : 0)
                    let s = PoseSample(timestamp: 0, yaw: headX * 40 + rng.noise(0.3), pitch: headY * 30 + rng.noise(0.3),
                                       pupilOffset: pupils ? pupil : nil)
                    out.append((s, SIMD2(tx, ty)))
                }
            }
        }
        return out
    }

    func test_FR_P2_01_fitRecoversHeadAndEyeMapping() throws {
        let map = try XCTUnwrap(GazeMap.fit(pairs(pupils: true)))
        XCTAssertNotNil(map.eyes)
        XCTAssertLessThan(try XCTUnwrap(map.eyesError), 0.02)
        XCTAssertLessThan(try XCTUnwrap(map.eyesError), map.headError, "eyes explain what the head doesn't")
        let p = map.point(PoseSample(timestamp: 0, yaw: 8, pitch: -6, pupilOffset: SIMD2(0.01, 0)))
        XCTAssertEqual(p.x, 0.5 + 8.0 / 40 + 0.02, accuracy: 0.03)
        XCTAssertEqual(p.y, 0.5 - 6.0 / 30, accuracy: 0.03)
    }

    func test_FR_P2_01_headOnlyWhenNoPupils() throws {
        let map = try XCTUnwrap(GazeMap.fit(pairs(pupils: false)))
        XCTAssertNil(map.eyes)
        let p = map.point(PoseSample(timestamp: 0, yaw: -10, pitch: 3))
        XCTAssertEqual(p.x, 0.25, accuracy: 0.02)
        XCTAssertEqual(p.y, 0.6, accuracy: 0.02)
    }

    func test_FR_P2_01_tooFewDotsGiveNoMap() {
        let one = pairs(pupils: false).filter { $0.target == SIMD2(0.5, 0.5) }
        XCTAssertNil(GazeMap.fit(one))
    }

    func test_FR_P2_01_regionLookupIsFrontmostAndDistrustsBorders() {
        let back = Region(id: "w1", windowID: 1, pid: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), isPane: false)
        let front = Region(id: "w2", windowID: 2, pid: 2, frame: CGRect(x: 500, y: 0, width: 500, height: 1000), isPane: false)
        let paneA = Region(id: "w1p0", windowID: 1, pid: 1, frame: CGRect(x: 0, y: 0, width: 250, height: 1000), isPane: true)
        let layout = ScreenLayout(display: "C", bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), regions: [front, paneA, back], focused: nil)
        XCTAssertEqual(layout.region(at: CGPoint(x: 700, y: 500), inset: 25)?.id, "w2")   // occluding window wins
        XCTAssertEqual(layout.region(at: CGPoint(x: 100, y: 500), inset: 25)?.id, "w1p0") // pane before its window
        XCTAssertEqual(layout.region(at: CGPoint(x: 380, y: 500), inset: 25)?.id, "w1")   // window area outside panes
        XCTAssertNil(layout.region(at: CGPoint(x: 510, y: 500), inset: 25))               // too close to a border
    }
}

/// Deterministic noise for tests.
struct SplitMix {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
    /// Uniform in ±amplitude·√3, so the standard deviation is `amplitude`.
    mutating func noise(_ amplitude: Double) -> Double { (next() * 2 - 1) * amplitude * 3.0.squareRoot() }
}

/// FR-P2-02: the pane shortcut points toward the target pane.
final class PaneKeysTests: XCTestCase {
    func test_FR_P2_02_arrowPointsTowardTheTargetPane() {
        let c = CGPoint(x: 500, y: 500)
        XCTAssertEqual(PaneKeys.arrow(toward: CGPoint(x: 900, y: 520), from: c), 124) // right
        XCTAssertEqual(PaneKeys.arrow(toward: CGPoint(x: 100, y: 450), from: c), 123) // left
        XCTAssertEqual(PaneKeys.arrow(toward: CGPoint(x: 520, y: 900), from: c), 125) // below (y grows down)
        XCTAssertEqual(PaneKeys.arrow(toward: CGPoint(x: 480, y: 100), from: c), 126) // above
    }

    func test_FR_P2_02_knownAppsHaveShortcutsOthersDont() {
        XCTAssertNotNil(PaneKeys(bundle: "com.googlecode.iterm2"))
        XCTAssertNotNil(PaneKeys(bundle: "com.microsoft.VSCode"))
        XCTAssertNil(PaneKeys(bundle: "com.apple.Safari"))
        XCTAssertNil(PaneKeys(bundle: nil))
    }
}

/// FR-P2-01 implicit calibration: clicks during real use pull the gaze map toward how the user looks.
final class ClickRefitTests: XCTestCase {
    func test_FR_P2_01_clicksCorrectABiasedCalibration() throws {
        // Calibration taught x = 0.5 + yaw/40; in real use this user's x is 0.1 further right.
        func pair(yaw: Double, x: Double) -> GazePair { GazePair(PoseSample(timestamp: 0, yaw: yaw, pitch: 0), target: SIMD2(x, 0.5)) }
        let calibration = stride(from: -16.0, through: 16.0, by: 2).flatMap { y in [pair(yaw: y, x: 0.5 + y / 40), pair(yaw: y, x: 0.5 + y / 40)] }
        let clicks = stride(from: -16.0, through: 16.0, by: 1.5).map { pair(yaw: $0, x: 0.6 + $0 / 40) }
        let before = try XCTUnwrap(GazeMap.fit(calibration: calibration, clicks: []))
        let after = try XCTUnwrap(GazeMap.fit(calibration: calibration, clicks: clicks))
        let s = PoseSample(timestamp: 0, yaw: 4, pitch: 0)
        XCTAssertEqual(before.point(s).x, 0.6, accuracy: 0.01)
        XCTAssertGreaterThan(after.point(s).x, 0.65, "moved most of the way toward the clicks (0.7)")
    }

    func test_storedPairsSurviveSanitising() throws {
        var m = DisplayModel(key: "k", name: "A", mean: .zero, covariance: Cov2(xx: 9, xy: 0, yy: 9), meanFaceScale: 0.2, cameraID: "c", sampleCount: 20)
        m.clickPairs = [GazePair(PoseSample(timestamp: 0, yaw: 1, pitch: 2, pupilOffset: SIMD2(0.1, 0)), target: SIMD2(0.3, 0.4))]
        XCTAssertEqual(CalibrationStore.sanitized(m)?.clickPairs?.count, 1)
        m.clickPairs = [GazePair(PoseSample(timestamp: 0, yaw: .infinity, pitch: 2), target: SIMD2(0.3, 0.4))]
        XCTAssertNil(CalibrationStore.sanitized(m)?.clickPairs)
    }
}
