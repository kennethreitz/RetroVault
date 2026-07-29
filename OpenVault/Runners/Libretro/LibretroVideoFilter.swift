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

    /// Chooses flat or curved CRT geometry for the game's system.
    case crtSmart = "crt-smart"

    /// The same CRT simulation with tube curvature and darkened corners.
    case crtCurved = "crt-curved"

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
        case .crtSmart:
            "CRT (Smart)"
        case .crtCurved:
            "CRT (Curved)"
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
            "A crisp flat CRT with scanlines, RGB phosphors, and brief "
                + "phosphor persistence."
        case .crtSmart:
            "Uses curved CRT glass for television-era consoles and arcade "
                + "systems, and a flat CRT for handhelds and newer systems."
        case .crtCurved:
            "The persistent RGB phosphor treatment with curved tube geometry "
                + "and softly darkened corners."
        }
    }

    var usesFrameHistory: Bool {
        switch self {
        case .crt, .crtSmart, .crtCurved:
            true
        case .nearest, .sharpBilinear, .xbr:
            false
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
        case .crtSmart:
            // The player resolves Smart before rendering. Flat CRT is the
            // safe fallback for content-free runtime tests.
            "openVaultCRTFragment"
        case .crtCurved:
            "openVaultCRTCurvedFragment"
        }
    }

    func resolved(forSystemName systemName: String?) -> Self {
        guard self == .crtSmart else {
            return self
        }
        return LibretroSmartCRTPolicy.prefersCurvature(
            forSystemName: systemName
        ) ? .crtCurved : .crt
    }
}

enum LibretroSmartCRTPolicy {
    /// Systems whose games were principally presented on a consumer
    /// television or an arcade CRT. Unknown, handheld, computer-monitor, and
    /// newer systems deliberately fall back to the flat CRT treatment.
    private static let curvedSystemNames: Set<String> = [
        "3do",
        "arcade",
        "atari 2600",
        "atari 5200",
        "atari 7800",
        "atari jaguar",
        "colecovision",
        "dreamcast",
        "famicom",
        "intellivision",
        "neo geo",
        "nintendo 64",
        "nintendo entertainment system",
        "nintendo gamecube",
        "pc engine cd",
        "pc engine supergrafx",
        "playstation",
        "playstation 2",
        "sega 32x",
        "sega cd",
        "sega master system",
        "sega master system/mark iii",
        "sega mega drive/genesis",
        "sega saturn",
        "super famicom",
        "super nintendo entertainment system",
        "turbografx-16/pc engine",
    ]

