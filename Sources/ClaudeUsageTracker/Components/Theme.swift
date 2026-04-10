import SwiftUI

enum Theme {
    // Fiskaly brand palette (from design-tokens.yaml)
    static let accent = Color(hex: 0x2DD4BF)             // Teal — signature brand color
    static let accentBright = Color(hex: 0x5EE8D5)       // Teal bright
    static let accentDim = Color(hex: 0x2DD4BF, opacity: 0.19) // Teal dim

    // Status colors (Fiskaly semantic palette)
    static let barSafe = Color(hex: 0x2DD4BF)            // Teal (on-brand safe)
    static let barWarning = Color(hex: 0xFDDD00)          // Amber
    static let barDanger = Color(hex: 0xFF9696)           // Red (90%+)
    static let barCritical = Color(hex: 0xFF6B6B)         // Stronger red (95%+)
    static let barMaxed = Color(hex: 0xFF4444)            // Vivid red (100%)

    // Background layers (Fiskaly dark palette: bunker → deep → surface)
    static let bgPrimary = Color(hex: 0x0F181B)          // Bunker
    static let bgCard = Color(hex: 0x171F24)             // Deep
    static let bgCardHover = Color(hex: 0x232A30)        // Surface

    // Text hierarchy
    static let textPrimary = Color(hex: 0xEFF1F3)        // Text
    static let textSecondary = Color(hex: 0x8B9299)      // Text dim
    static let textTertiary = Color(hex: 0x545B6F)       // Muted

    // Derived opacity variants
    static let textHint = textTertiary.opacity(0.6)
    static let accentBadgeBg = accent.opacity(0.15)
    static let dividerSubtle = Color.white.opacity(0.08)

    // Bar track
    static let barTrack = Color(hex: 0x2D353C)           // Surface 2

    // Model-specific colors
    static let opusColor = Color(hex: 0xFDDD00)          // Amber (premium)
    static let sonnetColor = Color(hex: 0xB6D2FF)        // Blue
    static let haikuColor = Color(hex: 0x99F6E4)         // Green/mint

    static func colorForModel(_ modelId: String) -> Color {
        if modelId.contains("opus") { return opusColor }
        if modelId.contains("sonnet") { return sonnetColor }
        if modelId.contains("haiku") { return haikuColor }
        return textSecondary
    }

    static func barColor(for percentage: Double) -> Color {
        if percentage >= 100 { return barMaxed }
        if percentage >= 95 { return barCritical }
        if percentage >= 90 { return barDanger }
        if percentage >= 70 { return barWarning }
        return barSafe
    }
}

// Hex color initializer
extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
