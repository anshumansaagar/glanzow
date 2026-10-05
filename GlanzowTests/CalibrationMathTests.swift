import XCTest
@testable import GlanzowKit

/// FR-CAL-02, 03, 06; §6.3 regularisation; §6.6 learning update.
final class CalibrationMathTests: XCTestCase {
    /// 16 samples around (10, −5): yaw offsets −3, −1, 1, 3 repeating; pitch offsets ±2 alternating.
    private let samples: [PoseSample] = (0..<16).map { i in
        let a = [-3.0, -1, 1, 3][i % 4]
        let b = i % 2 == 0 ? 2.0 : -2.0
        return PoseSample(timestamp: Double(i), yaw: 10 + a, pitch: -5 + b, faceScale: 0.2 + 0.01 * Double(i % 2))
    }

    func test_FR_CAL_03_fitGivesMeanCovarianceAndFaceScale() throws {
        let m = try XCTUnwrap(DisplayModel.fit(key: "k", name: "A", cameraID: "cam", samples: samples))
        XCTAssertEqual(m.mean.x, 10, accuracy: 1e-12)
        XCTAssertEqual(m.mean.y, -5, accuracy: 1e-12)
        XCTAssertEqual(m.covariance.xx, 80.0 / 15, accuracy: 1e-12) // unbiased (n − 1)
        XCTAssertEqual(m.covariance.yy, 64.0 / 15, accuracy: 1e-12)
        XCTAssertEqual(m.covariance.xy, -32.0 / 15, accuracy: 1e-12)
        XCTAssertEqual(m.meanFaceScale, 0.205, accuracy: 1e-12)
        XCTAssertEqual(m.cameraID, "cam")
        XCTAssertEqual(m.sampleCount, 16)
    }

    func test_FR_CAL_02_tooFewSamplesGiveNoModel() {
        XCTAssertNil(DisplayModel.fit(key: "k", name: "A", cameraID: "c", samples: Array(samples.prefix(DisplayModel.minSamples - 1))))
    }

    func test_FR_CLS_01_regularisationAddsOneDegreeSquaredAndInverts() throws {
        let c = Cov2(xx: 4, xy: 2, yy: 1) // singular: det 0
        XCTAssertNil(c.inverse)
        let r = c.regularized()
        XCTAssertEqual(r, Cov2(xx: 5, xy: 2, yy: 2))
        let inv = try XCTUnwrap(r.inverse)
        // r · inv = identity
        XCTAssertEqual(r.xx * inv.xx + r.xy * inv.xy, 1, accuracy: 1e-12)
        XCTAssertEqual(r.xx * inv.xy + r.xy * inv.yy, 0, accuracy: 1e-12)
        XCTAssertEqual(r.xy * inv.xy + r.yy * inv.yy, 1, accuracy: 1e-12)
    }

    func test_FR_LRN_02_learnMovesMeanTwoPercentAndUpdatesCovariance() {
        var m = DisplayModel(key: "k", name: "A", mean: .zero, covariance: Cov2(xx: 4, xy: 0, yy: 4),
                             meanFaceScale: 0.2, cameraID: "c", sampleCount: 20)
        m.learn(SIMD2(10, 0))
        XCTAssertEqual(m.mean.x, 0.2, accuracy: 1e-12)
        XCTAssertEqual(m.mean.y, 0, accuracy: 1e-12)
        XCTAssertEqual(m.covariance.xx, 0.98 * (4 + 0.02 * 100), accuracy: 1e-12)
        XCTAssertEqual(m.covariance.xy, 0, accuracy: 1e-12)
        XCTAssertEqual(m.covariance.yy, 0.98 * 4, accuracy: 1e-12)
    }

    func test_FR_CAL_03_storePersistsAndFiltersByCamera() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cal-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let m = try XCTUnwrap(DisplayModel.fit(key: "1-2-3", name: "A", cameraID: "cam", samples: samples))
        CalibrationStore(url: url).set([m])

