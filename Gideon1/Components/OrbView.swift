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
            let time = baseTime * 1.78

            let centerX = Float(size * 0.5)
            let centerY = Float(size * 0.5)
            let radius = Float(size * 0.49)
            let strength = Float(size * 0.0235)
            let maxOffset = CGFloat(strength) * 3.0

            ZStack {
                Image("orbTexture")
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .saturation(0.60)
                    .contrast(0.96)
                    .brightness(0.06)
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
                                Color.white.opacity(0.68),
                                Color(red: 0.66, green: 0.88, blue: 1.0).opacity(0.48),
                                Color(red: 0.78, green: 0.62, blue: 0.98).opacity(0.34),
                                Color.white.opacity(0.60)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: max(1.2, size * 0.008)
                    )
                    .blur(radius: 0.4)

                // Chromatic ring lift to make blue/purple read more clearly.
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [
                                Color(red: 0.60, green: 0.84, blue: 1.0).opacity(0.16),
                                Color(red: 0.76, green: 0.60, blue: 0.98).opacity(0.15),
                                Color(red: 0.56, green: 0.90, blue: 1.0).opacity(0.14),
                                Color(red: 0.60, green: 0.84, blue: 1.0).opacity(0.16)
                            ],
                            center: .center
                        ),
                        lineWidth: max(1.4, size * 0.008)
                    )
                    .blendMode(.screen)
                    .blur(radius: 0.5)

                // Subtle specular highlight.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.47), Color.clear],
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
            .shadow(color: Color.white.opacity(0.11), radius: size * 0.018)
            .shadow(color: Color.black.opacity(0.03), radius: 12, x: 0, y: 6)
        }
        .frame(width: size, height: size)
    }
}

