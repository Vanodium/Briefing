import AppKit
import SwiftUI

// MARK: - Type and color

/// One ink on one ground (see Palette). Hierarchy comes from size, weight and opacity — never from hue.
/// Three levels of type: ink (what matters), soft (what explains it), dim (what you can skip).
/// Light grounds need more ink to keep small capitals above 4.5:1.
enum Theme {
    static var ink: Color { Palette.current.inkColor() }
    static var soft: Color { Palette.current.inkColor(Palette.current.isLight ? 0.80 : 0.72) }
    static var dim: Color { Palette.current.inkColor(Palette.current.isLight ? 0.68 : 0.54) }
    static var rule: Color { Palette.current.rule ?? Palette.current.inkColor(0.30) }
    static var row: Color { Palette.current.row ?? Palette.current.inkColor(0.16) }
    /// Placeholders only.
    static var faint: Color { Palette.current.inkColor(Palette.current.isLight ? 0.42 : 0.34) }
    /// Index numbers and the one highlighted value. Same as the ink except where a theme sets an accent.
    static var accent: Color { Palette.current.accent ?? Palette.current.inkColor() }

    static let locale = Locale(identifier: "en_US")

    enum Weight { case regular, medium, bold }

    /// The type scale, in points at 1512×982. Nothing else is used.
    enum Size {
        static let display: CGFloat = 300   // the weekday
        static let clock: CGFloat = 168     // the time
        static let title: CGFloat = 72      // one question per onboarding step
        static let heading: CGFloat = 36    // principles, onboarding rows
        static let subheading: CGFloat = 28 // a long list of principles, values you type
        static let body: CGFloat = 20       // challenges
        static let text: CGFloat = 16       // agenda, explanations
        static let label: CGFloat = 12      // capitals: indexes, hints, meta
    }

    /// Small type never drops below this on a small screen, however far the layout scales down.
    static let minimumSize: CGFloat = 11

    /// Neue Haas Grotesk Display if it is installed (system-wide or in Briefing's Fonts folder),
    /// otherwise Helvetica Neue — its direct ancestor, present on every Mac.
    static func nsFont(_ size: CGFloat, _ weight: Weight = .medium) -> NSFont {
        let size = max(size, minimumSize)
        let names: [String]
        switch weight {
        case .regular: names = ["NHaasGroteskDSPro-55Rg", "NeueHaasDisplay-Roman", "HelveticaNeue"]
        case .medium: names = ["NHaasGroteskDSPro-65Md", "NeueHaasDisplay-Mediu", "NeueHaasDisplay-Medium", "HelveticaNeue-Medium"]
        case .bold: names = ["NHaasGroteskDSPro-75Bd", "NeueHaasDisplay-Bold", "HelveticaNeue-Bold"]
        }
        for name in names {
            if let f = NSFont(name: name, size: size) { return f }
        }
        let w: NSFont.Weight = weight == .bold ? .bold : (weight == .medium ? .medium : .regular)
        return NSFont.systemFont(ofSize: size, weight: w)
    }

    static func font(_ size: CGFloat, _ weight: Weight = .medium) -> Font {
        Font(nsFont(size, weight) as CTFont)
    }

    /// Distance from the top of a single-line Text frame to its baseline.
    static func ascent(_ size: CGFloat, _ weight: Weight = .medium) -> CGFloat {
        nsFont(size, weight).ascender
    }
}

// MARK: - Motion

/// Every curve the dashboard uses. Nothing linear, nothing springy.
/// With Reduce Motion on, nothing travels: movement lands at once and only opacity eases,
/// so every piece still fades in on its own beat, just without the lift, the blur or the glide.
enum Curves {
    /// System Settings → Accessibility → Display → Reduce motion.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private static let still = Animation.linear(duration: 0)

    /// Long, heavy and symmetric — for the large block that travels.
    static var glide: Animation { reduceMotion ? still : .timingCurve(0.76, 0, 0.24, 1, duration: 1.7) }
    /// Fast start, very soft landing — for things that rise into place.
    static func settle(_ duration: Double) -> Animation { reduceMotion ? still : .timingCurve(0.16, 1, 0.3, 1, duration: duration) }
    /// Slow start, quick exit — for a page leaving.
    static func leave(_ duration: Double) -> Animation { reduceMotion ? still : .timingCurve(0.7, 0, 0.84, 0, duration: duration) }
    /// Opacity: eases in gently, no pop at the start.
    static func fade(_ duration: Double) -> Animation { .timingCurve(0.33, 0, 0.2, 1, duration: duration) }
    /// The whole window fading away when the day begins.
    static let windowOut = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
    static let windowIn = CAMediaTimingFunction(controlPoints: 0.33, 0, 0.2, 1)
}