        let reloaded = CalibrationStore(url: url)
        XCTAssertEqual(reloaded.model("1-2-3")?.mean, m.mean)
        XCTAssertEqual(reloaded.model("1-2-3")?.covariance, m.covariance)
        let d = DisplayInfo(id: 1, key: "1-2-3", name: "A", bounds: .zero, isBuiltin: false)
        XCTAssertEqual(reloaded.valid(for: [d], cameraID: "cam").count, 1)
        XCTAssertEqual(reloaded.uncalibrated([d], cameraID: "other camera").map(\.key), ["1-2-3"])
    }

    func test_FR_CAL_05_mirrorCheck_yawMustBeMonotonicLeftToRight() {
        func pair(_ x: CGFloat, _ yaw: Double) -> (display: DisplayInfo, model: DisplayModel) {
            (DisplayInfo(id: 0, key: "\(x)", name: "", bounds: CGRect(x: x, y: 0, width: 1920, height: 1080), isBuiltin: false),
             DisplayModel(key: "\(x)", name: "", mean: SIMD2(yaw, 0), covariance: Cov2(xx: 1, xy: 0, yy: 1),
                          meanFaceScale: 0.2, cameraID: "", sampleCount: 20))
        }
        XCTAssertTrue(CalibrationStore.yawOrderConsistent([pair(0, -30), pair(1920, 0), pair(3840, 30)]))
        XCTAssertTrue(CalibrationStore.yawOrderConsistent([pair(0, 30), pair(1920, 0), pair(3840, -30)]))
        XCTAssertFalse(CalibrationStore.yawOrderConsistent([pair(0, -30), pair(1920, 30), pair(3840, 0)]))
    }

    func test_FR_CAL_01_dotPathCoversCentreCornersAndSharedEdges() {
        let a = DisplayInfo(id: 1, key: "a", name: "A", bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), isBuiltin: false)
        let b = DisplayInfo(id: 2, key: "b", name: "B", bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080), isBuiltin: false)
        XCTAssertEqual(CalibrationOverlay.points(for: a, among: [a]).count, 5)
        let pa = CalibrationOverlay.points(for: a, among: [a, b])
        XCTAssertEqual(pa.count, 7)
        XCTAssertEqual(pa.first, CGPoint(x: 960, y: 540))
        XCTAssertEqual(pa.filter { $0.x == 1860 && $0.y > 60 && $0.y < 1020 }.count, 2, "two points on the shared right edge")
        let pb = CalibrationOverlay.points(for: b, among: [a, b])
        XCTAssertEqual(pb.filter { $0.x == 1980 && $0.y > 60 && $0.y < 1020 }.count, 2, "two points on the shared left edge")
        XCTAssertTrue(pb.allSatisfy { b.bounds.contains($0) })
    }
}

/// Security: a calibration file is outside the app's control, so loading must never trust it.
final class CalibrationFileSafetyTests: XCTestCase {
    private func model(gaze: GazeMap? = nil, mean: SIMD2<Double> = SIMD2(0, 0), xx: Double = 9) -> DisplayModel {
        DisplayModel(key: "k", name: "A", mean: mean, covariance: Cov2(xx: xx, xy: 0, yy: 9), meanFaceScale: 0.2,
                     cameraID: "c", sampleCount: 20, gaze: gaze)
    }

    func test_malformedNumbersRejectTheModel() {
        XCTAssertNil(CalibrationStore.sanitized(model(mean: SIMD2(.nan, 0))))
        XCTAssertNil(CalibrationStore.sanitized(model(xx: -4)))
        XCTAssertNil(CalibrationStore.sanitized(model(mean: SIMD2(1e9, 0))))
        XCTAssertNotNil(CalibrationStore.sanitized(model()))
    }

    func test_misshapenGazeMapIsDroppedButModelKept() throws {
        let bad = GazeMap(head: [[0.5, 0.1]], eyes: nil, headError: 0.1, eyesError: nil) // one short row
        let kept = try XCTUnwrap(CalibrationStore.sanitized(model(gaze: bad)))
        XCTAssertNil(kept.gaze)
        let good = GazeMap(head: [[0.5, 0.1, 0], [0.5, 0, 0.1]], eyes: nil, headError: 0.1, eyesError: nil)
        XCTAssertNotNil(CalibrationStore.sanitized(model(gaze: good))?.gaze)
    }

    func test_garbageFileLoadsAsUncalibratedWithoutCrashing() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "bad-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"version":1,"models":[{"key":"k","name":"A","mean":[0],"covariance":{}}]}"#.utf8).write(to: url)
        XCTAssertTrue(CalibrationStore(url: url).all.isEmpty)
    }
}

