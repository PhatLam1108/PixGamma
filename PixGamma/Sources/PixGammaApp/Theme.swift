import SwiftUI

/// Design tokens. One neutral graphite family, one accent, one radius scale.
/// Photo tools keep chrome neutral so the UI never tints how the image is judged.
enum Theme {
    // Surfaces, darkest to lightest
    static let canvas = Color(red: 0.075, green: 0.078, blue: 0.086)      // behind the image
    static let base = Color(red: 0.106, green: 0.110, blue: 0.122)        // window
    static let panel = Color(red: 0.137, green: 0.141, blue: 0.157)       // sidebars
    static let raised = Color(red: 0.176, green: 0.180, blue: 0.200)      // controls, cards
    static let hover = Color(red: 0.215, green: 0.220, blue: 0.243)
    static let hairline = Color.white.opacity(0.07)

    static let textPrimary = Color(red: 0.93, green: 0.94, blue: 0.95)
    static let textSecondary = Color(red: 0.64, green: 0.66, blue: 0.70)
    static let textTertiary = Color(red: 0.47, green: 0.49, blue: 0.53)

    /// Single accent: cobalt. Used for selection, primary action and slider fill only.
    static let accent = Color(red: 0.30, green: 0.55, blue: 1.00)
    static let accentSoft = Color(red: 0.30, green: 0.55, blue: 1.00).opacity(0.16)
    static let danger = Color(red: 0.94, green: 0.36, blue: 0.36)
    static let success = Color(red: 0.33, green: 0.80, blue: 0.55)

    // Radius scale: 6 for controls, 10 for cards/panels, capsule for chips
    static let radiusControl: CGFloat = 6
    static let radiusCard: CGFloat = 10

    static let inspectorWidth: CGFloat = 300
    static let sidebarWidth: CGFloat = 232
}

extension View {
    func panelCard() -> some View {
        self.padding(12)
            .background(Theme.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.radiusCard))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).strokeBorder(Theme.hairline))
    }
}
