import XCTest
@testable import GlanzowKit

/// FR-CLS-01, 02, 03; FR-CAL-08 / §6.5. Three synthetic clusters 30° apart in yaw.
final class DisplayClassifierTests: XCTestCase {
    private func model(_ key: String, yaw: Double) -> DisplayModel {
        DisplayModel(key: key, name: key, mean: SIMD2(yaw, 0), covariance: Cov2(xx: 36, xy: 0, yy: 36),
                     meanFaceScale: 0.2, cameraID: "c", sampleCount: 50)
    }
    private lazy var classifier = MahalanobisClassifier(models: [model("L", yaw: -30), model("C", yaw: 0), model("R", yaw: 30)])
    private func at(_ yaw: Double, _ pitch: Double = 0, scale: Double = 0.2) -> PoseSample {
        PoseSample(timestamp: 0, yaw: yaw, pitch: pitch, faceScale: scale)
    }

    func test_FR_CLS_01_nearestDisplayByMahalanobisDistance() {
        XCTAssertEqual(classifier.classify(at(-28, 1), current: nil), .candidate("L"))
        XCTAssertEqual(classifier.classify(at(3, -2), current: nil), .candidate("C"))
        XCTAssertEqual(classifier.classify(at(26, 4), current: nil), .candidate("R"))
        let d = classifier.distances(at(30))
        XCTAssertEqual(d.first?.key, "R")
        XCTAssertEqual(d.first?.distance ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(d[1].distance, 30 / 37.0.squareRoot(), accuracy: 1e-12) // regularised σ² = 37
    }

    func test_FR_CLS_02_farFromEveryDisplayIsOffScreen() {
        XCTAssertEqual(classifier.classify(at(0, -35), current: "C"), .offScreen) // looking down at a phone
        XCTAssertEqual(classifier.classify(at(70, 0), current: "R"), .offScreen)
        XCTAssertEqual(MahalanobisClassifier(models: []).classify(at(0), current: nil), .offScreen)
    }

    func test_FR_CLS_03_hysteresisHoldsCurrentNearTheBoundary() {
        // At 16°, R is nearer (2.30 vs 2.63) but not by 1.2×, so stay on C.
        XCTAssertEqual(classifier.classify(at(16), current: "C"), .stay)
        XCTAssertEqual(classifier.classify(at(16), current: nil), .candidate("R"))
        // At 18°, R wins by more than the margin.
        XCTAssertEqual(classifier.classify(at(18), current: "C"), .candidate("R"))
        // Coming back the other way needs the same margin.
        XCTAssertEqual(classifier.classify(at(14), current: "R"), .stay)
        XCTAssertEqual(classifier.classify(at(1), current: "C"), .candidate("C"))
    }

    func test_FR_CLS_03_headTurnSettingNeverGoesBelowTheSpecFloor() {
        XCTAssertEqual(Tuning.hysteresisFactor(headTurn: 0), 1.2, accuracy: 1e-12)
        XCTAssertEqual(Tuning.hysteresisFactor(headTurn: 1), 1.6, accuracy: 1e-12)
        let loosest = MahalanobisClassifier(models: [model("C", yaw: 0), model("R", yaw: 30)],
                                            hysteresisFactor: Tuning.hysteresisFactor(headTurn: 0))
        XCTAssertEqual(loosest.classify(at(16), current: "C"), .stay)
    }

    func test_FR_CAL_08_leaningInShrinksOffsetsBackToCalibrationDistance() {
        // Neutral pose is the centre of the means (0, 0); calibrated face scale 0.2.
        XCTAssertEqual(classifier.compensated(at(42, 0, scale: 0.28)).x, 30, accuracy: 1e-9)  // ratio 1.4
        XCTAssertEqual(classifier.compensated(at(42, 0, scale: 0.40)).x, 30, accuracy: 1e-9)  // clamped to 1.4
        XCTAssertEqual(classifier.compensated(at(21, 0, scale: 0.14)).x, 30, accuracy: 1e-9)  // leaning back, ratio 0.7
        XCTAssertEqual(classifier.compensated(at(21, 0, scale: 0.20)).x, 21, accuracy: 1e-9)  // same distance: unchanged
        XCTAssertEqual(classifier.classify(at(42, 0, scale: 0.28), current: "C"), .candidate("R"))
    }
}
