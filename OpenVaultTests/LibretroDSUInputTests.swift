import Foundation
import Testing

@testable import OpenVault

@Suite("DSU input mapping")
struct LibretroDSUInputTests {
  @Test("Maps DualShock face buttons onto the RetroPad diamond")
  func mapsFaceButtons() {
    // Cross is the southern button, which RetroPad calls B.
    #expect(mask(for: .a) == LibretroButton.b.mask)
    // Circle is the eastern button, which RetroPad calls A.
    #expect(mask(for: .b) == LibretroButton.a.mask)
    #expect(mask(for: .x) == LibretroButton.y.mask)
    #expect(mask(for: .y) == LibretroButton.x.mask)
  }

  @Test("Keeps a Nintendo pad's labels when the server publishes them")
  func mapsNintendoFaceButtons() {
    // A server bridging a Switch pad fills the DualShock slots by label, so
    // the labelled A button is RetroPad A rather than the southern button.
    #expect(mask(for: .a, layout: .nintendo) == LibretroButton.a.mask)
    #expect(mask(for: .b, layout: .nintendo) == LibretroButton.b.mask)
    #expect(mask(for: .x, layout: .nintendo) == LibretroButton.x.mask)
    #expect(mask(for: .y, layout: .nintendo) == LibretroButton.y.mask)
  }

  @Test("Confirms with the same physical button under either layout")
  func activatesConsistentlyAcrossLayouts() {
    var standard = BigPictureControllerState()
    var nintendo = BigPictureControllerState()
    var state = DSUPadState()

    // Circle on a DualShock and A on a Switch pad are the same position, and
    // both are what OpenVault confirms with.
    state.buttons = [.b]
    standard.merge(state, layout: .standard)
    #expect(standard.activate)
    #expect(!standard.back)

    state.buttons = [.a]
    nintendo.merge(state, layout: .nintendo)
    #expect(nintendo.activate)
    #expect(!nintendo.back)
  }

  @Test("Names the prompts for a pad that reports no button titles")
  func namesPromptsFromLayout() {
    var standard = BigPictureControllerState()
    standard.applyPrompts(for: .standard)
    #expect(standard.activateButtonPrompt.label == "B")
    #expect(standard.backButtonPrompt.label == "A")

    var nintendo = BigPictureControllerState()
    nintendo.applyPrompts(for: .nintendo)
    #expect(nintendo.activateButtonPrompt.label == "A")
    #expect(nintendo.backButtonPrompt.label == "B")
  }

  @Test("Maps the d-pad and shoulders straight through")
  func mapsDirectionsAndShoulders() {
    #expect(mask(for: .up) == LibretroButton.up.mask)
    #expect(mask(for: .down) == LibretroButton.down.mask)
    #expect(mask(for: .left) == LibretroButton.left.mask)
    #expect(mask(for: .right) == LibretroButton.right.mask)
    #expect(mask(for: .l1) == LibretroButton.l.mask)
    #expect(mask(for: .r1) == LibretroButton.r.mask)
    #expect(mask(for: .l2) == LibretroButton.l2.mask)
    #expect(mask(for: .r2) == LibretroButton.r2.mask)
  }

  @Test("Keeps Start, Select, and the stick clicks out of the button mask")
  func reportsSpecialButtonsSeparately() {
    var calibration = DSUTouchCalibration()
    var state = DSUPadState()
    state.buttons = [.options, .share, .leftStick, .rightStick]
    let pad = LibretroDSUInput.pad(from: state, layout: .standard, calibration: &calibration)

    // The runtime owns the exit chord and the transport controls, so these
    // stay out of the mask and are reported as flags instead.
    #expect(pad.buttons == 0)
    #expect(pad.isStartPressed)
    #expect(pad.isSelectPressed)
    #expect(pad.isLeftStickPressed)
    #expect(pad.isRightStickPressed)
  }

  @Test("Centers a resting stick and flips Y into screen orientation")
  func mapsSticks() {
    var calibration = DSUTouchCalibration()
    var state = DSUPadState()

    let resting = LibretroDSUInput.pad(from: state, layout: .standard, calibration: &calibration)
    #expect(resting.leftAnalogX == 0)
    #expect(resting.leftAnalogY == 0)

    // The protocol reports 255 as up; Libretro expects up to be negative.
    state.leftStick = DSUStick(x: 255, y: 255)
    state.rightStick = DSUStick(x: 0, y: 0)
    let pushed = LibretroDSUInput.pad(from: state, layout: .standard, calibration: &calibration)
    #expect(pushed.leftAnalogX == Int16.max)
    #expect(pushed.leftAnalogY == -Int16.max)
    #expect(pushed.rightAnalogX == -Int16.max)
    #expect(pushed.rightAnalogY == Int16.max)
  }

