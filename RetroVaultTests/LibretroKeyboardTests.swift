import Testing

@testable import RetroVault

@Suite("Libretro keyboard")
struct LibretroKeyboardTests {
    // Printable keys share their ASCII code in retro_key, which is what lets a
    // core treat the id as a character without a second table.
    @Test("Letters and digits map to their ASCII codes")
    func printableKeys() {
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 0) == 97)   // a
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 6) == 122)  // z
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 18) == 49)  // 1
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 29) == 48)  // 0
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 49) == 32)  // space
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 36) == 13)  // return
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 53) == 27)  // escape
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 51) == 8)   // backspace
    }

    // A DOS game reads these constantly, and an off-by-one here would show up
    // as the wrong direction rather than as no input at all.
    @Test("Arrows map to the RETROK arrow block")
    func arrowKeys() {
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 126) == 273) // up
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 125) == 274) // down
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 124) == 275) // right
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 123) == 276) // left
    }

    @Test("The function row is contiguous from F1")
    func functionKeys() {
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 122) == 282) // f1
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 120) == 283) // f2
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 99) == 284)  // f3
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 109) == 291) // f10
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 111) == 293) // f12
    }

    @Test("Left and right modifiers are distinct keys")
    func modifierKeys() {
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 56) == 304)  // lshift
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 60) == 303)  // rshift
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 59) == 306)  // lctrl
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 62) == 305)  // rctrl
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 58) == 308)  // lalt
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 61) == 307)  // ralt
    }

    @Test("The keypad is a separate block from the digit row")
    func keypadKeys() {
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 82) == 256) // kp0
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 92) == 265) // kp9
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 76) == 271) // kp enter
        // The digit row must not collide with the keypad.
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 29) == 48)
    }

    @Test("Every mapped key is inside the retro_key range")
    func keysAreInRange() {
        for (_, retroKey) in LibretroKeyboard.retroKeysByMacKeyCode {
            #expect(retroKey < UInt32(LibretroKeyboard.keyCount))
        }
    }

    // Two physical keys sharing a retro_key would make one of them
    // indistinguishable from the other to the core.
    @Test("No two physical keys map to the same retro_key")
    func mappingIsInjective() {
        let mapped = LibretroKeyboard.retroKeysByMacKeyCode.values
        #expect(Set(mapped).count == mapped.count)
    }

    @Test("An unmapped key code produces nothing")
    func unmappedKeys() {
        #expect(LibretroKeyboard.retroKey(forMacKeyCode: 200) == nil)
    }
}

@Suite("Libretro keyboard input state")
struct LibretroKeyboardInputStateTests {
    @Test("A held key reads as pressed and a released one does not")
    func keyStateTracksPresses() {
        let input = LibretroInputState()
        input.setKeyboardEnabled(true)

        #expect(input.keyValue(for: 97) == 0)
        input.setKey(97, pressed: true, modifiers: 0)
        #expect(input.keyValue(for: 97) == 1)
        #expect(input.keyValue(for: 98) == 0)
        input.setKey(97, pressed: false, modifiers: 0)
        #expect(input.keyValue(for: 97) == 0)
    }

    @Test("Key events drain once, in order")
    func keyEventsDrainOnce() {
        let input = LibretroInputState()
        input.setKeyboardEnabled(true)
        input.setKey(97, pressed: true, modifiers: 1)
        input.setKey(97, pressed: false, modifiers: 0)

        let events = input.drainKeyEvents()
        #expect(events.count == 2)
        #expect(events.first?.key == 97)
        #expect(events.first?.pressed == true)
        #expect(events.first?.modifiers == 1)
        #expect(events.last?.pressed == false)
        // A second poll must not replay them.
        #expect(input.drainKeyEvents().isEmpty)
    }

    // Losing focus with a key held would otherwise leave a DOS game walking
    // into a wall forever.
    @Test("Losing the keyboard releases everything still held")
    func releasingKeyboardReportsReleases() {
        let input = LibretroInputState()
        input.setKeyboardEnabled(true)
        input.setKey(276, pressed: true, modifiers: 0)
        _ = input.drainKeyEvents()

        input.releaseKeyboard()

        #expect(input.keyValue(for: 276) == 0)
        let events = input.drainKeyEvents()
        #expect(events.contains(where: { $0.key == 276 && !$0.pressed }))
    }

    @Test("Keys are ignored until a core asks for a keyboard")
    func keyboardStartsDisabled() {
        let input = LibretroInputState()
        #expect(input.readsKeyboard == false)
        input.setKeyboardEnabled(true)
        #expect(input.readsKeyboard == true)
        input.setKeyboardEnabled(false)
        #expect(input.readsKeyboard == false)
        #expect(input.keyValue(for: 97) == 0)
    }

    @Test("A key beyond the retro_key range is dropped")
    func outOfRangeKeysDropped() {
        let input = LibretroInputState()
        input.setKeyboardEnabled(true)
        input.setKey(9_999, pressed: true, modifiers: 0)
        #expect(input.drainKeyEvents().isEmpty)
    }
}

@Suite("Libretro mouse input state")
struct LibretroMouseInputStateTests {
    @Test("Frontend advertises mouse and pointer device classes")
    func frontendDeviceCapabilitiesIncludePointingDevices() {
        let capabilities = LibretroInputState.supportedDeviceCapabilities

        #expect(capabilities & (UInt64(1) << 2) != 0) // mouse
        #expect(capabilities & (UInt64(1) << 6) != 0) // pointer
    }

    @Test("Relative motion is reported for one input poll")
    func relativeMotionIsConsumedOnce() {
        let input = LibretroInputState()
        input.moveMouse(deltaX: 12.75, deltaY: -7.25)

        input.pollMouse()
        #expect(input.mouseValue(for: 0) == 12)
        #expect(input.mouseValue(for: 1) == -7)

        input.pollMouse()
        #expect(input.mouseValue(for: 0) == 0)
        #expect(input.mouseValue(for: 1) == 0)
    }

    @Test("Fractional movement survives until it reaches a whole unit")
    func fractionalMovementAccumulates() {
        let input = LibretroInputState()
        input.moveMouse(deltaX: 0.4, deltaY: 0)
        input.pollMouse()
        #expect(input.mouseValue(for: 0) == 0)

        input.moveMouse(deltaX: 0.7, deltaY: 0)
        input.pollMouse()
        #expect(input.mouseValue(for: 0) == 1)
    }

    @Test("Mouse buttons remain held until released")
    func buttonsTrackHeldState() {
        let input = LibretroInputState()
        input.setMouseButton(2, pressed: true)
        input.setMouseButton(3, pressed: true)
        #expect(input.mouseValue(for: 2) == 1)
        #expect(input.mouseValue(for: 3) == 1)
        #expect(input.mouseValue(for: 6) == 0)

        input.releaseMouseButtons()
        #expect(input.mouseValue(for: 2) == 0)
        #expect(input.mouseValue(for: 3) == 0)
    }

    @Test("A wheel gesture becomes a one-frame direction pulse")
    func wheelPulsesOnce() {
        let input = LibretroInputState()
        input.scrollMouse(deltaY: -3)
        input.pollMouse()
        #expect(input.mouseValue(for: 4) == 0)
        #expect(input.mouseValue(for: 5) == 1)

        input.pollMouse()
        #expect(input.mouseValue(for: 5) == 0)
    }
}