/// Rise into place: opacity, a short lift and a blur that resolves into focus.
/// Movement and opacity run on different curves so the type is already settling
/// while it is still becoming visible.
struct Rise: ViewModifier {
    let visible: Bool
    let delay: Double
    let distance: CGFloat
    /// 1 is the dashboard's slow morning pace; below 1 is quicker (onboarding steps).
    var pace: Double = 1

    func body(content: Content) -> some View {
        content
            .offset(y: visible ? 0 : distance)
            .blur(radius: visible ? 0 : 6 * pace)
            .animation(visible ? Curves.settle(1.6 * pace).delay(delay) : Curves.fade(0.5 * pace), value: visible)
            .opacity(visible ? 1 : 0)
            .animation(visible ? Curves.fade(1.3 * pace).delay(delay) : Curves.fade(0.5 * pace), value: visible)
    }
}

extension View {
    func rise(_ visible: Bool, _ delay: Double, _ distance: CGFloat, pace: Double = 1) -> some View {
        modifier(Rise(visible: visible, delay: delay, distance: distance, pace: pace))
    }
}

// MARK: - Background

struct Backdrop: View {
    /// The light fades in with the ground, before any type appears.
    var sunVisible = false
    /// 0 turns the light off; 1 is full strength.
    var sunStrength = 0.8
    var palette: Palette = Palette.current
    /// The light leans a few percent toward the cursor, slowly, as if the room were breathing.
    var followsPointer = true

    @Environment(Pointer.self) private var pointer: Pointer?

    /// How far the light may travel, as a share of the screen, and the spare edge drawn so it never shows a seam.
    private static let reach: CGFloat = 0.025
    private static let margin: CGFloat = 0.03

