import Accelerate
import CoreVideo
import Foundation

/// Finds the centre of the iris inside a small grayscale eye patch, by the gradient method of
/// Timm & Barth ("Accurate eye centre localisation by means of gradients", VISAPP 2011): the
/// centre of a dark disc is the point most image gradients point away from. It needs no model,
/// copes with glasses better than thresholding (glints are bright, not dark), and costs well
/// under a millisecond on a 40×20 patch.
public enum IrisLocator {
    /// A grayscale patch, row-major, values 0…255.
    public struct Patch {
        public var width: Int
        public var height: Int
        public var pixels: [Float]

        public init(width: Int, height: Int, pixels: [Float]) {
            self.width = width; self.height = height; self.pixels = pixels
        }

        func at(_ x: Int, _ y: Int) -> Float { pixels[y * width + x] }
    }

    /// The iris centre in patch coordinates (0…width, 0…height), or nil for a patch without
    /// usable structure (a closed eye, a blown-out frame).
    public static func centre(of p: Patch) -> SIMD2<Double>? {
        let w = p.width, h = p.height
        guard w >= 8, h >= 6, p.pixels.count == w * h else { return nil }

        // Gradients (central differences), kept only where they are strong: the iris edge.
        var gx = [Float](repeating: 0, count: w * h), gy = gx, mag = gx
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                gx[i] = (p.at(x + 1, y) - p.at(x - 1, y)) / 2
                gy[i] = (p.at(x, y + 1) - p.at(x, y - 1)) / 2
                mag[i] = (gx[i] * gx[i] + gy[i] * gy[i]).squareRoot()
            }
        }
        var mean: Float = 0, sq: Float = 0
        vDSP_meanv(mag, 1, &mean, vDSP_Length(mag.count))
        vDSP_measqv(mag, 1, &sq, vDSP_Length(mag.count))
        let threshold = mean + 0.3 * max(sq - mean * mean, 0).squareRoot()
        var edges: [(x: Float, y: Float, dx: Float, dy: Float)] = []
        edges.reserveCapacity(w * h / 3)
        for i in 0..<(w * h) where mag[i] > threshold && mag[i] > 1 {
            edges.append((Float(i % w), Float(i / w), gx[i] / mag[i], gy[i] / mag[i]))
        }
        guard edges.count >= 6 else { return nil }

        // Dark pixels are more likely the centre: weight each candidate by inverted brightness,
        // lightly blurred so a single dark pixel (an eyelash) doesn't win. Only the darker 40% of
        // the patch can hold the iris centre, which also cuts the work by more than half.
        let blurred = boxBlur(p)
        let darkLimit = blurred.sorted()[Int(Double(blurred.count) * 0.4)]
        var scores = [Float](repeating: 0, count: w * h)
        var best: Float = 0, bestX = 0, bestY = 0
        for cy in 1..<(h - 1) {
            for cx in 1..<(w - 1) {
                let b = blurred[cy * w + cx]
                guard b <= darkLimit else { continue }
                var score: Float = 0
                let fx = Float(cx), fy = Float(cy)
                for e in edges {
                    let dx = e.x - fx, dy = e.y - fy
                    let n2 = dx * dx + dy * dy
                    guard n2 > 0 else { continue }
                    let dot = (dx * e.dx + dy * e.dy) // gradients point dark → bright: outward from the centre
                    if dot > 0 { score += dot * dot / n2 }
                }
                score *= 255 - b
                scores[cy * w + cx] = score
                if score > best { best = score; bestX = cx; bestY = cy }
            }
        }
        guard best > 0 else { return nil }
        // Sub-pixel: the score-weighted centroid of the 3×3 neighbourhood around the peak.
        var sx: Float = 0, sy: Float = 0, st: Float = 0
        for j in -1...1 {
            for i in -1...1 {
                let x = bestX + i, y = bestY + j
                guard x >= 0, y >= 0, x < w, y < h else { continue }
                let v = scores[y * w + x]
                sx += v * Float(x); sy += v * Float(y); st += v
            }
        }
        return SIMD2(Double(sx / st) + 0.5, Double(sy / st) + 0.5)
    }

    /// Where the eye points, from the iris centre in a patch made by `patch(fromLuma:...)`:
    /// x is the iris position along the corner-to-corner line, 0 at its middle (±0.5 at the
    /// corners); y is its distance from that line in the same units, positive downward.
    public static func eyeOffset(iris c: SIMD2<Double>, width w: Int, height h: Int) -> SIMD2<Double> {
        SIMD2(1.1 * c.x / Double(w) - 0.05 - 0.5, 1.1 * (c.y - Double(h) / 2) / Double(w))
    }

    static func boxBlur(_ p: Patch) -> [Float] {
        let w = p.width, h = p.height
        var out = p.pixels
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var s: Float = 0
                for j in -1...1 { for i in -1...1 { s += p.at(x + i, y + j) } }
                out[y * w + x] = s / 9
            }
        }
        return out
    }

    /// Samples an eye patch from the luma plane of a 420 bi-planar frame. `corners` are the eye's
    /// outer and inner corners in pixel coordinates (top-left origin); the patch is aligned to
    /// the line between them, so a tilted head still gives an upright eye. Returns the patch and
    /// a mapping back from patch coordinates to "eye space": x 0 at one corner, 1 at the other;
    /// y in the same units, 0 on the corner line.
    public static func patch(fromLuma pixels: CVPixelBuffer, corners a: SIMD2<Double>, _ b: SIMD2<Double>,
                             width w: Int = 40, height h: Int = 20) -> Patch? {
        guard CVPixelBufferGetPlaneCount(pixels) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let imgW = CVPixelBufferGetWidthOfPlane(pixels, 0), imgH = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)

        let axis = b - a
        let length = (axis.x * axis.x + axis.y * axis.y).squareRoot()
        guard length >= 8 else { return nil } // eye too small to read
        let ux = axis / length, uy = SIMD2(-ux.y, ux.x)
        // The patch spans the corner line a bit past each corner, and half its length up and down.
        let span = length * 1.1, tall = span * Double(h) / Double(w)
        let origin = (a + b) / 2 - ux * span / 2 - uy * tall / 2
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let q = origin + ux * (Double(x) + 0.5) * span / Double(w) + uy * (Double(y) + 0.5) * tall / Double(h)
                let px = Int(q.x), py = Int(q.y)
                guard px >= 0, py >= 0, px < imgW, py < imgH else { return nil }
                out[y * w + x] = Float(luma[py * rowBytes + px])
            }
        }
        // Normalise contrast: top lighting and dark skin shouldn't change the answer.
        var lo: Float = 0, hi: Float = 0
        vDSP_minv(out, 1, &lo, vDSP_Length(out.count))
        vDSP_maxv(out, 1, &hi, vDSP_Length(out.count))
        guard hi - lo > 12 else { return nil } // no contrast: closed eye or a dark frame
        var scale = 255 / (hi - lo), shift = -lo * 255 / (hi - lo)
        vDSP_vsmsa(out, 1, &scale, &shift, &out, 1, vDSP_Length(out.count))
        return Patch(width: w, height: h, pixels: out)
    }
}
