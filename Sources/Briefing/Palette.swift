import SwiftUI

/// The themes. Every colour on screen is derived from one of these:
/// the ink (type) at a few fixed opacities, the ground, and an optional light falling on it.
struct Palette: Identifiable {
    enum Ground {
        case solid(UInt32)
        /// Colour stops, centre of the gradient, radius as a share of the longer screen side.
        case radial([(UInt32, CGFloat)], UnitPoint, CGFloat)
    }

    /// sun, horizon and smoke are screened onto dark grounds; glow is a set of soft shapes
    /// laid over a light ground in plain colour, so light reads as warmth rather than as brightness.
    enum Light: Equatable { case none, sun, horizon, smoke, glow([Glow]) }

    let id: String
    let name: String
    let summary: String
    let ink: (Double, Double, Double)
    let ground: Ground
    /// A flat colour that stands for the ground: theme swatches and type on solid-ink buttons.
    let swatch: UInt32
    let light: Light
    let isLight: Bool
    var accent: Color? = nil
    var rule: Color? = nil
    var row: Color? = nil

    func inkColor(_ alpha: Double = 1) -> Color {
        Color(.sRGB, red: ink.0 / 255, green: ink.1 / 255, blue: ink.2 / 255, opacity: alpha)
    }

    var swatchColor: Color { Color(hex: swatch) }

    // MARK: Catalogue

    static let all: [Palette] = [
        Palette(id: "firstLight", name: "First Light",
                summary: "Low morning sun through a window, landing in the lower left. The signature.",
                ink: (255, 255, 255),
                ground: .radial([(0x1A1A1A, 0), (0x121212, 0.55), (0x0C0C0C, 1)], UnitPoint(x: 0.85, y: 0), 0.85),
                swatch: 0x151515, light: .sun, isLight: false),
        Palette(id: "graphite", name: "Graphite",
                summary: "Flat graphite. Nothing but the type.",
                ink: (255, 255, 255), ground: .solid(0x0E0E0E), swatch: 0x0E0E0E, light: .none, isLight: false),
        Palette(id: "cognac", name: "Cognac",
                summary: "Flat dark leather, warm bone type.",
                ink: (242, 233, 222), ground: .solid(0x1A120D), swatch: 0x1A120D, light: .none, isLight: false),
        Palette(id: "blueHour", name: "Blue Hour",
                summary: "Before first light: deep blue, a peach and violet glow just under the horizon.",
                ink: (240, 242, 250),
                ground: .radial([(0x141A2C, 0), (0x0C1020, 0.5), (0x080A14, 1)], UnitPoint(x: 0.5, y: 1.1), 0.9),
                swatch: 0x0C1020, light: .horizon, isLight: false),
        Palette(id: "smoke", name: "Smoke",
                summary: "Graphite with a slow drift of smoke. No colour, only light and air.",
                ink: (255, 255, 255), ground: .solid(0x101010), swatch: 0x101010, light: .smoke, isLight: false),
        Palette(id: "daybreak", name: "Daybreak",
                summary: "First Light on paper: warm sun lying across a cream page, its brightest edge in the lower left.",
                ink: (30, 26, 22),
                ground: .radial([(0xF3EDE3, 0), (0xEDE5D8, 0.55), (0xE6DCCC, 1)], UnitPoint(x: 0.85, y: 0), 0.85),
                swatch: 0xEDE5D8, light: .glow([
                    Glow([(0xFFD9A0, 0.30, 0), (0xFFD9A0, 0, 1)], size: (1.1, 0.9), at: (0.95, 0.0), rotation: -28, blur: 80),
                    Glow([(0xF7B267, 0.38, 0), (0xEE8A4F, 0.22, 0.45), (0xE07050, 0.08, 0.8), (0xE07050, 0, 1)],
                         size: (0.70, 0.48), at: (0.25, 0.72), rotation: -28, blur: 56,
                         center: UnitPoint(x: 0.68, y: 0.38), end: 0.62),
                    Glow([(0xFFF6D6, 0.75, 0), (0xFFE08A, 0.35, 0.5), (0xFFE08A, 0, 1)],
                         size: (0.34, 0.18), at: (0.29, 0.68), rotation: -28, blur: 26,
                         center: UnitPoint(x: 0.6, y: 0.45)),
                ]), isLight: true, accent: Color(hex: 0xB4531A)),
        Palette(id: "dawn", name: "Dawn",
                summary: "Blue Hour, a little later: a pale sky, peach and lilac just over the horizon.",
                ink: (22, 28, 48),
                ground: .radial([(0xDDE3EE, 0), (0xE4E7EF, 0.6), (0xEBEBEF, 1)], UnitPoint(x: 0.5, y: -0.1), 1.0),
                swatch: 0xE2E6EE, light: .glow([
                    Glow([(0xF8C6B0, 0.55, 0), (0xEFB8C8, 0.38, 0.3), (0xC9BCE6, 0.25, 0.58), (0xB9C6E6, 0.10, 0.82), (0xB9C6E6, 0, 1)],
                         size: (0.95, 0.56), at: (0.34, 0.97), rotation: -4, blur: 70,
                         center: UnitPoint(x: 0.46, y: 0.52), end: 0.6),
                    Glow([(0xFFF0E4, 0.70, 0), (0xFFF0E4, 0, 1)], size: (0.5, 0.12), at: (0.36, 0.92), rotation: -4, blur: 30),
                ]), isLight: true, accent: Color(hex: 0x5A5FA8)),
        Palette(id: "haze", name: "Haze",
                summary: "A rose morning haze from the top right, settling into peach light below.",
                ink: (44, 24, 26),
                ground: .radial([(0xF4E9E4, 0), (0xEFE1DB, 0.55), (0xE8D7D0, 1)], UnitPoint(x: 0.85, y: 0), 0.9),
                swatch: 0xEFE1DB, light: .glow([
                    Glow([(0xF2A99A, 0.35, 0), (0xE9B3C2, 0.18, 0.45), (0xE9B3C2, 0, 1)],
                         size: (1.0, 0.8), at: (0.92, 0.05), rotation: -28, blur: 90, end: 0.55),
                    Glow([(0xFFD7B8, 0.50, 0), (0xF7B6A0, 0.28, 0.5), (0xF7B6A0, 0, 1)],
                         size: (0.62, 0.40), at: (0.28, 0.74), rotation: -28, blur: 60,
                         center: UnitPoint(x: 0.65, y: 0.4), end: 0.6),
                    Glow([(0xFFF4EC, 0.60, 0), (0xFFF4EC, 0, 1)], size: (0.28, 0.14), at: (0.31, 0.70), rotation: -28, blur: 24),
                ]), isLight: true, accent: Color(hex: 0xB0505A)),
        Palette(id: "mist", name: "Mist",
                summary: "Smoke in daylight: pale grey air, slow shadows drifting through it.",
                ink: (20, 20, 20), ground: .solid(0xE8E7E4),
                swatch: 0xE8E7E4, light: .glow([
                    Glow([(0x9A9A9A, 0.16, 0), (0x9A9A9A, 0.07, 0.45), (0x9A9A9A, 0, 1)],
                         size: (0.78, 0.84), at: (0.81, 0.18), rotation: 14, blur: 90,
                         center: UnitPoint(x: 0.4, y: 0.55), end: 0.55),
                    Glow([(0xFFFFFF, 0.55, 0), (0xFFFFFF, 0, 1)], size: (0.6, 0.62), at: (0.2, 0.79), rotation: -10, blur: 90, end: 0.55),
                    Glow([(0x8C8C8C, 0.10, 0), (0x8C8C8C, 0, 1)], size: (0.5, 0.4), at: (0.55, 0.95), rotation: 6, blur: 100),
                ]), isLight: true),
        Palette(id: "gazette", name: "Gazette",
                summary: "The morning paper: newsprint grey, black type, one red rule. A briefing, literally.",
                ink: (17, 17, 17), ground: .solid(0xDAD7CF), swatch: 0xDAD7CF, light: .none, isLight: true,
                accent: Color(hex: 0xB3261E), rule: Color(hex: 0xB3261E, alpha: 0.75)),
    ]