    var body: some View {
        GeometryReader { geo in
            let r = max(geo.size.width, geo.size.height)
            let m = r * Self.margin
            let shift = lean(geo)
            ZStack(alignment: .topLeading) {
                ground(r)
                if sunStrength > 0, palette.light != .none {
                    light(CGSize(width: geo.size.width + 2 * m, height: geo.size.height + 2 * m))
                        .offset(x: shift.width - m, y: shift.height - m)
                        .animation(.spring(response: 2.4, dampingFraction: 1), value: shift)
                        .opacity(sunVisible ? min(sunStrength, 1) : 0)
                        .animation(Curves.fade(2.6).delay(0.2), value: sunVisible)
                }
                // Film grain: a static texture that removes gradient banding at zero cost.
                // It sits above the light so the warm gradient never shows steps.
                Image(decorative: Grain.image, scale: 2)
                    .resizable(resizingMode: .tile)
                    .opacity(0.03)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func lean(_ geo: GeometryProxy) -> CGSize {
        guard followsPointer, !Curves.reduceMotion, let p = pointer?.location else { return .zero }
        let f = geo.frame(in: .named(Pointer.space))
        let nx = max(-1, min(1, (p.x - f.midX) / max(f.width / 2, 1)))
        let ny = max(-1, min(1, (p.y - f.midY) / max(f.height / 2, 1)))
        return CGSize(width: nx * f.width * Self.reach, height: ny * f.height * Self.reach)
    }

    @ViewBuilder
    private func ground(_ r: CGFloat) -> some View {
        switch palette.ground {
        case .solid(let hex):
            Color(hex: hex)
        case .radial(let stops, let center, let radius):
            RadialGradient(
                stops: stops.map { Gradient.Stop(color: Color(hex: $0.0), location: $0.1) },
                center: center,
                startRadius: 0, endRadius: r * radius
            )
        }
    }

    @ViewBuilder
    private func light(_ size: CGSize) -> some View {
        switch palette.light {
        case .sun: SunPatch(size: size)
        case .horizon: HorizonGlow(size: size)
        case .smoke: SmokeDrift(size: size)
        case .glow(let glows): GlowField(size: size, glows: glows)
        case .none: EmptyView()
        }
    }
}

// MARK: - Sunlight

/// Low morning sun through a window high on the right: a faint wash from the top-right corner
/// and a long, soft patch of light lying in the lower left. Hottest (#FFC500) on the side
/// nearest the light, cooling to #C21500 at the edges. Drawn once, composited on the GPU.
struct SunPatch: View {
    let size: CGSize

    private static let gold = Color(hex: 0xFFC500)
    private static let amber = Color(hex: 0xF58200)
    private static let ember = Color(hex: 0xD63C00)
    private static let red = Color(hex: 0xC21500)
    private static let glint = Color(hex: 0xFFD65A)

    var body: some View {
        let w = size.width, h = size.height
        let s = max(0.05, min(w / 1512, h / 982))
        ZStack(alignment: .topLeading) {
            // The air the light travels through.
            LinearGradient(
                stops: [
                    .init(color: Self.gold.opacity(0.10), location: 0),
                    .init(color: Self.amber.opacity(0.06), location: 0.22),
                    .init(color: Self.red.opacity(0.03), location: 0.42),
                    .init(color: Self.red.opacity(0), location: 0.62),
                ],
                startPoint: UnitPoint(x: 1, y: 0),
                endPoint: UnitPoint(x: 0.15, y: 1)
            )
            .frame(width: w, height: h)

            // Where it lands: a long ellipse tilted along the direction of the light.
            Ellipse()
                .fill(EllipticalGradient(
                    stops: [
                        .init(color: Self.gold.opacity(0.62), location: 0),
                        .init(color: Self.amber.opacity(0.44), location: 0.30),
                        .init(color: Self.ember.opacity(0.28), location: 0.55),
                        .init(color: Self.red.opacity(0.12), location: 0.78),
                        .init(color: Self.red.opacity(0), location: 1),
                    ],
                    center: UnitPoint(x: 0.68, y: 0.38),
                    startRadiusFraction: 0,
                    endRadiusFraction: 0.62
                ))
                .frame(width: w * 0.66, height: h * 0.44)
                .rotationEffect(.degrees(-28))
                .blur(radius: 46 * s)
                .position(x: w * 0.25, y: h * 0.72)

            // A brighter core, as if the light is strongest through the middle of the pane.
            Ellipse()
                .fill(EllipticalGradient(
                    stops: [
                        .init(color: Self.glint.opacity(0.30), location: 0),
                        .init(color: Self.gold.opacity(0), location: 1),
                    ],
                    center: UnitPoint(x: 0.6, y: 0.45),
                    startRadiusFraction: 0,
                    endRadiusFraction: 0.5
                ))
                .frame(width: w * 0.30, height: h * 0.16)
                .rotationEffect(.degrees(-28))
                .blur(radius: 28 * s)
                .position(x: w * 0.29, y: h * 0.68)
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .drawingGroup()
        .blendMode(.screen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum Grain {
    static let image: CGImage = {
        let size = 192
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: size * size * 4)
        for i in 0..<(size * size) {
            let a = UInt8.random(in: 0...255)
            let v = UInt8.random(in: 140...255)
            let pv = UInt8((Int(v) * Int(a)) / 255)
            ptr[i * 4] = pv
            ptr[i * 4 + 1] = pv
            ptr[i * 4 + 2] = pv
            ptr[i * 4 + 3] = a
        }
        return ctx.makeImage()!
    }()
}


// MARK: - Hairline

/// A rule exactly one device pixel thick on any screen. 0.5 pt vanished on some displays.
/// Near the cursor it catches the light: a soft glow along the line, centred on the pointer.
struct Hair: View {
    var color: Color = Theme.row
    var vertical = false
    @Environment(\.displayScale) private var scale
    @Environment(Pointer.self) private var pointer: Pointer?

    private static let glowRadius: CGFloat = 260

    var body: some View {
        let px = 1 / max(scale, 1)
        Rectangle()
            .fill(color)
            .frame(width: vertical ? px : nil, height: vertical ? nil : px)
            .overlay {
                if let pointer {
                    GeometryReader { geo in
                        let f = geo.frame(in: .named(Pointer.space))
                        let p = pointer.location
                        RadialGradient(
                            colors: [Theme.ink.opacity(0.55), Theme.ink.opacity(0)],
                            center: UnitPoint(x: ((p?.x ?? -1e5) - f.minX) / max(f.width, px),
                                              y: ((p?.y ?? -1e5) - f.minY) / max(f.height, px)),
                            startRadius: 0, endRadius: Self.glowRadius
                        )
                        .opacity(p == nil ? 0 : 1)
                        .animation(Curves.fade(0.6), value: p == nil)
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

/// Where the cursor is over a window's content, shared with the pieces that respond to it
/// (the light and the hairlines). Nil when the cursor is outside.
@Observable
final class Pointer {
    static let space = "stage"
    var location: CGPoint?
}

extension View {
    /// Makes this view the stage the cursor is tracked on.
    func tracksPointer(_ pointer: Pointer) -> some View {
        coordinateSpace(.named(Pointer.space))
            .onContinuousHover(coordinateSpace: .named(Pointer.space)) { phase in
                switch phase {
                case .active(let p): pointer.location = p
                case .ended: pointer.location = nil
                }
            }
            .environment(pointer)
    }
}
