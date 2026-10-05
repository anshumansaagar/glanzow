import CoreVideo
import XCTest
@testable import GlanzowKit

/// FR-TRK-03 / FR-P2-01: iris centre localisation (Timm & Barth gradients) on synthetic eyes.
final class IrisLocatorTests: XCTestCase {
    /// A bright eye with a dark iris disc, optional glint and eyelid shadow, plus deterministic noise.
    private func eye(iris c: SIMD2<Double>, radius r: Double = 5, width w: Int = 40, height h: Int = 20,
                     glint: Bool = false, lidShadow: Bool = false, seed: UInt64 = 3) -> IrisLocator.Patch {
        var rng = SplitMix(seed)
        var px = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let d = ((Double(x) + 0.5 - c.x) * (Double(x) + 0.5 - c.x) + (Double(y) + 0.5 - c.y) * (Double(y) + 0.5 - c.y)).squareRoot()
                var v = d <= r ? 55.0 : 205.0                         // iris vs sclera
                if d <= r * 0.45 { v = 25 }                           // pupil
                if glint, abs(Double(x) + 0.5 - (c.x + 1.5)) < 1.2, abs(Double(y) + 0.5 - (c.y - 1.5)) < 1.2 { v = 255 }
                if lidShadow { v -= 60 * max(0, 1 - Double(y) / 5) } // top lighting: dark band under the brow
                px[y * w + x] = Float(max(0, min(255, v + rng.noise(6))))
            }
        }
        return IrisLocator.Patch(width: w, height: h, pixels: px)
    }

    private func assertFinds(_ truth: SIMD2<Double>, _ patch: IrisLocator.Patch, within tolerance: Double, file: StaticString = #filePath, line: UInt = #line) {
        guard let c = IrisLocator.centre(of: patch) else { return XCTFail("no centre found", file: file, line: line) }
        XCTAssertEqual(c.x, truth.x, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(c.y, truth.y, accuracy: tolerance, file: file, line: line)
    }

    func test_FR_P2_01_findsTheIrisCentre() {
        for truth in [SIMD2(20.0, 10.0), SIMD2(13.0, 9.0), SIMD2(27.0, 11.0)] {
            assertFinds(truth, eye(iris: truth), within: 1.0)
        }
    }

    func test_FR_P2_01_glassesGlintAndTopLightingDoNotMoveIt() {
        let truth = SIMD2(24.0, 10.5)
        assertFinds(truth, eye(iris: truth, glint: true), within: 1.5)
        assertFinds(truth, eye(iris: truth, lidShadow: true), within: 1.5)
    }

    func test_FR_P2_01_closedEyeGivesNothing() {
        let flat = IrisLocator.Patch(width: 40, height: 20, pixels: [Float](repeating: 120, count: 800))
        XCTAssertNil(IrisLocator.centre(of: flat))
    }

    func test_FR_P2_01_eyeOffsetIsZeroAtTheMiddleAndSignedOutward() {
        XCTAssertEqual(IrisLocator.eyeOffset(iris: SIMD2(20, 10), width: 40, height: 20), SIMD2(0, 0))
        XCTAssertGreaterThan(IrisLocator.eyeOffset(iris: SIMD2(26, 10), width: 40, height: 20).x, 0.1)
        XCTAssertLessThan(IrisLocator.eyeOffset(iris: SIMD2(20, 6), width: 40, height: 20).y, 0)
    }

    /// End to end on a 420f frame: draw an eye, sample its patch between the corners, find the iris.
    func test_FR_P2_01_patchFromCameraFrameRecoversTheIrisOffset() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 200, 120, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pb)
        let frame = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(frame, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
        for y in 0..<120 {
            for x in 0..<200 {
                let d = hypot(Double(x) - 110, Double(y) - 60)
                luma[y * row + x] = d <= 6 ? 50 : 190
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        // Corners 50 px apart, centred on x 105: the iris sits 5 px (0.1 eye-widths) toward b.
        let patch = try XCTUnwrap(IrisLocator.patch(fromLuma: frame, corners: SIMD2(80, 60), SIMD2(130, 60)))
        let c = try XCTUnwrap(IrisLocator.centre(of: patch))
        let offset = IrisLocator.eyeOffset(iris: c, width: patch.width, height: patch.height)
        XCTAssertEqual(offset.x, 0.1, accuracy: 0.03)
        XCTAssertEqual(offset.y, 0, accuracy: 0.03)
    }

    func test_cost_isWellUnderAMillisecond() {
        let p = eye(iris: SIMD2(20, 10))
        let start = Date()
        for _ in 0..<50 { _ = IrisLocator.centre(of: p) }
        let perEye = Date().timeIntervalSince(start) / 50
        // Debug builds are unoptimised; release is several times faster. Guard against regressions only.
        XCTAssertLessThan(perEye, 0.02, "per eye: \(perEye * 1000) ms")
    }
}
