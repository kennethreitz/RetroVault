#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

/// Builds a non-destructive CRT glass overlay for the native Big Picture
/// interface.
///
/// Sampling the composed hierarchy would force SwiftUI's lazy scrolling
/// content into a single offscreen layer. Keeping the shader independent of
/// that content preserves native scrolling and aligns its mask directly to
/// physical display pixels.
[[ stitchable ]] half4 openVaultBigPictureCRTOverlay(
    float2 position,
    half4 source,
    float2 size,
    float displayScale,
    float curvature
) {
    float2 safeSize = max(size, float2(1.0));
    float2 textureCoordinate = position / safeSize;
    float glass = 1.0;

    if (curvature > 0.5) {
        float2 centered = textureCoordinate * 2.0 - 1.0;
        float radiusSquared = dot(centered, centered) * 0.5;
        float vignette = 1.0 - 0.18 * radiusSquared * radiusSquared;
        float2 roundedEdge = max(
            abs(centered) - float2(0.92, 0.88),
            0.0
        );
        float corner = 1.0 - 0.24 * smoothstep(
            0.0,
            0.12,
            length(roundedEdge)
        );
        glass = vignette * corner;
    }

    float2 displayPixel = position * max(displayScale, 1.0);

    // One darker physical row followed by one bright row gives the interface
    // a scanline texture without softening its type.
    float scanlinePhase = fmod(floor(displayPixel.y), 2.0);
    float scanline = mix(0.84, 1.0, scanlinePhase);

    // Align an RGB aperture-grille triad to physical pixels. Keep the
    // non-emitting channels fairly bright so white text remains readable.
    uint phosphor = uint(max(floor(displayPixel.x), 0.0)) % 3;
    float3 phosphorMask;
    if (phosphor == 0) {
        phosphorMask = float3(1.0, 0.88, 0.88);
    } else if (phosphor == 1) {
        phosphorMask = float3(0.88, 1.0, 0.88);
    } else {
        phosphorMask = float3(0.88, 0.88, 1.0);
    }

    source.rgb = half3(phosphorMask * scanline * glass);
    source.a = 1.0h;
    return source;
}
