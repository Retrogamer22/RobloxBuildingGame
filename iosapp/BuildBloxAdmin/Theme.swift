import SwiftUI

/// BuildBlox Admin design system, ported 1:1 from the dashboard CSS `:root`.
/// Dark "developer console" look: near-black bg, faint blue grid, glassy cards,
/// one blue accent, semantic red/amber/green.
enum Theme {
    // MARK: Colors (hex from the original CSS variables)
    static let bg           = Color(hex: 0x07090F)
    static let bgElevated   = Color(hex: 0x0D111C)
    static let bgCard       = Color(hex: 0x111624).opacity(0.53) // #11162488
    static let bgCardSolid  = Color(hex: 0x111624)
    static let bgInput      = Color(hex: 0x161C2E)
    static let bgInputFocus = Color(hex: 0x1A2238)
    static let border       = Color(hex: 0x1F2740)
    static let borderBright  = Color(hex: 0x2A3550)
    static let text         = Color(hex: 0xE8ECF5)
    static let textDim      = Color(hex: 0x7A83A0)
    static let textFaint    = Color(hex: 0x4A5170)
    static let accent       = Color(hex: 0x5BB0FF)
    static let danger       = Color(hex: 0xFF6464)
    static let warning      = Color(hex: 0xFFC266)
    static let success      = Color(hex: 0x5FC97A)
    static let gridLine     = Color(hex: 0x5BB0FF).opacity(0.04)

    // MARK: Shape
    static let radius: CGFloat = 10
    static let radiusLarge: CGFloat = 14

    // MARK: Fonts
    // Bundle Bricolage Grotesque / Manrope / JetBrains Mono for an exact match, or
    // use these system fallbacks. Mono is used for all metric numbers.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    /// Build a Color from a 0xRRGGBB integer literal.
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// Glassy card container matching the dashboard's card style.
struct CardModifier: ViewModifier {
    var solid: Bool = false
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(solid ? Theme.bgCardSolid : Theme.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle(solid: Bool = false) -> some View { modifier(CardModifier(solid: solid)) }
}
