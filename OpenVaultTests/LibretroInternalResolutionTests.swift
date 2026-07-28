import Testing

@testable import OpenVault

// The value lists below are the ones the bundled cores actually publish, read
// out of each shipped dylib, so these tests fail if a core rebuild changes how
// it spells its resolutions.
@Suite("Libretro internal resolution")
struct LibretroInternalResolutionTests {
    private let flycastValues = [
        "320x240", "640x480", "800x600", "960x720", "1024x768",
        "1280x960", "1440x1080", "1600x1200", "1920x1440", "2560x1920",
    ]
    private let ppssppValues = [
        "480x272", "960x544", "1440x816", "1920x1088", "2400x1360",
    ]
    private let dolphinValues = [
        "1x Native (640x528)",
        "2x Native (1280x1056) for 720p",
        "3x Native (1920x1584) for 1080p",
        "4x Native (2560x2112) for 1440p",
    ]
    private let pcsxValues = ["disabled", "enabled"]

    @Test("Native leaves every core's own default in place")
    func nativeOverridesNothing() {
        let keys = [
            "reicast_internal_resolution",
            "ppsspp_internal_resolution",
            "dolphin_efb_scale",
            "pcsx_rearmed_neon_enhancement_enable",
        ]
        for key in keys {
            #expect(
                LibretroInternalResolutionOption.value(
                    forKey: key,
                    resolution: .native,
                    availableValues: flycastValues
                ) == nil
            )
        }
    }

    @Test("Dreamcast resolutions resolve by pixel width")
    func flycastScales() {
        #expect(
            LibretroInternalResolutionOption.value(
                forKey: "reicast_internal_resolution",
                resolution: .double,
                availableValues: flycastValues
            ) == "1280x960"
        )
        #expect(
            LibretroInternalResolutionOption.value(
                forKey: "reicast_internal_resolution",
                resolution: .quadruple,
                availableValues: flycastValues
            ) == "2560x1920"
        )
    }

    @Test("PSP resolutions resolve by pixel width")
    func ppssppScales() {
        #expect(
            LibretroInternalResolutionOption.value(
                forKey: "ppsspp_internal_resolution",
                resolution: .double,
                availableValues: ppssppValues
            ) == "960x544"
        )
        #expect(
            LibretroInternalResolutionOption.value(
                forKey: "ppsspp_internal_resolution",
                resolution: .quadruple,
                availableValues: ppssppValues
            ) == "1920x1088"
        )
    }

    @Test("GameCube resolutions resolve by their leading multiplier")
    func dolphinScales() {
        #expect(
            LibretroInternalResolutionOption.value(
                forKey: "dolphin_efb_scale",
                resolution: .double,
                availableValues: dolphinValues
            ) == "2x Native (1280x1056) for 720p"
        )
        #expect(
            LibretroInternalResolutionOption.value(
                forKey: "dolphin_efb_scale",
                resolution: .quadruple,
                availableValues: dolphinValues
            ) == "4x Native (2560x2112) for 1440p"
        )
    }

    // pcsx_rearmed's NEON renderer offers a single 2x mode rather than a list,
    // so both scales above native turn the same switch on.
    @Test("PlayStation enhancement is a switch, not a list")
    func pcsxEnhancement() {
        #expect(
            LibretroInternalResolutionOption.value(
                forKey: "pcsx_rearmed_neon_enhancement_enable",
                resolution: .double,
                availableValues: pcsxValues
            ) == "enabled"
        )
        #expect(
            LibretroInternalResolutionOption.value(
                forKey: "pcsx_rearmed_neon_enhancement_enable",
                resolution: .quadruple,
                availableValues: pcsxValues
            ) == "enabled"
        )
    }

    @Test("A core offering no matching scale keeps its own default")
    func unmatchedScaleFallsBack() {
        // The PSP core stops at 5x, so 4x resolves but a hypothetical 8x
        // would not. 3x is absent from this trimmed list on purpose.
        #expect(
            LibretroInternalResolutionOption.value(
                forKey: "ppsspp_internal_resolution",
                resolution: .quadruple,
                availableValues: ["480x272", "960x544"]
            ) == nil
        )
    }

    @Test("A key no core resolution uses is left alone")
    func unrelatedKeysIgnored() {
        #expect(
            LibretroInternalResolutionOption.value(
                forKey: "dosbox_pure_cpu_core",
                resolution: .double,
                availableValues: ["normal", "dynamic"]
            ) == nil
        )
    }

    // "1280x960" and "2x Native" both start with digits followed by an "x",
    // and reading the first as a 1280-times multiplier would pick nonsense.
    @Test("Pixel dimensions are not mistaken for multipliers")
    func dimensionsAreNotMultipliers() {
        #expect(
            LibretroInternalResolutionOption.leadingMultiplier("1280x960")
                == nil
        )
        #expect(
            LibretroInternalResolutionOption.leadingMultiplier("2x (800x480)")
                == 2
        )
        #expect(
            LibretroInternalResolutionOption.leadingWidth("1280x960") == 1280
        )
        #expect(
            LibretroInternalResolutionOption.leadingWidth("2x Native") == nil
        )
    }

    @Test("Compatibility overrides outrank the resolution preference")
    func compatibilityOverridesWin() {
        // parallel-n64 is pinned to the software renderer because the GL path
        // renders black frames, and no preference may undo that.
        #expect(
            LibretroCoreOptionPreferences.value(
                for: "parallel-n64-gfxplugin",
                default: "auto",
                availableValues: ["auto", "angrylion", "gln64"],
                internalResolution: .quadruple
            ) == "angrylion"
        )
    }

    // The runtime owns a single CGL context, which can only be current on one
    // thread, so a core rendering from a second thread would have no context
    // at all. Flycast defaults this on.
    @Test("Dreamcast rendering stays on the emulation thread")
    func flycastRendersOnEmulationThread() {
        for resolution in LibretroInternalResolution.allCases {
            #expect(
                LibretroCoreOptionPreferences.value(
                    for: "reicast_threaded_rendering",
                    default: "enabled",
                    availableValues: ["enabled", "disabled"],
                    internalResolution: resolution
                ) == "disabled"
            )
        }
    }

    // Without this, Flycast keeps reporting the full field rate for a game
    // that presents every second field, and the frontend paces it at double
    // speed.
    @Test("Dreamcast reports when a game halves its presentation rate")
    func flycastDetectsSwapInterval() {
        #expect(
            LibretroCoreOptionPreferences.value(
                for: "reicast_detect_vsync_swap_interval",
                default: "disabled",
                availableValues: ["disabled", "enabled"],
                internalResolution: .native
            ) == "enabled"
        )
    }

    @Test("The resolution preference reaches the option resolver")
    func preferenceReachesResolver() {
        #expect(
            LibretroCoreOptionPreferences.value(
                for: "pcsx_rearmed_neon_enhancement_enable",
                default: "disabled",
                availableValues: pcsxValues,
                internalResolution: .double
            ) == "enabled"
        )
        #expect(
            LibretroCoreOptionPreferences.value(
                for: "pcsx_rearmed_neon_enhancement_enable",
                default: "disabled",
                availableValues: pcsxValues,
                internalResolution: .native
            ) == "disabled"
        )
    }
}
