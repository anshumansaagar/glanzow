import XCTest
@testable import GlanceFocusKit

final class PreferencesTests: XCTestCase {
    func test_settings_defaultsMatchSpecTable() {
        let d = UserDefaults(suiteName: "test-\(UUID())")!
        Pref.register(d)
        let t = Tuning(d)
        XCTAssertEqual(t.dwell, 0.3, accuracy: 1e-9)
        XCTAssertEqual(t.hysteresisFactor, 1.2, accuracy: 1e-9) // FR-CLS-03 default
        XCTAssertEqual(t.typingPause, 3.0)
        XCTAssertEqual(t.mouseQuiet, 1.5)
        XCTAssertEqual(t.rejectThreshold, 4.0)
        XCTAssertFalse(t.confirmMode)
    }

    func test_settings_outOfRangeValuesAreClamped() {
        let d = UserDefaults(suiteName: "test-\(UUID())")!
        Pref.register(d)
        d.set(5000.0, forKey: Pref.dwellMs)
        d.set(0.01, forKey: Pref.typingPause)
        d.set(false, forKey: Pref.waitWhileTyping)
        d.set(3.0, forKey: Pref.headTurn)
        let t = Tuning(d)
        XCTAssertEqual(t.dwell, 1.0, accuracy: 1e-9)
        XCTAssertNil(t.typingPause)
        XCTAssertEqual(t.hysteresisFactor, 1.4, accuracy: 1e-9)
    }
}
