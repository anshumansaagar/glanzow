import XCTest
@testable import GlanzowKit

/// FR-LRN-01…03 and FR-TRK-08.
final class LearningTests: XCTestCase {
    private let models = [
        DisplayModel(key: "C", name: "C", mean: SIMD2(0, 0), covariance: Cov2(xx: 36, xy: 0, yy: 36), meanFaceScale: 0.2, cameraID: "", sampleCount: 50),
        DisplayModel(key: "R", name: "R", mean: SIMD2(30, 0), covariance: Cov2(xx: 36, xy: 0, yy: 36), meanFaceScale: 0.2, cameraID: "", sampleCount: 50),
    ]
    private var classifier: MahalanobisClassifier { MahalanobisClassifier(models: models) }

    func test_FR_LRN_02_clickNudgesClickedDisplayModel() throws {
        var l = LearningEngine()
        l.observe(.pose(PoseSample(timestamp: 10, yaw: 5, pitch: 0)))
        let u = l.click(at: 10.1, on: "C", classifier: classifier, model: models[0])
        XCTAssertEqual(try XCTUnwrap(u.model).mean.x, 0.1, accuracy: 1e-9) // 0.98·0 + 0.02·5
    }

    func test_FR_LRN_01_noLearningWithoutAFreshFaceOrRightAfterASwitch() {
        var l = LearningEngine()
        l.observe(.pose(PoseSample(timestamp: 10, yaw: 5, pitch: 0)))
        XCTAssertNil(l.click(at: 10.5, on: "C", classifier: classifier, model: models[0]).model, "pose too old")
        l.observe(.pose(PoseSample(timestamp: 11, yaw: 5, pitch: 0)))
        l.noteSwitch(at: 10.8)
        XCTAssertNil(l.click(at: 11.1, on: "C", classifier: classifier, model: models[0]).model, "within 500 ms of a switch")
        XCTAssertTrue(l.outcomes.isEmpty)
    }

    func test_FR_LRN_01_clickWhileLookingElsewhereDoesNotTeach() {
        var l = LearningEngine()
        l.observe(.pose(PoseSample(timestamp: 10, yaw: 30, pitch: 0))) // looking at R
        let u = l.click(at: 10.1, on: "C", classifier: classifier, model: models[0])
        XCTAssertNil(u.model)
        XCTAssertEqual(l.outcomes, [false])
    }

    func test_FR_LRN_03_alertOnceWhenMoreThan30PercentOfLast50Disagree() {
        var l = LearningEngine()
        var alerts: [Double] = []
        for i in 0..<120 {
            let t = Double(i)
            let yaw = i % 5 < 2 ? 30.0 : 0 // 40% of clicks on C are made while facing R
            l.observe(.pose(PoseSample(timestamp: t, yaw: yaw, pitch: 0)))
            if let a = l.click(at: t + 0.05, on: "C", classifier: classifier, model: models[0]).driftAlert { alerts.append(a) }
        }
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0], 0.4, accuracy: 1e-9)
        XCTAssertEqual(l.outcomes.count, 50)
    }

    func test_FR_TRK_08_steadyThenIdleThenMovementRestores15() {
        var g = FrameRateGovernor()
        var changes: [(Double, Int)] = []
        for k in 0..<(35 * 15) { // 35 s still, small jitter under 2°
            let t = Double(k) / 15
            if let f = g.update(.pose(PoseSample(timestamp: t, yaw: k % 2 == 0 ? 0.5 : -0.5, pitch: 0))) { changes.append((t, f)) }
        }
        XCTAssertEqual(changes.map(\.1), [8, 5])
        XCTAssertEqual(changes[0].0, 1.5, accuracy: 0.1)
        XCTAssertEqual(changes[1].0, 30, accuracy: 0.1)
        XCTAssertEqual(g.update(.pose(PoseSample(timestamp: 36, yaw: 10, pitch: 0))), 15)
        XCTAssertNil(g.update(.pose(PoseSample(timestamp: 36.1, yaw: 10.5, pitch: 0))), "still moving: stays at 15")
    }
}

/// The learned settle time (adaptive dwell).
final class SettleLearnerTests: XCTestCase {
    func test_undoAndBouncesSlowItDownUseSpeedsItUpWithinBounds() {
        var l = SettleLearner(dwell: 0.3)
        l.switched(at: 0); l.undone()
        XCTAssertEqual(l.dwell, 0.34, accuracy: 1e-9)
        l.switched(at: 20); l.bounced(at: 21)
        XCTAssertEqual(l.dwell, 0.355, accuracy: 1e-9)
        for k in 0..<200 { let t = 100 + Double(k) * 30; l.switched(at: t); l.used(at: t + 1) }
        XCTAssertEqual(l.dwell, 0.25, accuracy: 1e-9, "never below the floor")
        for _ in 0..<50 { l.undone() }
        XCTAssertEqual(l.dwell, 0.6, accuracy: 1e-9, "never above the ceiling")
    }

    func test_rapidBurstsTeachNothing() {
        var l = SettleLearner(dwell: 0.3)
        for t in [0.0, 1, 2, 3] { l.switched(at: t) }
        l.bounced(at: 3.5)
        l.used(at: 3.6)
        XCTAssertEqual(l.dwell, 0.3, accuracy: 1e-9)
    }
}
