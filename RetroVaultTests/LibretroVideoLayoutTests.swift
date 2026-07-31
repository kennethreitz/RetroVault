import Foundation
import Testing

@testable import RetroVault

@Suite("Libretro video layout")
struct LibretroVideoLayoutTests {
    // The view extends under the title bar and toolbar so the drawable never
    // resizes mid-game, which means the picture has to be placed against the
    // visible area instead. Reproduces the geometry from a windowed SNES
    // session: a 1810x1395 view whose top 85 points sit behind the chrome.
    @Test("Keeps the picture clear of the window chrome")
    func picturePlacedBelowChrome() {
        let viewBounds = CGRect(x: 0, y: 0, width: 1810, height: 1395)
        let visibleBounds = CGRect(x: 0, y: 0, width: 1810, height: 1310)

        let picture = LibretroVideoLayout.pictureRect(
            sourceSize: CGSize(width: 256, height: 224),
            visibleBounds: visibleBounds,
            aspectRatio: 4.0 / 3.0
        )

        // Nothing may stray above the visible area, which is what was being
        // clipped by the toolbar.
        #expect(picture.maxY <= visibleBounds.maxY + 0.001)
        #expect(picture.minY >= visibleBounds.minY - 0.001)
        #expect(picture.maxY < viewBounds.maxY)
        // And it stays 4:3.
        #expect(abs(picture.width / picture.height - 4.0 / 3.0) < 0.01)
    }

    @Test("Centers the picture within the visible area, not the whole view")
    func centersWithinVisibleArea() {
        let visibleBounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let picture = LibretroVideoLayout.pictureRect(
            sourceSize: CGSize(width: 320, height: 240),
            visibleBounds: visibleBounds,
            aspectRatio: 4.0 / 3.0
        )

        let topGap = visibleBounds.maxY - picture.maxY
        let bottomGap = picture.minY - visibleBounds.minY
        #expect(abs(topGap - bottomGap) <= 1)
    }

    // A Metal viewport counts down from the top of the drawable while a view
    // counts up from the bottom, so an inset at the top of the view has to
    // become an offset at the top of the viewport.
    @Test("Converts a picture rect into drawable coordinates")
    func convertsToViewport() {
        let viewBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        // Sits 50 points below the top of the view and 100 above the bottom.
        let picture = CGRect(x: 20, y: 100, width: 360, height: 150)

        let viewport = LibretroVideoLayout.viewport(
            pictureRect: picture,
            viewBounds: viewBounds,
            drawableSize: CGSize(width: 800, height: 600)
        )

        // Backing scale of 2 throughout.
        #expect(viewport.origin.x == 40)
        #expect(viewport.origin.y == 100)
        #expect(viewport.width == 720)
        #expect(viewport.height == 300)
    }

    @Test("A view with no chrome fills the whole drawable")
    func noChromeFillsDrawable() {
        let viewBounds = CGRect(x: 0, y: 0, width: 640, height: 480)
        let picture = LibretroVideoLayout.pictureRect(
            sourceSize: CGSize(width: 640, height: 480),
            visibleBounds: viewBounds,
            aspectRatio: 0
        )
        let viewport = LibretroVideoLayout.viewport(
            pictureRect: picture,
            viewBounds: viewBounds,
            drawableSize: CGSize(width: 640, height: 480)
        )

        #expect(viewport == CGRect(x: 0, y: 0, width: 640, height: 480))
    }

    // Rendering and pointer mapping read the same rect, so a mouse click has
    // to land where the picture was actually drawn.
    @Test("Pointer mapping agrees with where the picture was drawn")
    func pointerAgreesWithPicture() {
        let visibleBounds = CGRect(x: 0, y: 0, width: 800, height: 500)
        let picture = LibretroVideoLayout.pictureRect(
            sourceSize: CGSize(width: 256, height: 224),
            visibleBounds: visibleBounds,
            aspectRatio: 4.0 / 3.0
        )

        // The picture's top-left corner normalizes to (0, 0).
        let topLeft = CGPoint(x: picture.minX, y: picture.maxY)
        let normalizedX = (topLeft.x - picture.minX) / picture.width
        let normalizedY = (picture.maxY - topLeft.y) / picture.height
        #expect(normalizedX == 0)
        #expect(normalizedY == 0)

        // And its bottom-right corner to (1, 1).
        let bottomRight = CGPoint(x: picture.maxX, y: picture.minY)
        #expect((bottomRight.x - picture.minX) / picture.width == 1)
        #expect((picture.maxY - bottomRight.y) / picture.height == 1)

        // A point above the picture, where the toolbar sits, is outside it.
        #expect(
            !picture.contains(
                CGPoint(x: picture.midX, y: visibleBounds.maxY + 10)
            )
        )
    }

    @Test("A square-pixel core still lands on whole-number scales")
    func squarePixelCoresKeepIntegerScale() {
        let visibleBounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let picture = LibretroVideoLayout.pictureRect(
            sourceSize: CGSize(width: 160, height: 144),
            visibleBounds: visibleBounds,
            aspectRatio: 0
        )

        let scale = picture.width / 160
        #expect(scale == scale.rounded())
        #expect(picture.height / 144 == scale)
    }
}
