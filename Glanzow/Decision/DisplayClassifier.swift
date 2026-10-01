import Foundation

public enum Classification: Equatable, Sendable {
    /// Looking at no display: phone, desk, ceiling (FR-CLS-02).
    case offScreen
    /// Nearer another display, but not by the hysteresis margin (FR-CLS-03).
    case stay
    case candidate(DisplayKey)
}

public protocol DisplayClassifier: Sendable {
    func classify(_ sample: PoseSample, current: DisplayKey?) -> Classification
    /// Mahalanobis distance from the sample to every display, nearest first.
    func distances(_ sample: PoseSample) -> [(key: DisplayKey, distance: Double)]
}

/// §6.3 nearest-cluster classifier on (yaw, pitch), with §6.5 distance compensation.
public struct MahalanobisClassifier: DisplayClassifier {
    struct Cluster: Sendable {
        var key: DisplayKey
        var mean: SIMD2<Double>
        var inverse: Cov2
    }

    let clusters: [Cluster]
    public let rejectThreshold: Double
    public let hysteresisFactor: Double
    /// Centre of all display means: the user's neutral pose for distance compensation.
    let neutral: SIMD2<Double>
    let calibratedScale: Double
    public let compensateDistance: Bool

    public init(models: [DisplayModel], rejectThreshold: Double = 4.0, hysteresisFactor: Double = 1.2, compensateDistance: Bool = true) {
        clusters = models.map { Cluster(key: $0.key, mean: $0.mean, inverse: $0.covariance.regularized().inverse ?? Cov2(xx: 1, xy: 0, yy: 1)) }
        self.rejectThreshold = rejectThreshold
        self.hysteresisFactor = hysteresisFactor
        self.compensateDistance = compensateDistance
        let n = Double(max(models.count, 1))
        neutral = models.reduce(SIMD2<Double>.zero) { $0 + $1.mean } / n
        calibratedScale = models.reduce(0) { $0 + $1.meanFaceScale } / n
    }

    public var keys: [DisplayKey] { clusters.map(\.key) }

    /// FR-CAL-08, §6.5. Leaning in widens the angles between screens, so the sample's offset from
    /// the neutral pose is scaled back to calibration distance.
    /// SPEC: §6.5 literally says multiply by (current scale / calibrated scale), but that pushes a
    /// leaning-in sample further out, the opposite of what its own first sentence and FR-CAL-08
    /// ("scale the thresholds by current vs calibrated") describe. Dividing by that ratio is the
    /// same as scaling the thresholds up; the 0.7–1.4 clamp is kept on the ratio.
    public func compensated(_ s: PoseSample) -> SIMD2<Double> {
        guard compensateDistance, calibratedScale > 0, s.faceScale > 0 else { return s.angles }
        let ratio = min(max(s.faceScale / calibratedScale, 0.7), 1.4)
        return neutral + (s.angles - neutral) / ratio
    }

    public func distances(_ s: PoseSample) -> [(key: DisplayKey, distance: Double)] {
        let x = compensated(s)
        return clusters.map { c in (c.key, c.inverse.quadratic(x - c.mean).squareRoot()) }.sorted { $0.distance < $1.distance }
    }

    public func classify(_ s: PoseSample, current: DisplayKey?) -> Classification {
        let d = distances(s)
        guard let best = d.first, best.distance <= rejectThreshold else { return .offScreen }
        if let current, best.key != current, let toCurrent = d.first(where: { $0.key == current })?.distance,
           best.distance * hysteresisFactor > toCurrent {
            return .stay
        }
        return .candidate(best.key)
    }
}
