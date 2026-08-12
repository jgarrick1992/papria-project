import SwiftUI

/// The shared normal-display palette and layout constants for Papria 0.1.0.
/// Values intentionally mirror `docs/papria-ui-design/design-tokens.md`.
enum PapriaDesign {
    // MARK: - Normal display colour tokens

    static let canvas = Color(hex: 0xF7F2E8)
    static let raised = Color(hex: 0xFFFCF6)
    static let ink = Color(hex: 0x20221F)
    static let inkSecondary = Color(hex: 0x6F6C63)
    static let inkDisabled = Color(hex: 0x9B978D)
    static let lineSubtle = Color(hex: 0xD8D0C3)
    static let accent = Color(hex: 0xB74632)
    static let actionPressed = Color(hex: 0x8F3425)
    static let success = Color(hex: 0x2D7168)
    static let remote = Color(hex: 0x3D668B)
    static let warning = Color(hex: 0x9C661A)
    static let error = Color(hex: 0xB74632)
    static let focusRing = Color(hex: 0x3D668B)

    // `paper` remains the reader-facing name used by the existing reader
    // surface. It is the 0.1.0 paper.canvas token, not a platform default.
    static let paper = canvas

    // MARK: - Layout tokens

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 24
    static let space6: CGFloat = 32
    static let pageHorizontalInset: CGFloat = 16
    static let minimumHitTarget: CGFloat = 44
    static let ruleWidth: CGFloat = 1
    static let controlCornerRadius: CGFloat = 6
    static let panelCornerRadius: CGFloat = 8

    // MARK: - Dynamic Type typography tokens

    /// Semantic text styles keep the documented default point sizes while
    /// allowing iOS to scale them for the user's preferred text size:
    /// title2=22pt, headline=17pt, callout=16pt, footnote=13pt and
    /// caption=12pt at the default Dynamic Type setting.
    ///
    /// Do not replace these with `Font.system(size:)`: that form freezes text
    /// at a single point size and breaks the accessibility text-size setting.
    static let navigationTitle = Font.system(.title2, design: .default).weight(.semibold)
    static let sectionTitle = Font.system(.headline, design: .default).weight(.semibold)
    static let detailTitle = Font.system(.title3, design: .default).weight(.semibold)
    static let rowBody = Font.system(.callout, design: .default)
    static let metadata = Font.system(.footnote, design: .default)
    static let label = Font.system(.caption, design: .default).weight(.medium)
    static let badgeLabel = Font.system(.caption2, design: .default).weight(.bold)
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
