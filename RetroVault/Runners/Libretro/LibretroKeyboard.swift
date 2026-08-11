import Foundation

/// Libretro's `retro_key` values, and the translation from the virtual key
/// codes AppKit reports.
///
/// A core that wants a keyboard — DOSBox Pure being the reason this exists —
/// reads `RETRO_DEVICE_KEYBOARD` with a `retro_key` as the id, so the runtime
/// has to speak that enum rather than the RetroPad buttons the other cores
/// use. The values below are `retro_key` from `libretro.h`: printable keys
/// share their ASCII code and everything else is allocated from 256 up.
enum LibretroKeyboard {
    static let device: UInt32 = 3

    /// The highest `retro_key` value, `RETROK_UNDO`. Sizing the pressed-key
    /// set from this keeps the lookup a plain bounds check.
    static let keyCount = 323

    enum Modifier: UInt16 {
        case none = 0x0000
        case shift = 0x01
        case control = 0x02
        case alt = 0x04
        case meta = 0x08
        case numLock = 0x10
        case capsLock = 0x20
        case scrollLock = 0x40
    }

    /// macOS virtual key code to `retro_key`.
    ///
    /// Keyed by `kVK_*` constants, which describe physical key positions on a
    /// US layout. That is the right granularity here: DOS software reads scan
    /// codes, so a key's position matters more than the character the user's
    /// current layout would produce from it.
    static let retroKeysByMacKeyCode: [UInt16: UInt32] = [
        // Letters.
        0: 97,    // a
        11: 98,   // b
        8: 99,    // c
        2: 100,   // d
        14: 101,  // e
        3: 102,   // f
        5: 103,   // g
        4: 104,   // h
        34: 105,  // i
        38: 106,  // j
        40: 107,  // k
        37: 108,  // l
        46: 109,  // m
        45: 110,  // n
        31: 111,  // o
        35: 112,  // p
        12: 113,  // q
        15: 114,  // r
        1: 115,   // s
        17: 116,  // t
        32: 117,  // u
        9: 118,   // v
        13: 119,  // w
        7: 120,   // x
        16: 121,  // y
        6: 122,   // z

        // Digits.
        29: 48,  // 0
        18: 49,  // 1
        19: 50,  // 2
        20: 51,  // 3
        21: 52,  // 4
        23: 53,  // 5
        22: 54,  // 6
        26: 55,  // 7
        28: 56,  // 8
        25: 57,  // 9

        // Punctuation.
        27: 45,  // minus
        24: 61,  // equals
        33: 91,  // left bracket
        30: 93,  // right bracket
        42: 92,  // backslash
        41: 59,  // semicolon
        39: 39,  // quote
        43: 44,  // comma
        47: 46,  // period
        44: 47,  // slash
        50: 96,  // backquote

        // Editing and whitespace.
        36: 13,   // return
        48: 9,    // tab
        49: 32,   // space
        51: 8,    // backspace
        53: 27,   // escape
        117: 127, // forward delete
        114: 277, // help, which sits where Insert does on a PC keyboard
        115: 278, // home
        119: 279, // end
        116: 280, // page up
        121: 281, // page down

        // Arrows.
        126: 273, // up
        125: 274, // down
        124: 275, // right
        123: 276, // left

        // Keypad.
        82: 256,  // keypad 0
        83: 257,  // keypad 1
        84: 258,  // keypad 2
        85: 259,  // keypad 3
        86: 260,  // keypad 4
        87: 261,  // keypad 5
        88: 262,  // keypad 6
        89: 263,  // keypad 7
        91: 264,  // keypad 8
        92: 265,  // keypad 9
        65: 266,  // keypad period
        75: 267,  // keypad divide
        67: 268,  // keypad multiply
        78: 269,  // keypad minus
        69: 270,  // keypad plus
        76: 271,  // keypad enter
        81: 272,  // keypad equals
        71: 300,  // clear, which sits where Num Lock does

        // Function row.
        122: 282, // f1
        120: 283, // f2
        99: 284,  // f3
        118: 285, // f4
        96: 286,  // f5
        97: 287,  // f6
        98: 288,  // f7
        100: 289, // f8
        101: 290, // f9
        109: 291, // f10
        103: 292, // f11
        111: 293, // f12
        105: 294, // f13
        107: 295, // f14
        113: 296, // f15

        // Modifiers. AppKit reports these through flagsChanged rather than
        // keyDown, but they still need their own retro_key values.
        57: 301,  // caps lock
        56: 304,  // left shift
        60: 303,  // right shift
        59: 306,  // left control
        62: 305,  // right control
        58: 308,  // left alt
        61: 307,  // right alt
        55: 310,  // left meta
        54: 309,  // right meta
    ]

    static func retroKey(forMacKeyCode keyCode: UInt16) -> UInt32? {
        retroKeysByMacKeyCode[keyCode]
    }

    /// The `retro_key` values AppKit only reports through `flagsChanged`,
    /// paired with the modifier flag whose presence means the key is down.
    ///
    /// `flagsChanged` says which modifiers are active but not which key
    /// changed, so the runtime diffs the flags against the previous event to
    /// work out what went down or up.
    static let modifierKeyCodes: [UInt16] = [
        54, 55, 56, 57, 58, 59, 60, 61, 62,
    ]
}