    static func prefersCurvature(forSystemName systemName: String?) -> Bool {
        guard let systemName else {
            return false
        }
        let normalized = systemName
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return curvedSystemNames.contains(normalized)
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

        static float3 openVaultToLinear(float3 color) {
            return pow(max(color, 0.0), float3(2.2));
        }

        static float3 openVaultFromLinear(float3 color) {
            return pow(max(color, 0.0), float3(1.0 / 2.2));
        }

        // A bright phosphor does not go completely dark between two 60 Hz
        // frames. Retaining a small amount of the prior frame makes the
        // alternating-frame transparency used by period games appear
        // translucent instead of visibly blinking.
        //
        // The decay is deliberately applied to display-encoded color before
        // the CRT treatment is linearized. A 62% remnant in linear light
        // becomes roughly 80% after gamma encoding, which is physically
        // defensible but looks like motion blur on an LCD. In display space
        // it remains visible without softening every moving edge.
        static float3 openVaultPhosphorPersistence(
            float3 current,
            float3 previous
        ) {
            constexpr float decay = 0.62;
            return max(current, previous * decay);
        }

        // A consumer CRT does not have square RGB pixels. Its shadow mask
        // exposes short red, green, and blue phosphor slots in staggered
        // triads. Each slot here is two physical drawable pixels wide and two
        // high, followed by a one-pixel horizontal grille gap. On a Retina
        // panel that makes a slot roughly one point across: visible up close,
        // but fine enough to blend into color at normal viewing distance.
        //
        // The mask is deliberately energy-neutral across a complete triad so
        // white remains white instead of acquiring a color cast.
        static float3 openVaultRGBSlotMask(
            float2 physicalPixel,
            float strength
        ) {
            uint pixelX = uint(floor(max(physicalPixel.x, 0.0)));
            uint pixelY = uint(floor(max(physicalPixel.y, 0.0)));
            uint rowInBank = pixelY % 3u;
            uint bank = (pixelY / 3u) % 2u;
            uint shiftedX = pixelX + bank * 2u;
            uint phosphor = (shiftedX / 2u) % 3u;

            float3 mask = float3(0.78);
            if (phosphor == 0u) {
                mask.r = 1.22;
            } else if (phosphor == 1u) {
                mask.g = 1.22;
            } else {
                mask.b = 1.22;
            }

            // The unlit row between slot banks is the horizontal part of the
            // shadow mask. Keep it present but not black so scanlines remain
            // the dominant structure instead of producing a mesh overlay.
            if (rowInBank == 2u) {
                mask *= 0.78;
            }

            return mix(float3(1.0), mask * 1.165, strength);
        }

        // Barrel distortion is deliberately isolated here. The normal CRT
        // path never calls it, so choosing "CRT" cannot bend or crop a frame.
        static float2 openVaultCRTCurvedCoordinate(float2 coordinate) {
            float2 centered = coordinate * 2.0 - 1.0;
            float2 squared = centered * centered;
            centered.x *= 1.0 + squared.y * 0.045;
            centered.y *= 1.0 + squared.x * 0.035;
            return centered * 0.5 + 0.5;
        }

        static float4 openVaultCRT(
            float2 textureCoordinate,
            texture2d<float> frame,
            texture2d<float> previousFrame,
            constant OpenVaultVideoUniforms &uniforms,
            bool curved
        ) {
            float2 coordinate = curved
                ? openVaultCRTCurvedCoordinate(textureCoordinate)
                : textureCoordinate;

            // Curvature exposes the outside of the virtual tube at the
            // corners. Keep those pixels opaque black instead of smearing the
            // edge texels into the border.
            if (
                coordinate.x < 0.0 || coordinate.x > 1.0
                || coordinate.y < 0.0 || coordinate.y > 1.0
            ) {
                return float4(0.0, 0.0, 0.0, 1.0);
            }

            float2 sourceSize = max(
                float2(uniforms.sourceWidth, uniforms.sourceHeight),
                float2(1.0)
            );
            float2 targetSize = max(
                float2(uniforms.targetWidth, uniforms.targetHeight),
                float2(1.0)
            );
            // Apply the same crisp reconstruction as the flat CRT after
            // warping the texture coordinate. The older curved path used a
            // wide luminance-dependent beam plus a four-sample glass halo;
            // together those softened fine pixel art considerably.
            float3 color = openVaultPhosphorPersistence(
                openVaultSharpBilinear(
                    coordinate,
                    frame,
                    uniforms
                ).rgb,
                openVaultSharpBilinear(
                    coordinate,
                    previousFrame,
                    uniforms
                ).rgb
            );
            color = openVaultToLinear(color);

            // Keep scanlines source-aligned so the curved treatment retains
            // distinct rows without blending neighboring source pixels.
            float scanlinePhase = fract(coordinate.y * sourceSize.y);
            float distanceFromCenter = scanlinePhase - 0.5;
            float scanline =
                exp2(-8.0 * distanceFromCenter * distanceFromCenter);

            float2 outputScale = targetSize / sourceSize;
            float scanlineStrength = clamp(
                (outputScale.y - 1.5) / 1.5,
                0.0,
                1.0
            );
            color *= mix(1.0, scanline, scanlineStrength);

            // The slot mask is indexed in physical drawable pixels, not
            // SwiftUI points, so Retina displays receive the full phosphor
            // structure rather than a point-scaled approximation.
            float maskStrength = clamp(
                (min(outputScale.x, outputScale.y) - 2.0) / 2.0,
                0.0,
                1.0
            );
            color *= openVaultRGBSlotMask(
                textureCoordinate * targetSize,
                maskStrength * 0.58
            );

            // Curvature gets its own soft glass edge. The flat CRT path has
            // no vignette, geometry change, or loss of picture area.
            if (curved) {
                float2 edgeDistance =
                    min(coordinate, 1.0 - coordinate);
                float edge = smoothstep(
                    0.0,
                    0.025,
                    min(edgeDistance.x, edgeDistance.y)
                );
                color *= edge;
            }

            // Restore only the energy removed by visible scanlines. This
            // keeps a small window from becoming artificially overexposed.
            color *= mix(1.08, 1.52, scanlineStrength);
            return float4(openVaultFromLinear(color), 1.0);
        }

        fragment float4 openVaultCRTFragment(
            OpenVaultPixelVertex input [[stage_in]],
            texture2d<float> frame [[texture(0)]],
            texture2d<float> previousFrame [[texture(1)]],
            constant OpenVaultVideoUniforms &uniforms [[buffer(0)]]
        ) {
            float4 sampled = openVaultSharpBilinear(
                input.textureCoordinate,
                frame,
                uniforms
            );
            float3 previousColor =
                openVaultSharpBilinear(
                    input.textureCoordinate,
                    previousFrame,
                    uniforms
                ).rgb;
            float3 color = openVaultToLinear(
                openVaultPhosphorPersistence(sampled.rgb, previousColor)
            );

            // Keep the original sharp CRT treatment: source-aligned
            // scanlines over sharp-bilinear pixels, without reconstruction or
            // halation softening the image.
            float scanlinePhase =
                fract(input.textureCoordinate.y * uniforms.sourceHeight);
            float distanceFromCenter = scanlinePhase - 0.5;
            float scanline =
                exp2(-8.0 * distanceFromCenter * distanceFromCenter);

            float verticalScale =
                uniforms.targetHeight / max(uniforms.sourceHeight, 1.0);
            float scanlineStrength =
                clamp((verticalScale - 1.5) / 1.5, 0.0, 1.0);
            scanline = mix(1.0, scanline, scanlineStrength);

            float horizontalScale =
                uniforms.targetWidth / max(uniforms.sourceWidth, 1.0);
            float maskStrength = clamp(
                (min(horizontalScale, verticalScale) - 1.75) / 2.25,
                0.0,
                1.0
            );
            float3 mask = openVaultRGBSlotMask(
                input.position.xy,
                maskStrength * 0.72
            );

            color *= scanline;
            color *= mask;
            color *= mix(1.08, 1.52, scanlineStrength);

            return float4(
                pow(max(color, 0.0), float3(1.0 / 2.2)),
                1.0
            );
        }

        fragment float4 openVaultCRTCurvedFragment(
            OpenVaultPixelVertex input [[stage_in]],
            texture2d<float> frame [[texture(0)]],
            texture2d<float> previousFrame [[texture(1)]],
            constant OpenVaultVideoUniforms &uniforms [[buffer(0)]]
        ) {
            return openVaultCRT(
                input.textureCoordinate,
                frame,
                previousFrame,
                uniforms,
                true
            );
        }
        """
}