    static func byID(_ id: String) -> Palette {
        all.first { $0.id == id } ?? all[0]
    }

    /// Set while onboarding previews a theme that is not saved yet.
    static var override: String?

    /// The palette everything is drawn in right now.
    static var current: Palette {
        byID(override ?? SettingsStore.shared.settings.theme)
    }
}

// MARK: - Lights other than the sun

/// One soft shape of light or shade, in fractions of the screen.
struct Glow: Equatable {
    let stops: [Gradient.Stop]
    let size: CGSize
    let at: CGPoint
    let rotation: Double
    let blur: CGFloat
    let center: UnitPoint
    let end: CGFloat

    init(_ stops: [(UInt32, Double, CGFloat)], size: (CGFloat, CGFloat), at: (CGFloat, CGFloat),
         rotation: Double, blur: CGFloat, center: UnitPoint = .center, end: CGFloat = 0.5) {
        self.stops = stops.map { Gradient.Stop(color: Color(hex: $0.0, alpha: $0.1), location: $0.2) }
        self.size = CGSize(width: size.0, height: size.1)
        self.at = CGPoint(x: at.0, y: at.1)
        self.rotation = rotation
        self.blur = blur
        self.center = center
        self.end = end
    }
}

/// The light themes' light: soft shapes in plain colour over the ground.
struct GlowField: View {
    let size: CGSize
    let glows: [Glow]

