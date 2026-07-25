import AppKit
import Nuke
import SwiftUI

struct GameCoverView: View {
    let game: GameSummary
    let session: ServerSession
    let service: any LibraryServing

    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
                    .transition(.opacity)
            } else {
                Image(systemName: didFail ? "photo.badge.exclamationmark" : "gamecontroller")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 0.5)
        }
        .task(id: game.coverURL) {
            await loadImage()
        }
    }

    private func loadImage() async {
        image = nil
        didFail = false

        do {
            guard let urlRequest = try await service.artworkRequest(for: game, in: session) else {
                return
            }

            let request = ImageRequest(
                urlRequest: urlRequest,
                processors: [
                    ImageProcessors.Resize(
                        size: CGSize(width: 360, height: 480),
                        unit: .pixels,
                        contentMode: .aspectFit
                    ),
                ]
            )
            image = try await ImagePipeline.shared.image(for: request)
        } catch is CancellationError {
            return
        } catch {
            didFail = true
        }
    }
}
