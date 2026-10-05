import Foundation

/// One training example for a gaze map: what the head and eyes did, and where the user was
/// looking then (normalised on the display). Numbers only; stored with the display's calibration.
public struct GazePair: Codable, Sendable, Equatable {
    public var yaw: Double
    public var pitch: Double
    public var eyeX: Double?
    public var eyeY: Double?
    public var x: Double
    public var y: Double

    public init(_ s: PoseSample, target: SIMD2<Double>) {
        yaw = s.yaw; pitch = s.pitch; eyeX = s.pupilOffset?.x; eyeY = s.pupilOffset?.y; x = target.x; y = target.y
    }

    var sample: PoseSample {
        var s = PoseSample(timestamp: 0, yaw: yaw, pitch: pitch)
        if let eyeX, let eyeY { s.pupilOffset = SIMD2(eyeX, eyeY) }
        return s
    }
    var target: SIMD2<Double> { SIMD2(x, y) }
}

/// FR-P2-01: where on one display the user is looking, from head pose plus eye offset, as a
/// linear fit to the calibration dots. Output is normalised: (0, 0) top-left, (1, 1) bottom-right.
public struct GazeMap: Codable, Sendable, Equatable {
    /// Two rows (x, y) of coefficients over [1, yaw, pitch].
    public var head: [[Double]]
    /// Two rows over [1, yaw, pitch, pupil x·100, pupil y·100]; nil if calibration saw no pupils.
    public var eyes: [[Double]]?
    /// Root-mean-square fit error in normalised units (0.1 = a tenth of the screen).
    public var headError: Double
    public var eyesError: Double?
    /// Which eye measurement the eye model was fitted on. Maps from an older measurement fall
    /// back to the head model until the user recalibrates (nil: Vision's pupil points, pre-iris).
    public var eyeSource: String?
    public static let currentEyeSource = "iris-1"

    public init(head: [[Double]], eyes: [[Double]]?, headError: Double, eyesError: Double?, eyeSource: String? = GazeMap.currentEyeSource) {
        self.head = head; self.eyes = eyes; self.headError = headError; self.eyesError = eyesError; self.eyeSource = eyeSource
    }

    /// The eye model is usable with today's eye measurement.
    public var eyesCurrent: Bool { eyes != nil && eyeSource == Self.currentEyeSource }

    /// Pupil offsets are about ±0.1, head angles about ±30°; scaling pupils by 100 puts both on
    /// the same footing so the small ridge term treats them alike.
    static func features(_ s: PoseSample, angles: SIMD2<Double>, eyes: Bool) -> [Double]? {
        var f = [1, angles.x, angles.y]
        if eyes {
            guard let p = s.pupilOffset else { return nil }
            f += [p.x * 100, p.y * 100]
        }
        return f
    }

    /// Normalised gaze point; uses the eye model when the sample has pupils, else head only.
    /// `angles` lets the caller pass distance-compensated yaw and pitch.
    public func point(_ s: PoseSample, angles: SIMD2<Double>? = nil) -> SIMD2<Double> {
        let a = angles ?? s.angles
        let usable = eyeSource == Self.currentEyeSource ? eyes : nil
        let (rows, f) = usable.flatMap { e in Self.features(s, angles: a, eyes: true).map { (e, $0) } }
            ?? (head, Self.features(s, angles: a, eyes: false)!)
        return SIMD2(zip(rows[0], f).map(*).reduce(0, +), zip(rows[1], f).map(*).reduce(0, +))
    }

    /// The error of the model `point` would use for this sample.
    public func error(for s: PoseSample) -> Double { s.pupilOffset != nil && eyesCurrent ? (eyesError ?? headError) : headError }

    /// WebGazer-style refit (Papoutsaki et al., IJCAI 2016): calibration pairs plus the clicks of
    /// real use, where the eyes are on the click point. Clicks count three times each, since they
    /// are few but come from how the user actually looks.
    public static func fit(calibration: [GazePair], clicks: [GazePair]) -> GazeMap? {
        let pairs = (calibration + clicks + clicks + clicks).map { (sample: $0.sample, target: $0.target) }
        return fit(pairs)
    }

    /// Least squares over (sample, normalised dot position) pairs. Nil with too few samples or
    /// fewer than three distinct dot positions (a plane needs three).
    public static func fit(_ pairs: [(sample: PoseSample, target: SIMD2<Double>)]) -> GazeMap? {
        let distinct = Set(pairs.map { "\(Int($0.target.x * 100)),\(Int($0.target.y * 100))" })
        guard pairs.count >= 20, distinct.count >= 3, let head = solve(pairs, eyes: false) else { return nil }
        let withPupils = pairs.filter { $0.sample.pupilOffset != nil }
        let eyes = withPupils.count >= max(20, pairs.count / 2) ? solve(withPupils, eyes: true) : nil
        return GazeMap(head: head.rows, eyes: eyes?.rows, headError: head.error, eyesError: eyes?.error)
    }

    private static func solve(_ pairs: [(sample: PoseSample, target: SIMD2<Double>)], eyes: Bool) -> (rows: [[Double]], error: Double)? {
        let xs = pairs.compactMap { features($0.sample, angles: $0.sample.angles, eyes: eyes) }
        guard xs.count == pairs.count, let k = xs.first?.count else { return nil }
        // Normal equations (XᵀX + λI)β = XᵀY, with a small ridge λ for stability.
        var a = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        var b = [[Double]](repeating: [0, 0], count: k)
        for (x, p) in zip(xs, pairs) {
            for i in 0..<k {
                for j in 0..<k { a[i][j] += x[i] * x[j] }
                b[i][0] += x[i] * p.target.x
                b[i][1] += x[i] * p.target.y
            }
        }
        for i in 1..<k { a[i][i] += 1e-3 * Double(xs.count) } // not the intercept
        guard let beta = gaussian(a, b) else { return nil }
        let rows = [beta.map { $0[0] }, beta.map { $0[1] }]
        var sq = 0.0
        for (x, p) in zip(xs, pairs) {
            let px = zip(rows[0], x).map(*).reduce(0, +), py = zip(rows[1], x).map(*).reduce(0, +)
            sq += (px - p.target.x) * (px - p.target.x) + (py - p.target.y) * (py - p.target.y)
        }
        return (rows, (sq / Double(2 * xs.count)).squareRoot())
    }

    /// Solves A·X = B (A k×k, B k×2) by Gaussian elimination with partial pivoting.
    static func gaussian(_ a: [[Double]], _ b: [[Double]]) -> [[Double]]? {
        var a = a, b = b
        let n = a.count
        for c in 0..<n {
            let p = (c..<n).max { abs(a[$0][c]) < abs(a[$1][c]) }!
            guard abs(a[p][c]) > 1e-12 else { return nil }
            a.swapAt(c, p)
            b.swapAt(c, p)
            for r in 0..<n where r != c {
                let f = a[r][c] / a[c][c]
                guard f != 0 else { continue }
                for j in c..<n { a[r][j] -= f * a[c][j] }
                b[r][0] -= f * b[c][0]
                b[r][1] -= f * b[c][1]
            }
        }
        return (0..<n).map { [b[$0][0] / a[$0][$0], b[$0][1] / a[$0][$0]] }
    }
}
