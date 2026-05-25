import SwiftUI

/// Small dark rounded square containing a minimal bot face — used for the Agent card icon.
struct BotMark: View {
    var size: CGFloat = 44
    var corner: CGFloat = 10

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(AppTheme.darkBlock)

            // Antenna dot.
            Circle()
                .fill(Color.white)
                .frame(width: size * 0.085, height: size * 0.085)
                .offset(y: -size * 0.36)

            // Antenna line.
            Rectangle()
                .fill(Color.white)
                .frame(width: 1.2, height: size * 0.10)
                .offset(y: -size * 0.28)

            // Face block.
            RoundedRectangle(cornerRadius: size * 0.10, style: .continuous)
                .fill(Color.white.opacity(0.0))
                .frame(width: size * 0.62, height: size * 0.48)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.6)
                )

            // Eyes.
            HStack(spacing: size * 0.12) {
                Circle().fill(Color.white).frame(width: size * 0.08, height: size * 0.08)
                Circle().fill(Color.white).frame(width: size * 0.08, height: size * 0.08)
            }
            .offset(y: size * 0.02)
        }
        .frame(width: size, height: size)
    }
}

/// Small bot icon used in the bottom tab strip.
struct BotTabMark: View {
    var size: CGFloat = 26
    var color: Color = AppTheme.textPrimary
    private let accent = Color(red: 0.33, green: 0.63, blue: 0.98)

    var body: some View {
        ZStack {
            // Antenna ring and stem.
            Circle()
                .stroke(color, lineWidth: size * 0.070)
                .frame(width: size * 0.12, height: size * 0.12)
                .offset(y: -size * 0.45)

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color)
                .frame(width: size * 0.055, height: size * 0.11)
                .offset(y: -size * 0.33)

            // Side arm stubs.
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color)
                .frame(width: size * 0.11, height: size * 0.070)
                .offset(x: -size * 0.37, y: size * 0.00)

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color)
                .frame(width: size * 0.11, height: size * 0.070)
                .offset(x: size * 0.37, y: size * 0.00)

            // Head.
            RoundedRectangle(cornerRadius: size * 0.17, style: .continuous)
                .stroke(color, lineWidth: size * 0.085)
                .frame(width: size * 0.58, height: size * 0.58)

            // Eyes.
            HStack(spacing: size * 0.13) {
                Circle()
                    .fill(accent)
                    .frame(width: size * 0.075, height: size * 0.075)
                Circle()
                    .fill(accent)
                    .frame(width: size * 0.075, height: size * 0.075)
            }
            .offset(y: -size * 0.005)
        }
        .frame(width: size * 1.10, height: size * 1.16)
    }
}