    var body: some View {
        let w = size.width, h = size.height
        let s = max(0.05, min(w / 1512, h / 982))
        ZStack(alignment: .topLeading) {
            ForEach(glows.indices, id: \.self) { i in
                let g = glows[i]
                Ellipse()
                    .fill(EllipticalGradient(stops: g.stops, center: g.center,
                                             startRadiusFraction: 0, endRadiusFraction: g.end))
                    .frame(width: w * g.size.width, height: h * g.size.height)
                    .rotationEffect(.degrees(g.rotation))
                    .blur(radius: g.blur * s)
                    .position(x: w * g.at.x, y: h * g.at.y)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Blue Hour: a peach-and-violet glow lying just under the horizon.
struct HorizonGlow: View {
    let size: CGSize

    var body: some View {
        let w = size.width, h = size.height
        let s = max(0.05, min(w / 1512, h / 982))
        ZStack(alignment: .topLeading) {
            LinearGradient(
                stops: [
                    .init(color: Color(.sRGB, red: 150 / 255, green: 110 / 255, blue: 190 / 255, opacity: 0.12), location: 0),
                    .init(color: Color(.sRGB, red: 60 / 255, green: 80 / 255, blue: 150 / 255, opacity: 0.06), location: 0.3),
                    .init(color: Color(.sRGB, red: 60 / 255, green: 80 / 255, blue: 150 / 255, opacity: 0), location: 0.6),
                ],
                startPoint: .bottom, endPoint: .top
            )
            .frame(width: w, height: h)

            Ellipse()
                .fill(EllipticalGradient(
                    stops: [
                        .init(color: Color(.sRGB, red: 1, green: 176 / 255, blue: 150 / 255, opacity: 0.40), location: 0),
                        .init(color: Color(.sRGB, red: 214 / 255, green: 130 / 255, blue: 170 / 255, opacity: 0.28), location: 0.30),
                        .init(color: Color(.sRGB, red: 130 / 255, green: 100 / 255, blue: 190 / 255, opacity: 0.18), location: 0.58),
                        .init(color: Color(.sRGB, red: 50 / 255, green: 70 / 255, blue: 140 / 255, opacity: 0.08), location: 0.82),
                        .init(color: Color(.sRGB, red: 50 / 255, green: 70 / 255, blue: 140 / 255, opacity: 0), location: 1),
                    ],
                    center: UnitPoint(x: 0.46, y: 0.52), startRadiusFraction: 0, endRadiusFraction: 0.6
                ))
                .frame(width: w * 0.92, height: h * 0.54)
                .rotationEffect(.degrees(-4))
                .blur(radius: 70 * s)
                .position(x: w * 0.34, y: h * 0.95)

            Ellipse()
                .fill(EllipticalGradient(
                    stops: [
                        .init(color: Color(.sRGB, red: 1, green: 200 / 255, blue: 170 / 255, opacity: 0.26), location: 0),
                        .init(color: Color(.sRGB, red: 1, green: 200 / 255, blue: 170 / 255, opacity: 0), location: 1),
                    ],
                    center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5
                ))
                .frame(width: w * 0.40, height: h * 0.14)
                .rotationEffect(.degrees(-4))
                .blur(radius: 36 * s)
                .position(x: w * 0.36, y: h * 0.91)
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .drawingGroup()
        .blendMode(.screen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Smoke: no colour, only a slow drift of light and air.
struct SmokeDrift: View {
    let size: CGSize

    var body: some View {
        let w = size.width, h = size.height
        let s = max(0.05, min(w / 1512, h / 982))
        let r = max(w, h)
        ZStack(alignment: .topLeading) {
            RadialGradient(
                stops: [
                    .init(color: Color.white.opacity(0.04), location: 0),
                    .init(color: Color.white.opacity(0), location: 1),
                ],
                center: UnitPoint(x: 0.9, y: 0), startRadius: 0, endRadius: r * 0.6
            )
            .frame(width: w, height: h)

            Ellipse()
                .fill(EllipticalGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.075), location: 0),
                        .init(color: Color.white.opacity(0.035), location: 0.45),
                        .init(color: Color.white.opacity(0), location: 1),
                    ],
                    center: UnitPoint(x: 0.4, y: 0.55), startRadiusFraction: 0, endRadiusFraction: 0.55
                ))
                .frame(width: w * 0.78, height: h * 0.84)
                .rotationEffect(.degrees(14))
                .blur(radius: 80 * s)
                .position(x: w * 0.81, y: h * 0.18)

            Ellipse()
                .fill(EllipticalGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.045), location: 0),
                        .init(color: Color.white.opacity(0), location: 1),
                    ],
                    center: .center, startRadiusFraction: 0, endRadiusFraction: 0.55
                ))
                .frame(width: w * 0.60, height: h * 0.62)
                .rotationEffect(.degrees(-10))
                .blur(radius: 90 * s)
                .position(x: w * 0.20, y: h * 0.79)
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .drawingGroup()
        .blendMode(.screen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
