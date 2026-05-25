import SwiftUI

struct Eyebrow: View {
    let text: String
    var size: CGFloat = 11
    var color: Color = AppTheme.textTertiary

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .medium))
            .tracking(2.4)
            .foregroundStyle(color)
    }
}

struct PageTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 34, weight: .light))
            .tracking(1.5)
            .foregroundStyle(AppTheme.textPrimary)
    }
}
