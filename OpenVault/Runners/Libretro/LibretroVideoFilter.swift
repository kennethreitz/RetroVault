import Foundation

/// How a core's frame is resampled on its way to the display.
///
/// Every filter here is a single fragment pass over the frame the core just
/// handed over. That matters for a runtime that treats input latency as the
/// thing it will not trade away: a one-pass filter still resolves into the
/// same drawable in the same command buffer, so it costs microseconds of GPU
/// time and never an extra frame of presentation delay. A multi-pass chain
/// would need an intermediate render target, which is why none of these use
/// one.
enum LibretroVideoFilter: String, CaseIterable, Identifiable, Sendable {
    /// Point sampling. Exact at whole-number scales, uneven below them.
    case nearest

    /// Point sampling with the pixel edges — and only the edges — resolved.
    case sharpBilinear = "sharp-bilinear"

    /// Hyllian's xBR-lv2, which follows edges rather than pixel boundaries.
    case xbr

    /// Scanlines and a phosphor mask over a sharp-bilinear resample.
    case crt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nearest:
            "Off"
        case .sharpBilinear:
            "Sharp Bilinear"
        case .xbr:
            "xBR"
        case .crt:
            "CRT"
        }
    }

    var summary: String {
        switch self {
        case .nearest:
            "No filtering. Nearest-neighbor point sampling, with hard pixel "
                + "edges, exactly as the core drew the frame."
        case .sharpBilinear:
            "Softens only the seams between pixels, so off-multiple window "
                + "sizes stop shimmering without blurring the art."
        case .xbr:
            "Reshapes pixel-art edges into curves and diagonals. Suits 2D "
                + "games; leaves 3D cores looking waxy."
        case .crt:
            "Scanlines and a phosphor mask, approximating a consumer CRT."
        }
    }

    /// The Metal fragment function that implements this filter.
    var fragmentFunctionName: String {
        switch self {
        case .nearest:
            "openVaultNearestFragment"
        case .sharpBilinear:
            "openVaultSharpBilinearFragment"
        case .xbr:
            "openVaultXBRFragment"
        case .crt:
            "openVaultCRTFragment"
        }
    }
}

enum LibretroVideoPreferences {
    static let filterKey = "libretro.video.filter.v1"

    /// Point sampling stays the default because it is what the runtime has
    /// always done, and because `LibretroVideoLayout.viewport` already snaps
    /// square-pixel cores to whole-number scales where point sampling is
    /// exactly right. The other filters are opt-in.
    static let defaultFilter = LibretroVideoFilter.nearest

    static func filter(
        from defaults: UserDefaults = .standard
    ) -> LibretroVideoFilter {
        guard
            let raw = defaults.string(forKey: filterKey),
            let filter = LibretroVideoFilter(rawValue: raw)
        else {
            return defaultFilter
        }
        return filter
    }
}

/// Sizes the filters need in order to know how far apart the source pixels
/// land on screen. Laid out to match `OpenVaultVideoUniforms` in the shader.
struct LibretroVideoUniforms: Equatable {
    var sourceWidth: Float = 0
    var sourceHeight: Float = 0
    var targetWidth: Float = 0
    var targetHeight: Float = 0
}

enum LibretroMetalShader {
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct OpenVaultPixelVertex {
            float4 position [[position]];
            float2 textureCoordinate;
        };

        struct OpenVaultVideoUniforms {
            float sourceWidth;
            float sourceHeight;
            float targetWidth;
            float targetHeight;
        };

        constexpr sampler openVaultPointSampler(
            coord::normalized,
            address::clamp_to_edge,
            mag_filter::nearest,
            min_filter::nearest,
            mip_filter::none
        );

        constexpr sampler openVaultLinearSampler(
            coord::normalized,
            address::clamp_to_edge,
            mag_filter::linear,
            min_filter::linear,
            mip_filter::none
        );

        vertex OpenVaultPixelVertex openVaultPixelVertex(
            uint vertexID [[vertex_id]]
        ) {
            constexpr float2 positions[] = {
                float2(-1.0, -1.0),
                float2( 1.0, -1.0),
                float2(-1.0,  1.0),
                float2( 1.0,  1.0)
            };
            constexpr float2 textureCoordinates[] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };

