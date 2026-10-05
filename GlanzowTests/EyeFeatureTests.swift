import XCTest
@testable import GlanzowKit

final class EyeFeatureTests: XCTestCase {
    // MARK: Eye breaks

    func test_eyeBreakComesDueAfterTwentyMinutesOfScreenTime() {
        var timer = EyeBreakTimer()
        var due: Double?
        for k in 0...(21 * 60 * 2) { // two updates a second, always on screen
            if timer.update(at: Double(k) / 2, onScreen: true) == .due { due = Double(k) / 2; break }
        }
        XCTAssertEqual(due ?? -1, 20 * 60, accuracy: 0.6)
    }

    func test_eyeBreakCompletesByLookingAwayAndNaturalBreaksReset() {
        var timer = EyeBreakTimer()
        timer.workPeriod = 60
        var t = 0.0
        func run(_ seconds: Double, onScreen: Bool) -> [EyeBreakTimer.Event] {
            var events: [EyeBreakTimer.Event] = []
            for _ in 0..<Int(seconds * 2) { t += 0.5; if let e = timer.update(at: t, onScreen: onScreen) { events.append(e) } }
            return events
        }
        _ = run(1, onScreen: true)
        _ = run(40, onScreen: true)
        _ = run(25, onScreen: false)             // a natural break resets the clock
        XCTAssertEqual(timer.screenTime, 0, accuracy: 0.6)
        XCTAssertEqual(run(61, onScreen: true), [.due])
        XCTAssertEqual(run(10, onScreen: false), [])
        _ = run(3, onScreen: true)               // a glance back doesn't lose progress
        XCTAssertEqual(run(10.5, onScreen: false), [.done])
        XCTAssertEqual(timer.state, .working)
    }

    func test_eyeBreakSnoozeAsksAgainInFiveMinutes() {
        var timer = EyeBreakTimer()
        timer.snooze()
        XCTAssertEqual(timer.screenTime, 15 * 60)
    }

    // MARK: Privacy guard

    func test_privacyGuardVeilsAfterTwoSecondsAndLiftsWhenTheyLeave() {
        var g = PrivacyGuard()
        XCTAssertFalse(g.update(at: 0, watchers: 1))
        XCTAssertFalse(g.update(at: 1.9, watchers: 1))
        XCTAssertTrue(g.update(at: 2.0, watchers: 1))
        XCTAssertTrue(g.veiled)
        XCTAssertFalse(g.update(at: 3, watchers: 0))
        XCTAssertTrue(g.update(at: 4.5, watchers: 0))
        XCTAssertFalse(g.veiled)
    }

    func test_privacyGuardDismissedStaysDownUntilTheWatcherLeaves() {
        var g = PrivacyGuard()
        _ = g.update(at: 0, watchers: 1)
        _ = g.update(at: 2, watchers: 1)
        g.dismiss()
        XCTAssertFalse(g.update(at: 10, watchers: 1), "same watcher: stays dismissed")
        _ = g.update(at: 11, watchers: 0)
        _ = g.update(at: 13, watchers: 0)        // they left
        _ = g.update(at: 20, watchers: 1)
        XCTAssertTrue(g.update(at: 22, watchers: 1), "a new watcher veils again")
    }

    // MARK: Pointer follows eyes

    private let left = DisplayInfo(id: 1, key: "L", name: "L", bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), isBuiltin: false)
    private let right = DisplayInfo(id: 2, key: "R", name: "R", bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080), isBuiltin: false)

    func test_pointerJumpsToTheGazeWhenFarAndStaysWhenNear() {
        let far = MagicPointer.target(pointer: CGPoint(x: 100, y: 100), gaze: CGPoint(x: 1500, y: 800), faced: left, pointerDisplay: left, lastOnFaced: nil)
        XCTAssertEqual(far, CGPoint(x: 1500, y: 800))
        let near = MagicPointer.target(pointer: CGPoint(x: 1400, y: 760), gaze: CGPoint(x: 1500, y: 800), faced: left, pointerDisplay: left, lastOnFaced: nil)
        XCTAssertNil(near)
    }

    func test_aGazePointPastTheEdgeStillJumpsJustInsideTheFacedScreen() {
        let t = MagicPointer.target(pointer: CGPoint(x: 100, y: 100), gaze: CGPoint(x: 1990, y: 1130), faced: left, pointerDisplay: left, lastOnFaced: nil)
        XCTAssertEqual(t, CGPoint(x: 1900, y: 1060))
    }

    func test_pointerCrossesToTheFacedScreenWithoutAGazePoint() {
        let t = MagicPointer.target(pointer: CGPoint(x: 100, y: 100), gaze: nil, faced: right, pointerDisplay: left, lastOnFaced: CGPoint(x: 2500, y: 300))
        XCTAssertEqual(t, CGPoint(x: 2500, y: 300))
        XCTAssertNil(MagicPointer.target(pointer: CGPoint(x: 100, y: 100), gaze: nil, faced: left, pointerDisplay: left, lastOnFaced: nil))
        XCTAssertNil(MagicPointer.target(pointer: CGPoint(x: 100, y: 100), gaze: nil, faced: nil, pointerDisplay: left, lastOnFaced: nil))
    }
}
