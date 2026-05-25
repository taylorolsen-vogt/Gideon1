import SwiftUI

/// Anchored water orb. The orb stays fixed; its interior pushes, pulls,
/// rises and falls like a ball of water in zero-g. The `orbTexture`
/// asset is mapped directly to the orb surface.
struct OrbView: View {
    var size: CGFloat = 380

    var body: some View {
        TimelineView(.animation) { context in
            // Modulo to keep Metal float precision usable.
            let rawTime = context.date.timeIntervalSinceReferenceDate
            let baseTime = Float(rawTime.truncatingRemainder(dividingBy: 1000))
            let time = baseTime * 2.15

            let centerX = Float(size * 0.5)
            let centerY = Float(size * 0.5)
            let radius = Float(size * 0.49)
            let strength = Float(size * 0.027)
            let maxOffset = CGFloat(strength) * 3.0

            ZStack {
                Image("orbTexture")
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .saturation(0.62)
                    .frame(width: size, height: size)
                    .distortionEffect(
                        ShaderLibrary.orbDistort(
                            .float2(centerX, centerY),
                            .float(radius),
                            .float(time),
                            .float(strength)
                        ),
                        maxSampleOffset: CGSize(width: maxOffset, height: maxOffset)
                    )
                    .clipShape(Circle())

                // Rim sheen — keeps it reading as a wet sphere.
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.55),
                                Color(red: 0.78, green: 0.92, blue: 1.0).opacity(0.30),
                                Color.white.opacity(0.45)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: max(1.2, size * 0.008)
                    )
                    .blur(radius: 0.4)

                // Subtle specular highlight.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.35), Color.clear],
                            center: .init(x: 0.32, y: 0.28),
                            startRadius: 1,
                            endRadius: size * 0.22
                        )
                    )
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            }
            .frame(width: size, height: size)
            .compositingGroup()
            .shadow(color: Color.white.opacity(0.06), radius: size * 0.018)
            .shadow(color: Color.black.opacity(0.05), radius: 12, x: 0, y: 6)
        }
        .frame(width: size, height: size)
    }
}

