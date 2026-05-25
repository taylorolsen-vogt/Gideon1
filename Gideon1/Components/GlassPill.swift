import SwiftUI

struct GlassPill: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(AppTheme.textPrimary.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(AppTheme.pillFill)
                    .background(
                        Capsule(style: .continuous).fill(.ultraThinMaterial)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(AppTheme.pillStroke, lineWidth: 1)
                    )
            )
    }
}
