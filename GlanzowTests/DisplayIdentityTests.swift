import XCTest
@testable import GlanzowKit

/// FR-CAL-04, §7 "two identical monitor models" and "display rearranged".
final class DisplayIdentityTests: XCTestCase {
    private func raw(_ id: CGDirectDisplayID, serial: UInt32, x: CGFloat, model: UInt32 = 41_234) -> RawDisplay {
        RawDisplay(id: id, vendor: 4268, model: model, serial: serial,
                   bounds: CGRect(x: x, y: 0, width: 1920, height: 1080), name: "DELL E2421HN", isBuiltin: false)
    }

    func test_FR_CAL_04_replugMapsToSameCalibration() throws {
        let before = DisplayIdentity.assignKeys([raw(5, serial: 777, x: 0)])
        let after = DisplayIdentity.assignKeys([raw(9, serial: 777, x: 0)]) // new CGDirectDisplayID after re-plug
        XCTAssertEqual(before[0].key, after[0].key)

        let url = FileManager.default.temporaryDirectory.appending(path: "id-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CalibrationStore(url: url)
        store.set([DisplayModel(key: before[0].key, name: "DELL", mean: SIMD2(20, 0), covariance: Cov2(xx: 9, xy: 0, yy: 9),
                                meanFaceScale: 0.2, cameraID: "cam", sampleCount: 30)])
        XCTAssertEqual(store.valid(for: after, cameraID: "cam").first?.mean, SIMD2(20, 0))
    }

    func test_FR_CAL_04_identicalModelsWithSerialsAreDistinctAndSurviveRearrangement() {
        let keys = DisplayIdentity.assignKeys([raw(1, serial: 111, x: 0), raw(2, serial: 222, x: 1920)])
        XCTAssertNotEqual(keys[0].key, keys[1].key)
        XCTAssertFalse(keys.contains(where: \.ambiguous))
        let swapped = DisplayIdentity.assignKeys([raw(1, serial: 111, x: 1920), raw(2, serial: 222, x: 0)])
        XCTAssertEqual(swapped.map(\.key), keys.map(\.key))
    }

    func test_FR_CAL_04_identicalModelsWithoutSerialFallBackToPositionAndWarn() {
        let keys = DisplayIdentity.assignKeys([raw(7, serial: 0, x: 1920), raw(3, serial: 0, x: 0)])
        XCTAssertTrue(keys.allSatisfy(\.ambiguous))
        XCTAssertEqual(keys.first { $0.id == 3 }?.key, "4268-41234-0-p0") // leftmost
        XCTAssertEqual(keys.first { $0.id == 7 }?.key, "4268-41234-0-p1")
    }

    func test_FR_CAL_04_singleDisplayWithoutSerialIsNotAmbiguous() {
        let keys = DisplayIdentity.assignKeys([raw(1, serial: 0, x: 0), raw(2, serial: 0, x: 1920, model: 99)])
        XCTAssertFalse(keys.contains(where: \.ambiguous))
        XCTAssertEqual(Set(keys.map(\.key)).count, 2)
    }
}
