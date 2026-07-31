import AppKit
import Nuke
import SwiftUI

struct GameCoverView: View {
    let game: GameSummary
    let session: ServerSession
    let service: any LibraryServing

    var body: some View {
        RomMImageView(
            url: game.coverURL,
            session: session,
            service: service,
            targetSize: CGSize(width: 360, height: 480),
            contentMode: .fit,
            placeholderSystemImage: "gamecontroller",
            cornerRadius: 10,
            imagePadding: 5
        )
        .aspectRatio(3 / 4, contentMode: .fit)
    }
}

struct RomMImageView: View {
    let url: URL?
    let session: ServerSession
    let service: any LibraryServing
    let targetSize: CGSize
    let contentMode: ContentMode
    let placeholderSystemImage: String
    let cornerRadius: CGFloat
    let imagePadding: CGFloat

    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary)

            if let image {
                renderedImage(image)
                    .padding(imagePadding)
                    .transition(.opacity)
            } else {
                Image(systemName: didFail ? "photo.badge.exclamationmark" : placeholderSystemImage)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(
            minWidth: 0,
            maxWidth: .infinity,
            minHeight: 0,
            maxHeight: .infinity
        )
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 0.5)
        }
        .task(id: url) {
            await loadImage()
        }
    }

    @ViewBuilder
    private func renderedImage(_ image: NSImage) -> some View {
        if contentMode == .fit {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        }
    }

    private func loadImage() async {
        image = nil
        didFail = false

        do {
            guard let urlRequest = try await service.resourceRequest(for: url, in: session) else {
                return
            }

            let request = ImageRequest(
                urlRequest: urlRequest,
                processors: [
                    ImageProcessors.Resize(
                        size: targetSize,
                        unit: .pixels,
                        contentMode: contentMode == .fit ? .aspectFit : .aspectFill
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
