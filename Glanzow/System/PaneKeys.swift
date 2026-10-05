import CoreGraphics
import Foundation

/// The pane-navigation shortcuts apps ship with by default. If a user has remapped them, the
/// keystroke does nothing useful and FocusManager's check sees focus didn't move.
struct PaneKeys {
    enum Style {
        case optionCommandArrow        // iTerm2, Ghostty: ⌥⌘ + arrow
        case commandKThenCommandArrow  // VS Code, Cursor, VSCodium, Zed: ⌘K, then ⌘ + arrow
        case controlShiftArrow         // WezTerm: ⌃⇧ + arrow
    }
    let style: Style

    init?(bundle: String?) {
        switch bundle {
        case "com.googlecode.iterm2", "com.mitchellh.ghostty": style = .optionCommandArrow
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.vscodium", "dev.zed.Zed":
            style = .commandKThenCommandArrow
        case "com.github.wez.wezterm": style = .controlShiftArrow
        default: return nil
        }
    }

    /// Arrow key toward `target` from `from` (global coordinates, y grows downward).
    static func arrow(toward target: CGPoint, from: CGPoint) -> CGKeyCode {
        let dx = target.x - from.x, dy = target.y - from.y
        if abs(dx) >= abs(dy) { return dx > 0 ? 124 : 123 } // right : left
        return dy > 0 ? 125 : 126                            // down : up
    }

    static func name(_ arrow: CGKeyCode) -> String { [123: "left", 124: "right", 125: "down", 126: "up"][arrow] ?? "\(arrow)" }

    @discardableResult
    func move(toward target: CGPoint, from: CGPoint, pid: pid_t) -> CGKeyCode {
        let arrow = Self.arrow(toward: target, from: from)
        switch style {
        case .optionCommandArrow:
            Self.post(arrow, [.maskCommand, .maskAlternate], to: pid)
        case .commandKThenCommandArrow:
            Self.post(40, [.maskCommand], to: pid) // K
            usleep(30_000)
            Self.post(arrow, [.maskCommand], to: pid)
        case .controlShiftArrow:
            Self.post(arrow, [.maskControl, .maskShift], to: pid)
        }
        return arrow
    }

    /// Delivered to that one process (CGEventPostToPid), never into the system-wide stream, and
    /// from a private event source so the user's own held modifiers can't mix in.
    static func post(_ key: CGKeyCode, _ flags: CGEventFlags, to pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        let arrowFlags: CGEventFlags = (123...126).contains(key) ? [.maskSecondaryFn, .maskNumericPad] : []
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags.union(arrowFlags)
            event.postToPid(pid)
        }
    }
}
