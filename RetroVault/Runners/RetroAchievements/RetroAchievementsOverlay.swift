import AVFoundation
import SwiftUI

struct RetroAchievementsToast: Identifiable, Equatable {
  enum Style: Equatable {
    case loaded
    case unlock
    case mastery
    case leaderboard
    case message
  }

  let id = UUID()
  var style: Style
  var title: String
  var detail: String
  var badgeURL: URL?
  var points: Int?
  var hardcore: Bool

  var dwells: Duration {
    switch style {
    case .loaded:
      .seconds(3.2)
    case .unlock, .leaderboard, .message:
      .seconds(4.6)
    case .mastery:
      .seconds(6.5)
    }
  }
}

struct RetroAchievementsOverlay: View {
  let toasts: [RetroAchievementsToast]
  let progressTitle: String?
  let progressDetail: String?
  let leaderboard: String?
  let richPresence: String?
  let onDismiss: (RetroAchievementsToast.ID) -> Void

  var body: some View {
    VStack(alignment: .trailing, spacing: 10) {
      ForEach(toasts.prefix(3)) { toast in
        RetroAchievementsToastCard(toast: toast)
          .transition(
            .asymmetric(
              insertion: .move(edge: .top).combined(with: .opacity),
              removal: .opacity
            )
          )
          .task(id: toast.id) {
            try? await Task.sleep(for: toast.dwells)
            onDismiss(toast.id)
          }
      }

      if let progressTitle, let progressDetail, !progressDetail.isEmpty {
        RetroAchievementsStatusChip(
          systemImage: "chart.bar.fill",
          title: progressTitle,
          detail: progressDetail
        )
      }

      if let leaderboard, !leaderboard.isEmpty {
        RetroAchievementsStatusChip(
          systemImage: "flag.checkered",
          title: "Leaderboard",
          detail: leaderboard
        )
      }

      if let richPresence, !richPresence.isEmpty {
        Text(richPresence)
          .font(.caption.weight(.medium))
          .foregroundStyle(.white.opacity(0.86))
          .lineLimit(2)
          .padding(.horizontal, 12)
          .padding(.vertical, 7)
          .openVaultGlass(in: Capsule())
      }
    }
    .padding(22)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: toasts.map(\.id))
    .allowsHitTesting(false)
  }
}

private struct RetroAchievementsToastCard: View {
  let toast: RetroAchievementsToast
  @State private var appeared = false

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      badge

      VStack(alignment: .leading, spacing: 3) {
        Text(eyebrow)
          .font(.caption2.weight(.semibold))
          .tracking(0.6)
          .foregroundStyle(accent)

        Text(toast.title)
          .font(toast.style == .mastery ? .title3.bold() : .headline)
          .foregroundStyle(.white)
          .lineLimit(2)

        if !toast.detail.isEmpty {
          Text(toast.detail)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(3)
        }
      }

