import AppKit
import SwiftUI

/// Design tokens for light and dark. Every colour resolves against the current appearance, so
/// switching the app between Sáng / Tối / Theo hệ thống repaints without rebuilding views.
/// Chrome stays neutral; the brand gradient (from the lens logo) appears only on the logo and the
/// one primary action (Xem trước). Everything selected uses the single accent.
enum Theme {
    // Surfaces
    static let bg = dyn(light: 0xEEF0F4, dark: 0x0A0B0F)            // window
    static let stage = dyn(light: 0xDFE3EA, dark: 0x050608)         // behind the photo
    static let surface = dyn(light: 0xFFFFFF, dark: 0x171A21)       // sheets, selected segments
    static let glass = dyn(light: 0xFFFFFF, 0.72, dark: 0x1C1F28, 0.74) // dock, drawer (over a material)
    static let chip = dyn(light: 0x0F172A, 0.05, dark: 0xFFFFFF, 0.06)  // control wells, cards
    static let chipHover = dyn(light: 0x0F172A, 0.09, dark: 0xFFFFFF, 0.10)
    static let track = dyn(light: 0x0F172A, 0.10, dark: 0xFFFFFF, 0.10)
    static let line = dyn(light: 0x0F172A, 0.08, dark: 0xFFFFFF, 0.08)
    static let line2 = dyn(light: 0x0F172A, 0.12, dark: 0xFFFFFF, 0.14)
    static let shadow = dyn(light: 0x1E293B, 0.18, dark: 0x000000, 0.55)

    // Selected segment: ink on light, white on dark
    static let inverse = dyn(light: 0x0F172A, dark: 0xFFFFFF)
    static let onInverse = dyn(light: 0xFFFFFF, dark: 0x0B0D12)

    static let textPrimary = dyn(light: 0x0F172A, dark: 0xF2F4F8)
    static let textSecondary = dyn(light: 0x4B5565, dark: 0xA2A9B6)
    static let textTertiary = dyn(light: 0x8A93A3, dark: 0x6B7280)

    // One blue-violet for every selected state, slider fill and focus ring
    static let accent = Color(hex: 0x6366F1)
    static let accentSoft = Color(hex: 0x6366F1).opacity(0.14)
    static let danger = Color(hex: 0xEF4444)
    static let success = Color(hex: 0x10B981)

    static let brandColors: [Color] = [Color(hex: 0x22D3EE), Color(hex: 0x3B82F6), Color(hex: 0x8B5CF6), Color(hex: 0xEC4899)]
    static let brand = LinearGradient(colors: brandColors, startPoint: .leading, endPoint: .trailing)
    static let brandRing = AngularGradient(colors: brandColors + [brandColors[0]], center: .center)

    // Radius scale: 8 controls, 12 segments, 16 cards, 20 dock / drawer / stage
    static let radiusControl: CGFloat = 8
    static let radiusSegment: CGFloat = 12
    static let radiusCard: CGFloat = 16
    static let radiusPanel: CGFloat = 20

    // Old names still used by the update sheet
    static var base: Color { surface }
    static var panel: Color { chip }

    private static func dyn(light: UInt32, _ la: Double = 1, dark: UInt32, _ da: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? da : la)
        })
    }
}

/// Theo hệ thống / Sáng / Tối, kept in UserDefaults and applied to NSApp.
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { self == .system ? "Theo hệ thống" : self == .light ? "Sáng" : "Tối" }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: CGFloat(alpha))
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

extension View {
    /// Frosted panel: system material under a light/dark tint, hairline edge, soft shadow.
    func glassPanel(radius: CGFloat = Theme.radiusPanel) -> some View {
        self.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.glass))
        }
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.line2))
        .shadow(color: Theme.shadow, radius: 24, y: 12)
    }

    /// Group card inside the drawer.
    func card() -> some View {
        self.padding(12)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
    }
}
