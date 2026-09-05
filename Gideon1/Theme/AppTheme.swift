import SwiftUI

enum AppTheme {
    // Background — light cool gray, slightly brighter.
    static let background = Color(red: 0.972, green: 0.972, blue: 0.982)

    // Card surface — translucent liquid glass over the app background.
    static let cardFill = Color.white.opacity(0.035)
    static let cardStroke = Color.white.opacity(0.82)
    static let cardShadow = Color.black.opacity(0.055)

    // Text.
    static let textPrimary = Color(red: 0.07, green: 0.08, blue: 0.10)
    static let textSecondary = Color(red: 0.07, green: 0.08, blue: 0.10).opacity(0.64)
    static let textTertiary = Color(red: 0.07, green: 0.08, blue: 0.10).opacity(0.42)
    static let textMuted = Color(red: 0.07, green: 0.08, blue: 0.10).opacity(0.30)

    // Accents.
    static let statusGreen = Color(red: 0.20, green: 0.78, blue: 0.46)
    static let statusOrange = Color(red: 0.92, green: 0.58, blue: 0.20)

    // Pill / dark blocks.
    static let darkBlock = Color(red: 0.10, green: 0.11, blue: 0.13)
    static let pillFill = Color.white.opacity(0.55)
    static let pillStroke = Color.black.opacity(0.06)

    // Divider.
    static let divider = Color.black.opacity(0.08)
}
