#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

/// Applies the selected CRT treatment to the native Big Picture interface.
///
/// `colorEffect` supplies the menu's actual source color without requiring a
/// sampled offscreen texture. That preserves native lazy scrolling while
/// allowing the shader to use the same linear-light scanline and RGB-slot
/// treatment as gameplay.
[[ stitchable ]] half4 openVaultBigPictureCRT(
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

    float2 physicalPixel = position * max(displayScale, 1.0);

    // Match the gameplay shader's two-pixel RGB slots, staggered every bank.
    uint pixelX = uint(floor(max(physicalPixel.x, 0.0)));
    uint pixelY = uint(floor(max(physicalPixel.y, 0.0)));
    uint rowInBank = pixelY % 3u;
    uint bank = (pixelY / 3u) % 2u;
    uint shiftedX = pixelX + bank * 2u;
    uint phosphor = (shiftedX / 2u) % 3u;

    float3 phosphorMask = float3(0.78);
    if (phosphor == 0u) {
        phosphorMask.r = 1.22;
    } else if (phosphor == 1u) {
        phosphorMask.g = 1.22;
    } else {
        phosphorMask.b = 1.22;
    }
    if (rowInBank == 2u) {
        phosphorMask *= 0.78;
    }
    phosphorMask = mix(float3(1.0), phosphorMask * 1.165, 0.72);

    // A four-physical-pixel beam approximates a 240-line source at common
    // Big Picture sizes. It is the same Gaussian beam used by the flat
    // gameplay CRT, fixed in display space because vector UI has no source
    // raster height from which to derive a scale.
    float scanlinePhase = fract(physicalPixel.y / 4.0);
    float distanceFromCenter = scanlinePhase - 0.5;
    float scanline = exp2(-8.0 * distanceFromCenter * distanceFromCenter);
    scanline = mix(1.0, scanline, 0.34);

    float3 color = pow(max(float3(source.rgb), 0.0), float3(2.2));
    color *= scanline;
    color *= phosphorMask;
    color *= 1.18 * glass;

    source.rgb = half3(pow(max(color, 0.0), float3(1.0 / 2.2)));
    return source;
}
