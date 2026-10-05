import CoreGraphics
import Foundation

/// Dispersion-threshold fixation identification, I-DT (Salvucci & Goldberg, "Identifying
/// fixations and saccades in eye-tracking protocols", ETRA 2000), run online: the gaze points of
/// the last `duration` seconds form a fixation when their spread — width plus height of their
/// bounding box — stays under `dispersion`. The fixation's position is their centroid, which
/// averages away most of the frame-to-frame jitter a single sample carries.
public struct FixationDetector: Sendable {
    public var dispersion: Double
    public var duration: TimeInterval
    private var window: [(t: TimeInterval, p: CGPoint)] = []

    public init(dispersion: Double, duration: TimeInterval) {
        self.dispersion = dispersion
        self.duration = duration
    }

    /// Adds a gaze point; returns the fixation centroid if the last `duration` seconds form one.
    public mutating func add(_ p: CGPoint, at t: TimeInterval) -> CGPoint? {
        if let last = window.last, t <= last.t { return nil }
        window.append((t, p))
        // Keep exactly enough history to span `duration`: drop a sample once the next one alone covers it.
        while window.count > 1, t - window[1].t >= duration { window.removeFirst() }
        guard t - window[0].t >= duration else { return nil }
        let xs = window.map(\.p.x), ys = window.map(\.p.y)
        let spread = Double((xs.max()! - xs.min()!) + (ys.max()! - ys.min()!))
        guard spread <= dispersion else { return nil }
        let n = CGFloat(window.count)
        return CGPoint(x: xs.reduce(0, +) / n, y: ys.reduce(0, +) / n)
    }

    public mutating func reset() { window.removeAll() }
}
