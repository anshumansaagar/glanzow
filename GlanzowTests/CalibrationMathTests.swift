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

    func test_regularisationAddsOneDegreeSquaredAndInverts() throws {
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

    func test_mirrorCheck_yawMustBeMonotonicLeftToRight() {
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
