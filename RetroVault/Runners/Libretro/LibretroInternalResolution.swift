import Foundation

/// How far above its native resolution a 3D core should render.
///
/// This is a different thing from `LibretroVideoFilter`. A filter resamples
/// the picture a core already drew; this asks the core to draw more picture in
/// the first place, which is the only way polygon edges and 3D textures
/// actually gain detail. It means nothing to a 2D core, whose framebuffer size
/// is dictated by the hardware being emulated.
enum LibretroInternalResolution: String, CaseIterable, Identifiable, Sendable {
    case native
    case double = "2x"
    case quadruple = "4x"

    var id: String { rawValue }

    /// The multiple of the system's native resolution to ask for.
    var scale: Int {
        switch self {
        case .native:
            1
        case .double:
            2
        case .quadruple:
            4
        }
    }

    var displayName: String {
        switch self {
        case .native:
            "Native"
        case .double:
            "2x"
        case .quadruple:
            "4x"
        }
    }
}

enum LibretroInternalResolutionPreferences {
    static let scaleKey = "libretro.video.internal-resolution.v1"

    /// Native keeps the runtime doing what it has always done, and keeps the
    /// cores that only just work on this stack off the more demanding path.
    static let defaultResolution = LibretroInternalResolution.native

    static func resolution(
        from defaults: UserDefaults = .standard
    ) -> LibretroInternalResolution {
        guard
            let raw = defaults.string(forKey: scaleKey),
            let resolution = LibretroInternalResolution(rawValue: raw)
        else {
            return defaultResolution
        }
        return resolution
    }
}

/// Picks a core's internal-resolution option value out of the list that core
/// itself advertised.
///
/// Hardcoding the value strings would be guesswork that rots: each core spells
/// its own scales differently ("1280x960", "2x (800x480)", "2x Native
/// (1280x1056)", "enabled"), and the strings change between core revisions.
/// Reading the list the core just published and matching against it means an
/// unrecognised list leaves the core's own default alone rather than feeding
/// it a value it will reject.
enum LibretroInternalResolutionOption {
    /// The option key each core uses, and the native width its value list is
    /// expressed in when that list spells out pixel dimensions.
    ///
    /// parallel_n64 is deliberately absent: the runtime pins it to the
    /// Angrylion software renderer because GLideN64 produces black frames
    /// through macOS's deprecated OpenGL, and a software rasteriser has no
    /// higher resolution to render at. melonds is absent because the bundled
    /// build exposes no resolution option at all.
    private static let optionsByKey: [String: Int?] = [
        // Dreamcast. Values read "640x480", "1280x960", ...
        "reicast_internal_resolution": 640,
        // PSP. Values read "480x272", "960x544", ...
        "ppsspp_internal_resolution": 480,
        // GameCube and Wii. Values read "1x Native (640x528)", ...
        "dolphin_efb_scale": 640,
        // PlayStation. A plain on/off for the NEON renderer's 2x mode rather
        // than a list of resolutions, handled separately below.
        "pcsx_rearmed_neon_enhancement_enable": nil,
    ]

    static func isResolutionKey(_ key: String) -> Bool {
        optionsByKey.keys.contains(key)
    }

    /// Returns the value to send for `key`, or nil to leave the core's own
    /// default in place.
    static func value(
        forKey key: String,
        resolution: LibretroInternalResolution,
        availableValues: [String]
    ) -> String? {
        guard let nativeWidth = optionsByKey[key] else {
            return nil
        }
        guard resolution != .native else {
            // Native is the core's own default everywhere here, so there is
            // nothing to override.
            return nil
        }

        // pcsx_rearmed's enhancement is a boolean 2x, so anything above
        // native turns it on.
        guard let nativeWidth else {
            return availableValues.contains("enabled") ? "enabled" : nil
        }

        return matching(
            scale: resolution.scale,
            nativeWidth: nativeWidth,
            in: availableValues
        )
    }

    /// Finds the value that means `scale` times native, trying the two shapes
    /// these cores use: a leading "Nx" multiplier, or explicit pixel
    /// dimensions whose width is the multiple.
    static func matching(
        scale: Int,
        nativeWidth: Int,
        in values: [String]
    ) -> String? {
        if let multiplier = values.first(where: {
            leadingMultiplier($0) == scale
        }) {
            return multiplier
        }
        return values.first {
            leadingWidth($0) == nativeWidth * scale
        }
    }

    /// Reads the `2` out of "2x", "2x Native (1280x1056)", or "2x (800x480)".
    static func leadingMultiplier(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber }
        guard
            !digits.isEmpty,
            trimmed.dropFirst(digits.count).first == "x"
        else {
            return nil
        }
        // "1280x960" also starts with digits followed by an "x", so require
        // that what follows is not another run of digits.
        let remainder = trimmed.dropFirst(digits.count + 1)
        guard remainder.first?.isNumber != true else {
            return nil
        }
        return Int(digits)
    }

    /// Reads the `1280` out of "1280x960".
    static func leadingWidth(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber }
        guard
            !digits.isEmpty,
            trimmed.dropFirst(digits.count).first == "x",
            trimmed.dropFirst(digits.count + 1).first?.isNumber == true
        else {
            return nil
        }
        return Int(digits)
    }
}
