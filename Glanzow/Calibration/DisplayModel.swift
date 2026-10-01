import Foundation

/// Symmetric 2×2 covariance of (yaw, pitch), degrees².
public struct Cov2: Codable, Sendable, Equatable {
    public var xx: Double
    public var xy: Double
    public var yy: Double

    public init(xx: Double, xy: Double, yy: Double) { self.xx = xx; self.xy = xy; self.yy = yy }

    public var determinant: Double { xx * yy - xy * xy }

    /// §6.3: add 1 degree² to the diagonal so tight clusters don't give overconfident boundaries.
    /// For any valid covariance this also guarantees an inverse (determinant ≥ 1).
    public func regularized(_ r: Double = 1) -> Cov2 { Cov2(xx: xx + r, xy: xy, yy: yy + r) }

    public var inverse: Cov2? {
        let d = determinant
        guard d > 1e-12 else { return nil }
        return Cov2(xx: yy / d, xy: -xy / d, yy: xx / d)
    }

    /// vᵀ M v
    public func quadratic(_ v: SIMD2<Double>) -> Double { v.x * v.x * xx + 2 * v.x * v.y * xy + v.y * v.y * yy }
}

/// Where the user's head points when looking at one display, learned by calibration (FR-CAL-03).
public struct DisplayModel: Codable, Sendable, Equatable {
    public var key: DisplayKey
    public var name: String
    public var mean: SIMD2<Double>      // (yaw, pitch), degrees
    public var covariance: Cov2         // raw; regularised where it is used (§6.3)
    public var meanFaceScale: Double
    public var cameraID: String
    public var sampleCount: Int
    public var calibratedAt: Date
    /// FR-P2-01: gaze position within this display. Nil for calibrations made before Phase 2.
    public var gaze: GazeMap?

    public static let minSamples = 15

    public init(key: DisplayKey, name: String, mean: SIMD2<Double>, covariance: Cov2, meanFaceScale: Double,
                cameraID: String, sampleCount: Int, calibratedAt: Date = Date(), gaze: GazeMap? = nil) {
        self.key = key; self.name = name; self.mean = mean; self.covariance = covariance
        self.meanFaceScale = meanFaceScale; self.cameraID = cameraID; self.sampleCount = sampleCount
        self.calibratedAt = calibratedAt; self.gaze = gaze
    }

    /// Mean and unbiased sample covariance of (yaw, pitch), plus mean face scale.
    /// Nil if there are too few samples to trust (the face was mostly undetected).
    public static func fit(key: DisplayKey, name: String, cameraID: String, samples: [PoseSample]) -> DisplayModel? {
        guard samples.count >= minSamples else { return nil }
        let n = Double(samples.count)
        let mean = samples.reduce(SIMD2<Double>.zero) { $0 + $1.angles } / n
        var c = Cov2(xx: 0, xy: 0, yy: 0)
        for s in samples {
            let d = s.angles - mean
            c.xx += d.x * d.x
            c.xy += d.x * d.y
            c.yy += d.y * d.y
        }
        c = Cov2(xx: c.xx / (n - 1), xy: c.xy / (n - 1), yy: c.yy / (n - 1))
        let scale = samples.reduce(0) { $0 + $1.faceScale } / n
        return DisplayModel(key: key, name: name, mean: mean, covariance: c, meanFaceScale: scale,
                            cameraID: cameraID, sampleCount: samples.count)
    }

    /// §6.6, FR-LRN-02: exponentially weighted update from one click-labelled sample:
    /// mean ← (1−w)·mean + w·x, and the covariance with the same weight.
    public mutating func learn(_ x: SIMD2<Double>, weight w: Double = 0.02) {
        let d = x - mean
        mean += w * d
        covariance = Cov2(xx: (1 - w) * (covariance.xx + w * d.x * d.x),
                          xy: (1 - w) * (covariance.xy + w * d.x * d.y),
                          yy: (1 - w) * (covariance.yy + w * d.y * d.y))
    }
}
