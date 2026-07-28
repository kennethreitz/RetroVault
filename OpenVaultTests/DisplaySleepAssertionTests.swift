import Foundation
import Testing

@testable import OpenVault

@Suite("Display sleep assertion")
struct DisplaySleepAssertionTests {
  @Test("Holds nothing until gameplay asks for it")
  func startsInactive() {
    #expect(!DisplaySleepAssertion().isActive)
  }

  @Test("Holds the display awake while a game runs")
  func holdsWhileRunning() {
    let assertion = DisplaySleepAssertion()

    assertion.begin(reason: "Playing a game")
    #expect(assertion.isActive)

    assertion.end()
    #expect(!assertion.isActive)
  }

  @Test("Keeps a single assertion when gameplay asks repeatedly")
  func doesNotStackAssertions() {
    let assertion = DisplaySleepAssertion()

    assertion.begin(reason: "First")
    assertion.begin(reason: "Second")
    assertion.begin(reason: "Third")
    #expect(assertion.isActive)

    // One release is enough because only one assertion was ever taken; a
    // stacked implementation would leave the display pinned awake here.
    assertion.end()
    #expect(!assertion.isActive)
  }

  @Test("Ignores a release when nothing is held")
  func toleratesRedundantRelease() {
    let assertion = DisplaySleepAssertion()

    assertion.end()
    #expect(!assertion.isActive)

    assertion.begin(reason: "Playing a game")
    assertion.end()
    assertion.end()
    #expect(!assertion.isActive)
  }

  @Test("Can be taken again after being released")
  func resumesAfterRelease() {
    let assertion = DisplaySleepAssertion()

    assertion.begin(reason: "Playing a game")
    assertion.end()
    // Pausing releases and resuming retakes it, so this has to work more than
    // once for the lifetime of one session.
    assertion.begin(reason: "Playing a game")
    #expect(assertion.isActive)

    assertion.end()
    #expect(!assertion.isActive)
  }
}
