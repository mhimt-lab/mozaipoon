import AppKit

/// The progress of the work in hand (finding faces, reading text, writing files) on the app's
/// Dock icon: a search or an export of a long video takes minutes, usually with the app behind
/// another one.
@MainActor
enum DockProgress {
    private static let view = DockProgressView()

    /// `fraction` 0...1 draws a bar under the icon; nil puts the plain icon back.
    static func show(_ fraction: Double?) {
        let tile = NSApp.dockTile
        guard let fraction else {
            guard tile.contentView != nil else { return }
            tile.contentView = nil
            tile.display()
            return
        }
        view.fraction = min(max(fraction, 0), 1)
        if tile.contentView !== view { tile.contentView = view }
        tile.display()
    }
}

/// The app icon with a progress bar along its foot (as Finder and Safari draw one).
private final class DockProgressView: NSView {
    var fraction = 0.0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
        // Inside the icon's shape (which leaves a margin in the tile), so the track has one
        // background: over the icon's edge, half of it lay on the icon and half on the Dock.
        let track = NSRect(x: bounds.width * 0.19, y: bounds.height * 0.17, width: bounds.width * 0.62, height: bounds.height * 0.085)
        let radius = track.height / 2
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let inner = track.insetBy(dx: 1.5, dy: 1.5)
        var done = inner
        done.size.width = max(inner.height, inner.width * fraction)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: done, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }
}
