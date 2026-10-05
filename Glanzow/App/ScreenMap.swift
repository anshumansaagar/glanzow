import SwiftUI
import GlanzowKit

/// Draws the user's displays to scale, the way they're arranged, with the gleam on one of them.
/// Used by the welcome window and the live view in the menu bar panel.
enum ScreenMap {
    /// Fits the arrangement into `box`, keeping proportions, with a small gap between screens.
    static func layout(_ displays: [DisplayInfo], in box: CGRect) -> [CGRect] {
        let bounds = displays.isEmpty ? [CGRect(x: 0, y: 0, width: 1600, height: 1000)] : displays.map(\.bounds)
        let (scale, offset, union) = transform(bounds, box)
        return bounds.map { b in
            CGRect(x: offset.x + (b.minX - union.minX) * scale, y: offset.y + (b.minY - union.minY) * scale,
                   width: b.width * scale, height: b.height * scale).insetBy(dx: 3, dy: 3)
        }
    }

    /// A point in global display coordinates, mapped into the same box.
    static func point(_ p: CGPoint, _ displays: [DisplayInfo], in box: CGRect) -> CGPoint {
        let bounds = displays.isEmpty ? [CGRect(x: 0, y: 0, width: 1600, height: 1000)] : displays.map(\.bounds)
        let (scale, offset, union) = transform(bounds, box)
        return CGPoint(x: offset.x + (p.x - union.minX) * scale, y: offset.y + (p.y - union.minY) * scale)
    }

    private static func transform(_ bounds: [CGRect], _ box: CGRect) -> (CGFloat, CGPoint, CGRect) {
        let union = bounds.dropFirst().reduce(bounds[0]) { $0.union($1) }
        let scale = min(box.width / union.width, box.height / union.height)
        return (scale, CGPoint(x: box.midX - union.width * scale / 2, y: box.midY - union.height * scale / 2), union)
    }
}

/// The night stage with screens and the gleam: shared look for onboarding and the live view.
struct ScreenStage: View {
    let displays: [DisplayInfo]
    /// The screen to light, by key.
    let lit: DisplayKey?
    /// Where the gleam sits, global coordinates; nil puts it at the lit screen's centre.
    let gleam: CGPoint?
    var showsGleam = true
    var padding = EdgeInsets(top: 22, leading: 22, bottom: 22, trailing: 22)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let box = CGRect(x: padding.leading, y: padding.top, width: geo.size.width - padding.leading - padding.trailing,
                             height: geo.size.height - padding.top - padding.bottom)
            let rects = ScreenMap.layout(displays, in: box)
            let litIndex = displays.firstIndex { $0.key == lit }
            let dot: CGPoint? = {
                guard showsGleam, let i = litIndex else { return nil }
                if let gleam { return ScreenMap.point(gleam, displays, in: box) }
                return CGPoint(x: rects[i].midX, y: rects[i].midY)
            }()
            ZStack(alignment: .topLeading) {
                Color(nsColor: Palette.night)
                RadialGradient(colors: [Color(nsColor: Palette.dusk).opacity(0.75), .clear], center: .center,
                               startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.6)
                ForEach(rects.indices, id: \.self) { i in
                    let r = rects[i]
                    RoundedRectangle(cornerRadius: min(6, r.height / 6), style: .continuous)
                        .fill(Color(nsColor: Palette.dusk).opacity(i == litIndex ? 1 : 0.55))
                        .overlay(RoundedRectangle(cornerRadius: min(6, r.height / 6), style: .continuous)
                            .strokeBorder(Color(nsColor: Palette.mist).opacity(i == litIndex ? 0.6 : 0.22), lineWidth: 1))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                }
                if let dot {
                    Circle()
                        .fill(Color(nsColor: Palette.gleam))
                        .frame(width: 11, height: 11)
                        .shadow(color: Color(nsColor: Palette.gleam).opacity(0.9), radius: 8)
                        .shadow(color: Color(nsColor: Palette.gleam).opacity(0.4), radius: 20)
                        .position(dot)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: dot)
        }
    }
}