      if let points = toast.points, points > 0, toast.style == .unlock {
        Text("+\(points)")
          .font(.title3.weight(.bold).monospacedDigit())
          .foregroundStyle(accent)
      }
    }
    .padding(14)
    .frame(maxWidth: toast.style == .mastery ? 460 : 420, alignment: .leading)
    .openVaultGlass(tint: accent.opacity(toast.style == .mastery ? 0.28 : 0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(accent.opacity(0.45), lineWidth: toast.style == .mastery ? 1.5 : 1)
    }
    .scaleEffect(appeared ? 1 : 0.94)
    .onAppear {
      withAnimation(.spring(response: 0.46, dampingFraction: 0.72)) {
        appeared = true
      }
      if toast.style == .unlock {
        RetroAchievementsChime.playUnlock()
      } else if toast.style == .mastery {
        RetroAchievementsChime.playMastery()
      }
    }
  }

  private var eyebrow: String {
    switch toast.style {
    case .loaded:
      "RetroAchievements"
    case .unlock:
      toast.hardcore ? "Hardcore unlock" : "Achievement unlocked"
    case .mastery:
      toast.hardcore ? "Mastered" : "Set complete"
    case .leaderboard:
      "Leaderboard"
    case .message:
      "RetroAchievements"
    }
  }

  private var accent: Color {
    toast.style == .mastery || toast.hardcore
      ? Color(red: 0.96, green: 0.78, blue: 0.34)
      : Color(red: 0.55, green: 0.78, blue: 1)
  }

  @ViewBuilder
  private var badge: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(accent.opacity(0.18))
      if let badgeURL = toast.badgeURL {
        AsyncImage(url: badgeURL) { phase in
          switch phase {
          case .success(let image):
            image.resizable().scaledToFit().padding(4)
          default:
            Image(systemName: symbol)
              .font(.title2)
              .foregroundStyle(accent)
          }
        }
      } else {
        Image(systemName: symbol)
          .font(.title2)
          .foregroundStyle(accent)
      }
    }
    .frame(width: 64, height: 64)
  }

  private var symbol: String {
    switch toast.style {
    case .loaded:
      "trophy"
    case .unlock:
      "trophy.fill"
    case .mastery:
      "star.circle.fill"
    case .leaderboard:
      "flag.checkered"
    case .message:
      "rosette"
    }
  }
}

private struct RetroAchievementsStatusChip: View {
  let systemImage: String
  let title: String
  let detail: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .foregroundStyle(Color(red: 0.96, green: 0.78, blue: 0.34))
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.white.opacity(0.7))
        Text(detail)
          .font(.caption.weight(.semibold).monospacedDigit())
          .foregroundStyle(.white)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .openVaultGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

enum RetroAchievementsChime {
  static func playUnlock() {
    play(notes: [(880, 0.07), (1318, 0.11)])
  }

  static func playMastery() {
    play(notes: [(523, 0.08), (659, 0.08), (784, 0.08), (1046, 0.16)])
  }

  private static func play(notes: [(frequency: Double, duration: Double)]) {
    let sampleRate = 44_100.0
    var samples: [Int16] = []
    for (index, note) in notes.enumerated() {
      let count = Int(sampleRate * note.duration)
      for sample in 0..<count {
        let time = Double(sample) / sampleRate
        let envelope = min(1, Double(sample) / 200) * min(1, Double(count - sample) / 500)
        let wave = sin(2 * Double.pi * note.frequency * time)
        samples.append(Int16(wave * envelope * 0.18 * Double(Int16.max)))
      }
      if index < notes.count - 1 {
        samples.append(contentsOf: repeatElement(0, count: Int(sampleRate * 0.02)))
      }
    }
    let data = wavData(samples: samples, sampleRate: Int(sampleRate))
    RetroAchievementsChimePlayer.shared.play(data)
  }

  private static func wavData(samples: [Int16], sampleRate: Int) -> Data {
    var data = Data()
    let dataLength = samples.count * 2
    func append(_ string: String) {
      data.append(contentsOf: string.utf8)
    }
    func append32(_ value: UInt32) {
      var little = value.littleEndian
      data.append(Data(bytes: &little, count: 4))
    }
    func append16(_ value: UInt16) {
      var little = value.littleEndian
      data.append(Data(bytes: &little, count: 2))
    }
    append("RIFF")
    append32(UInt32(36 + dataLength))
    append("WAVE")
    append("fmt ")
    append32(16)
    append16(1)
    append16(1)
    append32(UInt32(sampleRate))
    append32(UInt32(sampleRate * 2))
    append16(2)
    append16(16)
    append("data")
    append32(UInt32(dataLength))
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    return data
  }
}

private final class RetroAchievementsChimePlayer: NSObject, AVAudioPlayerDelegate {
  static let shared = RetroAchievementsChimePlayer()
  private var players: [AVAudioPlayer] = []

  func play(_ data: Data) {
    guard let player = try? AVAudioPlayer(data: data) else {
      return
    }
    player.volume = 0.55
    player.delegate = self
    players.append(player)
    player.play()
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    players.removeAll { $0 === player }
  }
}
