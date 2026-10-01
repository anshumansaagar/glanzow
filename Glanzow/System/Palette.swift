import AppKit

/// Glanzow's look. "Glanz" is German for gleam: one warm point of light that goes where you
/// look, on a calm night-blue ground. The gleam is the only loud thing; everything else is native.
public enum Palette {
    /// Ground of the calibration screens and the welcome-window stage.
    public static let night = rgb(0x14, 0x12, 0x2B)
    /// Screen outlines and inactive surfaces on night.
    public static let dusk = rgb(0x2A, 0x27, 0x52)
    /// The gleam: calibration dot, focus flash, the dot in the welcome stage.
    public static let gleam = rgb(0xFF, 0xC8, 0x5C)
    /// Primary text on night (contrast ≈ 16:1).
    public static let snow = rgb(0xF5, 0xF4, 0xFA)
    /// Secondary text on night (contrast ≈ 9:1).
    public static let mist = rgb(0xB9, 0xB6, 0xD3)

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// SF Pro, expanded width: the display face for headlines.
    public static func headline(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold, width: .expanded) }

    public static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