            OpenVaultPixelVertex output;
            output.position = float4(positions[vertexID], 0.0, 1.0);
            output.textureCoordinate = textureCoordinates[vertexID];
            return output;
        }

        fragment float4 openVaultNearestFragment(
            OpenVaultPixelVertex input [[stage_in]],
            texture2d<float> frame [[texture(0)]]
        ) {
            return frame.sample(openVaultPointSampler, input.textureCoordinate);
        }

        // Themaister's sharp-bilinear. Walks the sample point to the middle of
        // whichever source pixel contains it, except within one output pixel
        // of a seam, where it sweeps across to the neighbour. At whole-number
        // scales the sweep is narrower than an output pixel and the result is
        // indistinguishable from point sampling; below them it replaces the
        // duplicated-pixel-column shimmer with a one-pixel ramp.
        static float4 openVaultSharpBilinear(
            float2 textureCoordinate,
            texture2d<float> frame,
            constant OpenVaultVideoUniforms &uniforms
        ) {
            float2 sourceSize = float2(
                uniforms.sourceWidth,
                uniforms.sourceHeight
            );
            float2 targetSize = float2(
                uniforms.targetWidth,
                uniforms.targetHeight
            );
            float2 scale = max(floor(targetSize / sourceSize), float2(1.0));

            float2 texel = textureCoordinate * sourceSize;
            float2 texelFloored = floor(texel);
            float2 subpixel = fract(texel);
            float2 regionRange = 0.5 - 0.5 / scale;
            float2 centerDistance = subpixel - 0.5;
            float2 swept =
                (centerDistance
                    - clamp(centerDistance, -regionRange, regionRange))
                * scale
                + 0.5;

            return frame.sample(
                openVaultLinearSampler,
                (texelFloored + swept) / sourceSize
            );
        }

        fragment float4 openVaultSharpBilinearFragment(
            OpenVaultPixelVertex input [[stage_in]],
            texture2d<float> frame [[texture(0)]],
            constant OpenVaultVideoUniforms &uniforms [[buffer(0)]]
        ) {
            return openVaultSharpBilinear(
                input.textureCoordinate,
                frame,
                uniforms
            );
        }

        // Hyllian's xBR-lv2, ported from the reference GLSL with its stock
        // parameters: CORNER_C detection, SMOOTH_TIPS on, small_details off,
        // Y weight 48, equality threshold 15, level-2 coefficient 2.
        //
        // Copyright (C) 2011-2016 Hyllian <sergiogdb@gmail.com>, MIT licensed.
        // The reference shader precomputes its 5x5 neighbourhood as vertex
        // varyings; sampling those offsets here in the fragment stage is the
        // only structural change.
        constant float3 openVaultXBRWeights = float3(14.352, 28.176, 5.472);
        constant float openVaultXBREqThreshold = 15.0;
        constant float openVaultXBRLv2Coefficient = 2.0;
        constant float openVaultXBRScale = 3.0;

        constant float4 openVaultXBRAo = float4( 1.0, -1.0, -1.0,  1.0);
        constant float4 openVaultXBRBo = float4( 1.0,  1.0, -1.0, -1.0);
        constant float4 openVaultXBRCo = float4( 1.5,  0.5, -0.5,  0.5);
        constant float4 openVaultXBRAx = float4( 1.0, -1.0, -1.0,  1.0);
        constant float4 openVaultXBRBx = float4( 0.5,  2.0, -0.5, -2.0);
        constant float4 openVaultXBRCx = float4( 1.0,  1.0, -0.5,  0.0);
        constant float4 openVaultXBRAy = float4( 1.0, -1.0, -1.0,  1.0);
        constant float4 openVaultXBRBy = float4( 2.0,  0.5, -2.0, -0.5);
        constant float4 openVaultXBRCy = float4( 2.0,  0.0, -1.0,  0.5);
        constant float4 openVaultXBRCi = float4(0.25, 0.25, 0.25, 0.25);

        static float4 openVaultXBRDf(float4 a, float4 b) {
            return abs(a - b);
        }

        static float4 openVaultXBRDiff(float4 a, float4 b) {
            return float4(a.x != b.x, a.y != b.y, a.z != b.z, a.w != b.w);
        }

        static float4 openVaultXBREq(float4 a, float4 b) {
            return step(
                openVaultXBRDf(a, b),
                float4(openVaultXBREqThreshold)
            );
        }

        static float4 openVaultXBRNeq(float4 a, float4 b) {
            return float4(1.0) - openVaultXBREq(a, b);
        }

        static float4 openVaultXBRWd(
            float4 a, float4 b, float4 c, float4 d,
            float4 e, float4 f, float4 g, float4 h
        ) {
            return openVaultXBRDf(a, b)
                + openVaultXBRDf(a, c)
                + openVaultXBRDf(d, e)
                + openVaultXBRDf(d, f)
                + 4.0 * openVaultXBRDf(g, h);
        }

        static float openVaultXBRColorDf(float3 c1, float3 c2) {
            float3 d = abs(c1 - c2);
            return d.r + d.g + d.b;
        }

        fragment float4 openVaultXBRFragment(
            OpenVaultPixelVertex input [[stage_in]],
            texture2d<float> frame [[texture(0)]],
            constant OpenVaultVideoUniforms &uniforms [[buffer(0)]]
        ) {
            float2 sourceSize = float2(
                uniforms.sourceWidth,
                uniforms.sourceHeight
            );
            float dx = 1.0 / sourceSize.x;
            float dy = 1.0 / sourceSize.y;
            float2 uv = input.textureCoordinate;
            float2 fp = fract(uv * sourceSize);

            float4 delta = float4(1.0 / openVaultXBRScale);
            float4 deltaL = float4(
                0.5 / openVaultXBRScale,
                1.0 / openVaultXBRScale,
                0.5 / openVaultXBRScale,
                1.0 / openVaultXBRScale
            );
            float4 deltaU = deltaL.yxwz;

            float3 A1 = frame.sample(
                openVaultPointSampler, uv + float2(-dx, -2.0 * dy)
            ).xyz;
            float3 B1 = frame.sample(
                openVaultPointSampler, uv + float2(0.0, -2.0 * dy)
            ).xyz;
            float3 C1 = frame.sample(
                openVaultPointSampler, uv + float2( dx, -2.0 * dy)
            ).xyz;
            float3 A = frame.sample(
                openVaultPointSampler, uv + float2(-dx, -dy)
            ).xyz;
            float3 B = frame.sample(
                openVaultPointSampler, uv + float2(0.0, -dy)
            ).xyz;
            float3 C = frame.sample(
                openVaultPointSampler, uv + float2( dx, -dy)
            ).xyz;
            float3 D = frame.sample(
                openVaultPointSampler, uv + float2(-dx, 0.0)
            ).xyz;
            float3 E = frame.sample(
                openVaultPointSampler, uv
            ).xyz;
            float3 F = frame.sample(
                openVaultPointSampler, uv + float2( dx, 0.0)
            ).xyz;
            float3 G = frame.sample(
                openVaultPointSampler, uv + float2(-dx, dy)
            ).xyz;
            float3 H = frame.sample(
                openVaultPointSampler, uv + float2(0.0, dy)
            ).xyz;
            float3 I = frame.sample(
                openVaultPointSampler, uv + float2( dx, dy)
            ).xyz;
            float3 G5 = frame.sample(
                openVaultPointSampler, uv + float2(-dx, 2.0 * dy)
            ).xyz;
            float3 H5 = frame.sample(
                openVaultPointSampler, uv + float2(0.0, 2.0 * dy)
            ).xyz;
            float3 I5 = frame.sample(
                openVaultPointSampler, uv + float2( dx, 2.0 * dy)
            ).xyz;
            float3 A0 = frame.sample(
                openVaultPointSampler, uv + float2(-2.0 * dx, -dy)
            ).xyz;
            float3 D0 = frame.sample(
                openVaultPointSampler, uv + float2(-2.0 * dx, 0.0)
            ).xyz;
            float3 G0 = frame.sample(
                openVaultPointSampler, uv + float2(-2.0 * dx, dy)
            ).xyz;
            float3 C4 = frame.sample(
                openVaultPointSampler, uv + float2( 2.0 * dx, -dy)
            ).xyz;
            float3 F4 = frame.sample(
                openVaultPointSampler, uv + float2( 2.0 * dx, 0.0)
            ).xyz;
            float3 I4 = frame.sample(
                openVaultPointSampler, uv + float2( 2.0 * dx, dy)
            ).xyz;

            float4 b = float4(
                dot(B, openVaultXBRWeights),
                dot(D, openVaultXBRWeights),
                dot(H, openVaultXBRWeights),
                dot(F, openVaultXBRWeights)
            );
            float4 c = float4(
                dot(C, openVaultXBRWeights),
                dot(A, openVaultXBRWeights),
                dot(G, openVaultXBRWeights),
                dot(I, openVaultXBRWeights)
            );
            float4 d = b.yzwx;
            float4 e = float4(dot(E, openVaultXBRWeights));
            float4 f = b.wxyz;
            float4 g = c.zwxy;
            float4 h = b.zwxy;
            float4 i = c.wxyz;

            float4 i4 = float4(
                dot(I4, openVaultXBRWeights),
                dot(C1, openVaultXBRWeights),
                dot(A0, openVaultXBRWeights),
                dot(G5, openVaultXBRWeights)
            );
            float4 i5 = float4(
                dot(I5, openVaultXBRWeights),
                dot(C4, openVaultXBRWeights),
                dot(A1, openVaultXBRWeights),
                dot(G0, openVaultXBRWeights)
            );
            float4 h5 = float4(
                dot(H5, openVaultXBRWeights),
                dot(F4, openVaultXBRWeights),
                dot(B1, openVaultXBRWeights),
                dot(D0, openVaultXBRWeights)
            );
            // The reference GLSL declares f4 but never assigns it, which
            // leaves its CORNER_C and weighted-distance terms reading an
            // undefined value. Every other neighbourhood vector here is the
            // same rule sampled at four 90-degree rotations, and f4 is the
            // rotation of h5: component x wants the pixel right of F, which
            // is h5.y, and the remaining components follow.
            float4 f4 = h5.yzwx;

            float4 fx = openVaultXBRAo * fp.y + openVaultXBRBo * fp.x;
            float4 fxL = openVaultXBRAx * fp.y + openVaultXBRBx * fp.x;
            float4 fxU = openVaultXBRAy * fp.y + openVaultXBRBy * fp.x;

            float4 irlv0 =
                openVaultXBRDiff(e, f) * openVaultXBRDiff(e, h);
            // CORNER_C, the reference shader's enabled corner rule.
            float4 irlv1 = irlv0
                * (openVaultXBRNeq(f, b) * openVaultXBRNeq(f, c)
                    + openVaultXBRNeq(h, d) * openVaultXBRNeq(h, g)
                    + openVaultXBREq(e, i)
                        * (openVaultXBRNeq(f, f4) * openVaultXBRNeq(f, i4)
                            + openVaultXBRNeq(h, h5) * openVaultXBRNeq(h, i5))
                    + openVaultXBREq(e, g)
                    + openVaultXBREq(e, c));

            float4 irlv2l =
                openVaultXBRDiff(e, g) * openVaultXBRDiff(d, g);
            float4 irlv2u =
                openVaultXBRDiff(e, c) * openVaultXBRDiff(b, c);

            float4 fx45i = clamp(
                (fx + delta - openVaultXBRCo - openVaultXBRCi)
                    / (2.0 * delta),
                0.0,
                1.0
            );
            float4 fx45 = clamp(
                (fx + delta - openVaultXBRCo) / (2.0 * delta),
                0.0,
                1.0
            );
            float4 fx30 = clamp(
                (fxL + deltaL - openVaultXBRCx) / (2.0 * deltaL),
                0.0,
                1.0
            );
            float4 fx60 = clamp(
                (fxU + deltaU - openVaultXBRCy) / (2.0 * deltaU),
                0.0,
                1.0
            );

            float4 wd1 = openVaultXBRWd(e, c, g, i, h5, f4, h, f);
            float4 wd2 = openVaultXBRWd(h, d, i5, f, i4, b, e, i);

            float4 edri = step(wd1, wd2) * irlv0;
            float4 edr = step(wd1 + float4(0.1), wd2) * step(float4(0.5), irlv1);
            float4 edrL = step(
                openVaultXBRLv2Coefficient * openVaultXBRDf(f, g),
                openVaultXBRDf(h, c)
            ) * irlv2l * edr;
            float4 edrU = step(
                openVaultXBRLv2Coefficient * openVaultXBRDf(h, c),
                openVaultXBRDf(f, g)
            ) * irlv2u * edr;

            fx45 = edr * fx45;
            fx30 = edrL * fx30;
            fx60 = edrU * fx60;
            fx45i = edri * fx45i;

            float4 px = step(openVaultXBRDf(e, f), openVaultXBRDf(e, h));

            // SMOOTH_TIPS, which the reference enables for every corner rule
            // other than CORNER_A.
            float4 maximos = max(max(fx30, fx60), max(fx45, fx45i));

            float3 res1 = E;
            res1 = mix(res1, mix(H, F, px.x), maximos.x);
            res1 = mix(res1, mix(B, D, px.z), maximos.z);

            float3 res2 = E;
            res2 = mix(res2, mix(F, B, px.y), maximos.y);
            res2 = mix(res2, mix(D, H, px.w), maximos.w);

            float3 res = mix(
                res1,
                res2,
                step(
                    openVaultXBRColorDf(E, res1),
                    openVaultXBRColorDf(E, res2)
                )
            );

            return float4(res, 1.0);
        }

        // Scanlines and an aperture-grille mask over a sharp-bilinear
        // resample. Weighting happens on linearised colour so the mask darkens
        // the picture the way a real tube does rather than crushing it, and
        // the result is re-encoded before it reaches the drawable.
        fragment float4 openVaultCRTFragment(
            OpenVaultPixelVertex input [[stage_in]],
            texture2d<float> frame [[texture(0)]],
            constant OpenVaultVideoUniforms &uniforms [[buffer(0)]]
        ) {
            float4 sampled = openVaultSharpBilinear(
                input.textureCoordinate,
                frame,
                uniforms
            );
            float3 color = pow(max(sampled.rgb, 0.0), float3(2.2));

            // Scanline weight from the vertical position inside the source
            // scanline, so the lines track the core's resolution rather than
            // the window size.
            float scanlinePhase =
                fract(input.textureCoordinate.y * uniforms.sourceHeight);
            float distanceFromCenter = scanlinePhase - 0.5;
            float scanline =
                exp2(-8.0 * distanceFromCenter * distanceFromCenter);

            // Below roughly 3x there are too few output rows per source line
            // to draw a gap without it turning into moire, so fade the effect
            // out rather than let it alias.
            float verticalScale =
                uniforms.targetHeight / max(uniforms.sourceHeight, 1.0);
            float scanlineStrength =
                clamp((verticalScale - 1.5) / 1.5, 0.0, 1.0);
            scanline = mix(1.0, scanline, scanlineStrength);

            // Aperture grille keyed to the output pixel column, cycling
            // red-green-blue across every three physical pixels.
            uint column = uint(input.position.x) % 3u;
            float3 mask = float3(0.85);
            if (column == 0u) {
                mask = float3(1.0, 0.8, 0.8);
            } else if (column == 1u) {
                mask = float3(0.8, 1.0, 0.8);
            } else {
                mask = float3(0.8, 0.8, 1.0);
            }

            color *= scanline;
            color *= mask;
            // Scanlines and mask together remove roughly a third of the
            // energy. Put back only what the scanlines actually took, so a
            // window too small to draw them does not come out overexposed.
            color *= mix(1.15, 1.6, scanlineStrength);

            return float4(pow(max(color, 0.0), float3(1.0 / 2.2)), 1.0);
        }
        """
}
