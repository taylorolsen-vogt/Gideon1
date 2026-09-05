import SwiftUI

struct GlassCard<Content: View>: View {
    var corner: CGFloat = 22
    var padding: CGFloat = 18
    var fillWidth: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if fillWidth {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                content()
            }
        }
            .padding(padding)
            .background {
                let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)

                shape
                    .fill(.ultraThinMaterial)
                    .opacity(0.22)
                    .overlay(
                        shape.fill(AppTheme.cardFill)
                    )
                    .overlay(
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.18),
                                    Color.white.opacity(0.05),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
                    .overlay(
                        shape
                            .inset(by: 0.7)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.92),
                                        Color.white.opacity(0.36),
                                        Color.white.opacity(0.14)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .overlay(
                        shape
                            .inset(by: 1.8)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                            .blendMode(.screen)
                    )
                    .overlay(
                        shape
                            .strokeBorder(Color.black.opacity(0.035), lineWidth: 0.6)
                            .blur(radius: 0.5)
                            .offset(x: 0, y: 1)
                            .mask(shape)
                    )
                    .shadow(color: Color.white.opacity(0.24), radius: 2, x: -1, y: -1)
                    .shadow(color: AppTheme.cardShadow, radius: 18, x: 0, y: 8)
            }
    }
}