  @Test("Converts motion into the units Libretro's sensor interface uses")
  func convertsMotionUnits() {
    let sensors = LibretroSensorValues.from(
      DSUMotion(
        timestamp: 0,
        accelerationX: 1,
        accelerationY: -2,
        accelerationZ: 0,
        pitch: 180,
        yaw: -90,
        roll: 0
      )
    )

    // Acceleration arrives in g and leaves in m/s².
    #expect(abs(sensors.accelerationX - 9.806_65) < 0.001)
    #expect(abs(sensors.accelerationY + 19.613_3) < 0.001)
    // Rotation arrives in degrees per second and leaves in radians.
    #expect(abs(sensors.gyroscopeX - Float.pi) < 0.001)
    #expect(abs(sensors.gyroscopeY + Float.pi / 2) < 0.001)
    #expect(sensors.gyroscopeZ == 0)
  }

  @Test("Reports no pointer until the touchpad is being touched")
  func mapsTouchToPointer() {
    var calibration = DSUTouchCalibration()
    var state = DSUPadState()
    #expect(LibretroDSUInput.pad(from: state, layout: .standard, calibration: &calibration).pointer == nil)

    state.touches[0] = DSUTouch(isActive: true, id: 1, x: 0, y: 0)
    let topLeft = LibretroDSUInput.pad(from: state, layout: .standard, calibration: &calibration)
    #expect(topLeft.pointer == LibretroDSUInput.Pointer(x: -32_767, y: -32_767, isPressed: true))

    state.touches[0] = DSUTouch(isActive: true, id: 1, x: 1_919, y: 941)
    let bottomRight = LibretroDSUInput.pad(from: state, layout: .standard, calibration: &calibration)
    #expect(bottomRight.pointer?.x == 32_767)
    #expect(bottomRight.pointer?.y == 32_767)
  }

  @Test("Widens the touchpad range when a pad reports beyond the default")
  func calibratesTouchRange() {
    var calibration = DSUTouchCalibration()
    // A DualSense is taller than the DualShock 4 the defaults assume.
    _ = calibration.normalized(DSUTouch(isActive: true, id: 0, x: 1_919, y: 1_079))
    #expect(calibration.maximumY == 1_079)

    let middle = calibration.normalized(DSUTouch(isActive: true, id: 0, x: 0, y: 1_079))
    #expect(middle.y == 32_767)
  }

  @Test("Drives Big Picture navigation from a network pad")
  func mergesIntoBigPictureNavigation() {
    var state = DSUPadState()
    state.isConnected = true
    state.buttons = [.b, .l1]
    state.leftStick = DSUStick(x: 128, y: 255)

    var navigation = BigPictureControllerState()
    navigation.merge(state)

    #expect(navigation.isConnected)
    // A stick held up navigates up, the same as the d-pad would.
    #expect(navigation.up)
    #expect(!navigation.down)
    #expect(navigation.activate)
    #expect(!navigation.back)
    #expect(navigation.pageUp)
    #expect(!navigation.pageDown)
  }

  @Test("Treats Share as the Big Picture sync status button")
  func mergesAuxiliaryButtons() {
    var state = DSUPadState()
    state.buttons = [.share, .options]

    var navigation = BigPictureControllerState()
    navigation.merge(state)

    #expect(navigation.showsSyncStatus)
    #expect(navigation.opensBigPicture)
    // The pad's Options button is the Start/Menu button, which now opens the
    // game options rather than launching the selection.
    #expect(navigation.opensGameOptions)
  }

  private func mask(
    for button: DSUButtons,
    layout: ControllerFaceButtonLayout = .standard
  ) -> UInt16 {
    var calibration = DSUTouchCalibration()
    var state = DSUPadState()
    state.buttons = button
    return LibretroDSUInput.pad(
      from: state,
      layout: layout,
      calibration: &calibration
    ).buttons
  }
}
