#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Distortion-only fluid simulation. The orb stays anchored; only the
// interior of the surface pushes, pulls, rises, falls and curls like
// a ball of water in zero-g.
[[ stitchable ]] float2 orbDistort(
    float2 position,
    float2 center,
    float radius,
    float time,
    float strength
) {
    float2 delta = position - center;
    float dist = length(delta);
    if (dist > radius || radius <= 0.0001) {
        return position;
    }

    float r = dist / radius;
    float interior = 1.0 - smoothstep(0.84, 1.0, r);
    float2 dir = (dist > 0.0001) ? delta / dist : float2(0.0, 0.0);

        float2 tangent = float2(-dir.y, dir.x);
        float angle = atan2(dir.y, dir.x);
        float core = (1.0 - r);

        // Directional pressure gives push/pull pockets without uniform breathing.
        float pressure = (sin(angle * 2.0 + time * 0.82 + r * 3.2)
                                        + cos(angle * 3.0 - time * 0.66 - r * 2.4)) * 0.5;
        float2 radialFlow = dir * pressure * core * 0.55;

        // Clear coherent spin: tangential flow with slow modulation.
        float spinSpeed = 0.95 + 0.22 * sin(time * 0.24);
        float2 spinFlow = tangent * spinSpeed * core * 0.92;

        // Rise/fall with phase shift across the body.
        float verticalPhase = sin(delta.x * 0.022 + time * 0.88)
                                                * cos(delta.y * 0.018 - time * 0.52);
        float2 verticalBias = float2(0.0, -1.0) * verticalPhase * core * 0.50;

        // Multi-octave turbulence (dimensionless field).
        float2 p1 = delta * 0.020 + float2(time * 0.26, time * 0.18);
        float2 p2 = delta * 0.038 - float2(time * 0.17, time * 0.29);
        float2 p3 = delta * 0.064 + float2(-time * 0.11, time * 0.13);

        float2 warp = float2(
                sin(p1.x + cos(p1.y * 1.2)) * 0.52
            + sin(p2.x * 1.4 - p2.y * 0.9 + time * 0.35) * 0.30
            + sin(p3.x * 1.9 + p3.y * 0.6) * 0.18,
                cos(p1.y - sin(p1.x * 1.1)) * 0.52
            + cos(p2.y * 1.3 + p2.x * 0.7 - time * 0.31) * 0.30
            + cos(p3.y * 1.8 - p3.x * 0.5) * 0.18
        );

        // Local curl adds shearing pockets.
        float curl = sin(time * 0.42 + angle * 1.6 + r * 4.2);
        float2 curlFlow = tangent * curl * core * 0.35;

        // Keep offsets bounded: all flow fields are unit-ish, scaled once by strength.
        float2 flow = radialFlow + spinFlow + verticalBias + warp * 0.72 + curlFlow;
        float2 offset = flow * strength;

    offset *= interior;

    return position - offset;
}

// Optional refraction shader (kept available for later).
[[ stitchable ]] half4 orbRefract(
    float2 position,
    SwiftUI::Layer layer,
    float2 center,
    float radius,
    float time,
    float strength
) {
    float2 delta = position - center;
    float dist = length(delta);
    half4 base = layer.sample(position);
    if (dist > radius) {
        return base;
    }
    float bend = 1.0 - dist / radius;
    float2 dir = (dist > 0.0001) ? delta / dist : float2(0.0, 0.0);
    float2 offset = dir * bend * strength;
    half4 refracted = layer.sample(position - offset);
    return mix(base, refracted, half(0.5));
}