/// Trace-the-gleam calibration (smooth pursuit).
final class PursuitTests: XCTestCase {
    private let a = DisplayInfo(id: 1, key: "a", name: "A", bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), isBuiltin: false)
    private let b = DisplayInfo(id: 2, key: "b", name: "B", bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080), isBuiltin: false)

    func test_FR_CAL_01_tourPassesEveryCornerAndSharedEdgeAndCrossesTheMiddle() {
        let path = CalibrationOverlay.pursuitPath(for: a, among: [a, b])
        for corner in [CGPoint(x: 60, y: 60), CGPoint(x: 1860, y: 60), CGPoint(x: 1860, y: 1020), CGPoint(x: 60, y: 1020)] {
            XCTAssertTrue(path.contains(corner), "missing corner \(corner)")
        }
        // Two points on the shared right edge, besides the middle crossing at y 540.
        XCTAssertEqual(path.filter { $0.x == 1860 && $0.y > 60 && $0.y < 1020 && $0.y != 540 }.count, 2)
        XCTAssertTrue(path.contains(CGPoint(x: 60, y: 540)) && path.contains(CGPoint(x: 1860, y: 540)), "crosses the middle")
    }

    func test_fixedSpotsStayOnScreenAndEveryMoveIsALongJump() {
        let spots = CalibrationOverlay.fixedSpots(in: b)
        XCTAssertEqual(Set(spots.map { "\($0.x),\($0.y)" }).count, 9, "nine different spots")
        XCTAssertTrue(spots.allSatisfy { b.bounds.insetBy(dx: 100, dy: 100).contains($0) })
        for (p, q) in zip(spots, spots.dropFirst()) {
            XCTAssertGreaterThan(hypot((q.x - p.x) / 1920, (q.y - p.y) / 1080), 0.39, "\(p) → \(q) is a small correction, not a jump")
        }
        XCTAssertTrue(zip(spots, spots.dropFirst()).contains { $0.x == $1.x && abs($1.y - $0.y) >= 0.8 * 1080 }, "a full-height jump")
    }

    func test_spotPairsKeepOnlySamplesTakenOnceASpotHadSettled() {
        let spots: [(shown: ClosedRange<TimeInterval>, target: SIMD2<Double>)] = [(1.35...1.9, SIMD2(0.1, 0.1)), (2.25...2.8, SIMD2(0.9, 0.9))]
        let samples = [1.2, 1.4, 1.8, 2.0, 2.3, 2.9].map { PoseSample(timestamp: $0, yaw: 0, pitch: 0) }
        let pairs = CalibrationOverlay.spotPairs(samples, spots)
        XCTAssertEqual(pairs.map(\.sample.timestamp), [1.4, 1.8, 2.3])
        XCTAssertEqual(pairs.map(\.target), [SIMD2(0.1, 0.1), SIMD2(0.1, 0.1), SIMD2(0.9, 0.9)])
    }

    func test_polylineWalksByDistanceAndFindsCorners() {
        let line = Polyline([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50)])
        XCTAssertEqual(line.length, 150)
        XCTAssertEqual(line.position(at: 50), CGPoint(x: 50, y: 0))
        XCTAssertEqual(line.position(at: 125), CGPoint(x: 100, y: 25))
        XCTAssertEqual(line.corners, [100])
    }

    func test_FR_CAL_02_pairsLagTheTargetAndSkipCatchUpAndCorners() {
        let line = Polyline([CGPoint(x: 100, y: 100), CGPoint(x: 1100, y: 100), CGPoint(x: 1100, y: 600)])
        let speed: CGFloat = 500 // px/s: corner at t = 2 s
        let samples = stride(from: 0.0, to: 3.0, by: 1.0 / 15).map { PoseSample(timestamp: 10 + $0, yaw: 0, pitch: 0) }
        let pairs = CalibrationOverlay.pursuitPairs(samples, rest: 0...1, centre: .zero, tour: 10...13, path: line, speed: speed, in: a)
        let times = pairs.map(\.sample.timestamp)
        XCTAssertFalse(times.contains { $0 < 10.5 - 1e-9 }, "first 0.4 s (+0.1 lag) skipped while the eyes catch up")
        XCTAssertFalse(times.contains { abs($0 - 0.1 - 12) < 0.25 }, "no pairs near the corner")
        // A sample at 11.2 s pairs with where the gleam was at 11.1 s: 550 px along from x 100 → x 650.
        let at = pairs.first { abs($0.sample.timestamp - 11.2) < 1e-6 }
        XCTAssertEqual(at?.target.x ?? -1, 650.0 / 1920, accuracy: 1e-6)
    }
}
