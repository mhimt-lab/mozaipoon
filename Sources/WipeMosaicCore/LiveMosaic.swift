import AVFoundation
import CoreImage

/// Mosaic applied during playback (AVPlayer preview), identical to what the export writes.
/// The composition's filter reads the current selection and settings from this object, so
/// changing them needs no new composition — only a redraw of the current frame.
public final class LiveMosaic: @unchecked Sendable {
    private let lock = NSLock()
    private var index = FaceIndex(frames: [])
    private var render = RenderSettings()
    private var enabled = false

    public init() {}

    public func update(frames: [FrameFaces], render: RenderSettings, enabled: Bool) {
        let sorted = FaceIndex(frames: frames.sorted { $0.time < $1.time })
        lock.withLock {
            index = sorted
            self.render = render
            self.enabled = enabled
        }
    }

    /// A composition for `asset` whose frames get the current mosaic.
    public func composition(for asset: AVAsset) async throws -> AVVideoComposition {
        try await AVVideoComposition.videoComposition(with: asset) { [self] request in
            let source = request.sourceImage
            let (index, render, enabled) = lock.withLock { (self.index, self.render, self.enabled) }
            let origin = source.extent.origin
            let t = request.compositionTime.seconds
            let rects = enabled
                ? index.allRects(at: t, hold: render.hold, pad: render.pad).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
                : []
            let stickers = enabled
                ? index.stickerBoxes(at: t).map { StickerBox(rect: $0.rect.offsetBy(dx: origin.x, dy: origin.y), person: $0.person) }
                : []
            guard !rects.isEmpty || !stickers.isEmpty else {
                request.finish(with: source, context: nil)
                return
            }
            let out = applyCover(
                source, rects: rects, stickers: stickers, render: render, block: render.blockSize(for: source.extent.size))
            request.finish(with: out, context: nil)
        }
    }
}
