import SwiftUI

struct CollapseChevron: View {
    var isCollapsed: Bool = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.55))
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().strokeBorder(AppTheme.pillStroke, lineWidth: 1))
                    .frame(width: 28, height: 28)
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .rotationEffect(.degrees(isCollapsed ? 180 : 0))
            }
        }
        .buttonStyle(.plain)
    }
}
