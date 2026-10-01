import Foundation
import os
import QuartzCore

/// The one clock every module uses: seconds on the host clock (same base as camera frame times).
public func now() -> TimeInterval { CACurrentMediaTime() }

public func logger(_ category: String) -> Logger { Logger(subsystem: "dev.glanzow", category: category) }

public enum Paths {
    /// ~/Library/Application Support/Glanzow — calibration, event log, debug recordings.
    public static var appSupport: URL {
        URL.applicationSupportDirectory.appending(path: "Glanzow", directoryHint: .isDirectory)
    }
}

/// UserDefaults keys for every setting in spec §3.9, plus the hidden debug pane (§6.2, §6.3).
/// Calibration lives separately, as JSON in Application Support (CalibrationStore).
public enum Pref {
    public static let dwellMs = "dwellMs"
    public static let headTurn = "headTurn"
    public static let waitWhileTyping = "waitWhileTyping"
    public static let typingPause = "typingPause"
    public static let mouseQuiet = "mouseQuiet"
    public static let movePointer = "movePointer"
    public static let flashOnSwitch = "flashOnSwitch"
    public static let learnFromClicks = "learnFromClicks"
    public static let cameraID = "cameraID"
    public static let hotkeyCode = "hotkeyCode"
    public static let hotkeyModifiers = "hotkeyModifiers"
    public static let hotkeyLabel = "hotkeyLabel"
    public static let excludedApps = "excludedApps"
    public static let showActiveBorder = "showActiveBorder"
    public static let confirmMode = "confirmMode"
    public static let confirmKey = "confirmKey"   // fn, control, option, command
    public static let onboardingDone = "onboardingDone"
    public static let focusWithinScreen = "focusWithinScreen"   // FR-P2-01
    public static let focusPanes = "focusPanes"                 // FR-P2-02
    public static let paneClickFallback = "paneClickFallback"   // FR-P2-02 opt-in click
    public static let suggestedCallApps = "suggestedCallApps"
    // Hidden debug pane
    public static let minCutoff = "minCutoff"
    public static let beta = "beta"
    public static let dCutoff = "dCutoff"
    public static let rejectThreshold = "rejectThreshold"
    public static let trackPupils = "trackPupils"
    public static let showDebugOverlay = "showDebugOverlay"

    public static let defaults: [String: Any] = [
        dwellMs: 300.0,
        headTurn: 0.5,
        waitWhileTyping: true,
        typingPause: 3.0,
        mouseQuiet: 1.5,
        movePointer: true,
        flashOnSwitch: true,
        learnFromClicks: true,
        cameraID: "",                 // "" = built-in camera
        hotkeyCode: 5,                // kVK_ANSI_G
        hotkeyModifiers: 768,         // cmdKey | shiftKey
        hotkeyLabel: "⇧⌘G",
        excludedApps: [String](),
        showActiveBorder: false,
        confirmMode: false,
        confirmKey: "fn",
        onboardingDone: false,
        focusWithinScreen: true,
        focusPanes: true,
        paneClickFallback: false,
        suggestedCallApps: [String](),
        minCutoff: 1.0,
        beta: 0.05,
        dCutoff: 1.0,
        rejectThreshold: 4.0,
        // SPEC: FR-TRK-03 is a Should and V1 classification never reads pupils, so landmarks
        // (the most expensive Vision request) stay off by default to protect NFR-04 CPU.
        trackPupils: false,
        showDebugOverlay: false,
    ]

    public static func register(_ d: UserDefaults = .standard) { d.register(defaults: defaults) }
}

func clamp<T: Comparable>(_ x: T, _ lo: T, _ hi: T) -> T { min(max(x, lo), hi) }

/// Decision parameters read by the classifier and SwitchController. Values from UserDefaults are
/// clamped to the spec's ranges, since `defaults write` can put anything there.
public struct Tuning: Sendable, Equatable {
    public var dwell: TimeInterval = 0.3               // FR-CLS-04
    public var hysteresisFactor = 1.4                   // FR-CLS-03 (default 50%)
    public var rejectThreshold = 4.0                    // FR-CLS-02
    public var typingPause: TimeInterval? = 3.0         // FR-SAF-01; nil = "Wait while typing" off
    public var typingOverride: TimeInterval = 1.0       // FR-SAF-01 sustained-turn override
    public var mouseQuiet: TimeInterval = 1.5           // FR-SAF-02
    public var noFaceTimeout: TimeInterval = 1.0        // FR-TRK-06
    public var confirmMode = false                      // FR-SAF-08
    public var focusWithinScreen = true                 // FR-P2-01
    /// SPEC: Phase 2 gives no dwell for moves within a screen. Eye-based gaze is noisier than
    /// head pose, so it waits 1.5× the screen dwell (450 ms by default).
    public var regionDwell: TimeInterval = 0.45
    /// Hysteresis within a screen: the gaze must leave the focused region by this fraction of
    /// the display width, and land this far (halved) inside the new one.
    public var regionMargin = 0.05

    public init() {}

    public init(_ d: UserDefaults) {
        dwell = clamp(d.double(forKey: Pref.dwellMs), 100, 1000) / 1000
        hysteresisFactor = Self.hysteresisFactor(headTurn: d.double(forKey: Pref.headTurn))
        rejectThreshold = clamp(d.double(forKey: Pref.rejectThreshold), 1, 20)
        typingPause = d.bool(forKey: Pref.waitWhileTyping) ? clamp(d.double(forKey: Pref.typingPause), 0.5, 10) : nil
        mouseQuiet = clamp(d.double(forKey: Pref.mouseQuiet), 0.5, 5)
        confirmMode = d.bool(forKey: Pref.confirmMode)
        focusWithinScreen = d.bool(forKey: Pref.focusWithinScreen)
        regionDwell = dwell * 1.5
    }

    /// SPEC: FR-CLS-03 says "at least 1.2×", user-tunable. 0–100% maps linearly to 1.2–1.6, so
    /// 1.2 is the floor and the 50% default is 1.4. Reading 50% as exactly 1.2 would let the
    /// slider go below the floor, which switches more.
    public static func hysteresisFactor(headTurn: Double) -> Double { 1.2 + 0.4 * clamp(headTurn, 0, 1) }
}

/// One Euro filter parameters (§6.2), exposed in the hidden debug pane.
public struct SmoothingParams: Sendable, Equatable {
    public var minCutoff = 1.0
    public var beta = 0.05
    public var dCutoff = 1.0

    public init() {}

    public init(_ d: UserDefaults) {
        minCutoff = clamp(d.double(forKey: Pref.minCutoff), 0.01, 10)
        beta = clamp(d.double(forKey: Pref.beta), 0, 10)
        dCutoff = clamp(d.double(forKey: Pref.dCutoff), 0.01, 10)
    }
}
