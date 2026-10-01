import Foundation

/// One Euro filter for one channel (Casiez, Roussel, Vogel, CHI 2012). FR-TRK-04, §6.2.
/// Low cutoff when the signal is still (kills jitter), higher cutoff as it moves (cuts lag).
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double
    private var last: (t: Double, x: Double, dx: Double)?

    public init(minCutoff: Double = 1.0, beta: Double = 0.05, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    public mutating func callAsFunction(_ x: Double, at t: Double) -> Double {
        guard let p = last else {
            last = (t, x, 0)
            return x
        }
        guard t > p.t else { return p.x }
        let dt = t - p.t
        let dx = Self.lowpass((x - p.x) / dt, p.dx, Self.alpha(dt, dCutoff))
        let fx = Self.lowpass(x, p.x, Self.alpha(dt, minCutoff + beta * abs(dx)))
        last = (t, fx, dx)
        return fx
    }

    public mutating func reset() { last = nil }

    static func alpha(_ dt: Double, _ cutoff: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    static func lowpass(_ x: Double, _ previous: Double, _ a: Double) -> Double { a * x + (1 - a) * previous }
}

/// Smooths yaw, pitch, roll and face scale of a pose stream. Used live and by ReplayCLI so both
/// see identical numbers. A gap longer than `resetGap` (the face was lost) restarts the filters,
/// so a returning face is not blended with where it was seconds ago.
public struct PoseSmoother: Sendable {
    private var yaw, pitch, roll, scale: OneEuroFilter
    private var lastTime = -Double.infinity
    public var resetGap: TimeInterval = 1.0

    public init(_ p: SmoothingParams = SmoothingParams()) {
        let f = OneEuroFilter(minCutoff: p.minCutoff, beta: p.beta, dCutoff: p.dCutoff)
        (yaw, pitch, roll, scale) = (f, f, f, f)
    }

    public mutating func callAsFunction(_ s: PoseSample) -> PoseSample {
        if s.timestamp - lastTime > resetGap { yaw.reset(); pitch.reset(); roll.reset(); scale.reset() }
        lastTime = s.timestamp
        var out = s
        out.yaw = yaw(s.yaw, at: s.timestamp)
        out.pitch = pitch(s.pitch, at: s.timestamp)
        out.roll = roll(s.roll, at: s.timestamp)
        out.faceScale = scale(s.faceScale, at: s.timestamp)
        return out
    }
}
