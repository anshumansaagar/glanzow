import XCTest
@testable import GlanzowKit

/// FR-TRK-04. Reference values come from an independent Python port of the Casiez et al.
/// reference implementation, run with the §6.2 defaults (min cutoff 1 Hz, beta 0.05, d cutoff 1 Hz)
/// at 15 fps.
final class OneEuroFilterTests: XCTestCase {
    private func run(_ xs: [Double]) -> [Double] {
        var f = OneEuroFilter(minCutoff: 1.0, beta: 0.05, dCutoff: 1.0)
        return xs.indices.map { f(xs[$0], at: Double($0) / 15) }
    }

    func test_FR_TRK_04_stepResponseMatchesReference() {
        let out = run(Array(repeating: 0, count: 10) + Array(repeating: 10, count: 20))
        let reference: [Int: Double] = [10: 5.738033257391884, 11: 8.272977008952484, 12: 9.255054410896502,
                                        15: 9.900247753600823, 20: 9.989901356202566, 29: 9.999618635080672]
        for (k, v) in reference { XCTAssertEqual(out[k], v, accuracy: 1e-9, "sample \(k)") }
    }

    func test_FR_TRK_04_noiseResponseMatchesReferenceAndReducesJitter() {
        let xs: [Double] = (0..<60).map { k in
            let x = Double(k)
            return 5 + sin(x * 1.7) * 0.8 + cos(x * 0.3) * 0.2
        }
        let out = run(xs)
        let reference: [Int: Double] = [1: 5.458531534679651, 5: 5.302066515068528, 30: 4.921425336413352, 59: 4.843023891003817]
        for (k, v) in reference { XCTAssertEqual(out[k], v, accuracy: 1e-9, "sample \(k)") }
        func std(_ a: ArraySlice<Double>) -> Double {
            let m = a.reduce(0, +) / Double(a.count)
            return (a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count)).squareRoot()
        }
        XCTAssertLessThan(std(out[20...]), 0.4 * std(xs[20...]))
    }

    func test_FR_TRK_04_firstSamplePassesThroughAndRepeatedTimestampIsHeld() {
        var f = OneEuroFilter()
        XCTAssertEqual(f(3, at: 1), 3)
        XCTAssertEqual(f(9, at: 1), 3)
    }

    func test_FR_TRK_04_smootherRestartsAfterFaceLoss() {
        var s = PoseSmoother()
        _ = s(PoseSample(timestamp: 0, yaw: 0, pitch: 0))
        _ = s(PoseSample(timestamp: 0.07, yaw: 0, pitch: 0))
        let back = s(PoseSample(timestamp: 3, yaw: 30, pitch: -5))
        XCTAssertEqual(back.yaw, 30)
        XCTAssertEqual(back.pitch, -5)
    }
}
