import Foundation
import Testing

@testable import RetroVault

@Suite("Server reachability")
struct ServerReachabilityTests {
  @Test(
    "Treats genuine transport failures as an unreachable server",
    arguments: [
      URLError.Code.cannotConnectToHost,
      .cannotFindHost,
      .dnsLookupFailed,
      .networkConnectionLost,
      .notConnectedToInternet,
      .timedOut,
    ])
  func detectsUnreachableServer(code: URLError.Code) {
    #expect(
      RomMAPIError.indicatesServerUnreachable(
        RomMAPIError.transport(URLError(code))
      )
    )
    // The same judgement holds for a bare URLError that never got wrapped.
    #expect(RomMAPIError.indicatesServerUnreachable(URLError(code)))
  }

  @Test(
    "Keeps answered requests online, whatever the answer was",
    arguments: [
      RomMAPIError.unauthorized,
      .forbidden,
      .notFound,
      .invalidResponse,
      .downloadUnavailable,
      .rejectedPairingCode,
      .server(statusCode: 500),
      .server(statusCode: 503),
    ])
  func keepsAnsweredRequestsOnline(error: RomMAPIError) {
    // A server that refuses, redirects, or errors is still a server that
    // answered, so none of these may put RetroVault offline.
    #expect(!RomMAPIError.indicatesServerUnreachable(error))
  }

  @Test("Never treats cancellation as being offline")
  func ignoresCancellation() {
    #expect(!RomMAPIError.indicatesServerUnreachable(CancellationError()))
    // URLSession reports a cancelled task this way rather than throwing
    // CancellationError, which is what made a cancelled sync look offline.
    #expect(
      !RomMAPIError.indicatesServerUnreachable(
        RomMAPIError.transport(URLError(.cancelled))
      )
    )
    #expect(!RomMAPIError.indicatesServerUnreachable(URLError(.cancelled)))
  }

  @Test("Never treats a decoding failure as being offline")
  func ignoresDecodingFailures() {
    let failure = RomMAPIError.decoding(
      DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: [], debugDescription: "bad")
      )
    )
    #expect(!RomMAPIError.indicatesServerUnreachable(failure))
  }

  @Test("Ignores errors it knows nothing about")
  func ignoresUnrelatedErrors() {
    struct SomeOtherFailure: Error {}
    #expect(!RomMAPIError.indicatesServerUnreachable(SomeOtherFailure()))
  }

  @Test("Starts online and only goes offline on real transport failures")
  func tracksReachabilityFromTraffic() {
    let reachability = RomMReachability()
    // Nothing has been attempted yet, so nothing justifies an offline state.
    #expect(reachability.isReachable)

    reachability.recordFailure(RomMAPIError.unauthorized)
    #expect(reachability.isReachable)

    reachability.recordFailure(
      RomMAPIError.transport(URLError(.notConnectedToInternet))
    )
    #expect(!reachability.isReachable)
  }

  @Test("Lets any answered request clear an offline state")
  func recoversOnAnyAnsweredRequest() {
    let reachability = RomMReachability()
    reachability.recordFailure(
      RomMAPIError.transport(URLError(.cannotConnectToHost))
    )
    #expect(!reachability.isReachable)

    // Even a refusal proves the server is back, so one call from any feature
    // is enough to recover.
    reachability.recordServerAnswered()
    #expect(reachability.isReachable)
  }

  @Test("Publishes the current value and every change to observers")
  func publishesChanges() async {
    let reachability = RomMReachability()
    var received: [Bool] = []

    let observation = Task {
      for await value in reachability.changes() {
        received.append(value)
        if received.count == 3 {
          break
        }
      }
      return received
    }

    // Give the stream a moment to deliver its current value first.
    try? await Task.sleep(for: .milliseconds(50))
    reachability.recordFailure(RomMAPIError.transport(URLError(.timedOut)))
    reachability.recordServerAnswered()

    let values = await observation.value
    #expect(values == [true, false, true])
  }
}
