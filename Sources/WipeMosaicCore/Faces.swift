import CoreImage
import Vision

/// Thread-safe slots for results produced by concurrentPerform.
final class ResultBox<T>: @unchecked Sendable {
    private var slots: [Result<T, Error>?]
    private let lock = NSLock()
    init(count: Int) { slots = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ r: Result<T, Error>) { lock.withLock { slots[i] = r } }
    func values() throws -> [T] { try lock.withLock { slots }.map { try $0!.get() } }
}

/// Boxes for one frame, in Core Image coordinates (pixels, bottom-left origin).
public struct FrameFaces: Sendable {
    public let time: Double
    /// Faces to mosaic; the face margin (pad) is added when drawing.
    public let mosaic: [CGRect]
    public let kept: [CGRect]
    /// Other boxes to mosaic exactly as given (on-screen text, margin already included).
    public let exact: [CGRect]
    /// For each of `exact`, the corner its mosaic blocks line up with (empty: each box's own).
    public let exactAnchors: [CGPoint]
    /// Faces covered by a person's sticker instead of the mosaic (not in `mosaic`).
    public let stickers: [StickerBox]
    public init(
        time: Double, mosaic: [CGRect], kept: [CGRect], exact: [CGRect] = [], exactAnchors: [CGPoint] = [],
        stickers: [StickerBox] = []
    ) {
        self.time = time
        self.mosaic = mosaic
        self.kept = kept
        self.exact = exact
        self.exactAnchors = exactAnchors
        self.stickers = stickers
    }

    /// Faces hidden in this frame, by mosaic or sticker.
    public var faceCount: Int { mosaic.count + stickers.count }
    /// Something is hidden in this frame.
    public var hidesAnything: Bool { !mosaic.isEmpty || !exact.isEmpty || !stickers.isEmpty }
}

private func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

/// Detect faces in one region; returns rects in the image's coordinates.
private func detect(in image: CIImage, region: CGRect) throws -> [CGRect] {
    let crop = image.cropped(to: region)
        .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
    let req = VNDetectFaceRectanglesRequest()
    try VNImageRequestHandler(ciImage: crop, orientation: .up, options: [:]).perform([req])
    return (req.results ?? []).map {
        VNImageRectForNormalizedRect($0.boundingBox, Int(region.width), Int(region.height))
            .offsetBy(dx: region.minX, dy: region.minY)
    }
}

/// Overlapping grid tiles (tiles x tiles, 25% overlap) so small faces are not lost
/// when Vision downsamples the full frame.
private func tileRects(_ ext: CGRect, tiles: Int) -> [CGRect] {
    guard tiles > 1 else { return [] }
    let overlap: CGFloat = 0.25
    let tw = ext.width / (CGFloat(tiles) - overlap * CGFloat(tiles - 1))
    let th = ext.height / (CGFloat(tiles) - overlap * CGFloat(tiles - 1))
    var out: [CGRect] = []
    for row in 0..<tiles {
        for col in 0..<tiles {
            let x = ext.minX + CGFloat(col) * tw * (1 - overlap)
            let y = ext.minY + CGFloat(row) * th * (1 - overlap)
            out.append(CGRect(x: x, y: y, width: tw, height: th).integral.intersection(ext))
        }
    }
    return out
}

/// Merge boxes that describe the same face (from full frame and tiles) into their union.
private func mergeDuplicates(_ rects: [CGRect]) -> [CGRect] {
    var merged: [CGRect] = []
    for r in rects.sorted(by: { area($0) > area($1) }) {
        if let i = merged.firstIndex(where: {
            let inter = area($0.intersection(r))
            return inter > 0 && inter / min(area($0), area(r)) >= 0.5
        }) {
            merged[i] = merged[i].union(r)
        } else {
            merged.append(r)
        }
    }
    return merged
}

/// Full frame + grid tiles + each extra region (the wipes, slightly enlarged), merged.
/// Wipes get their own pass because a second person inside the wipe is the case where
/// a miss would leave someone other than the presenter unmasked.
public func detectFaces(image: CIImage, tiles: Int, extraRegions: [CGRect]) throws -> [CGRect] {
    let ext = image.extent
    var regions = [ext] + tileRects(ext, tiles: tiles)
    for r in extraRegions {
        let e = r.insetBy(dx: -r.width * 0.1, dy: -r.height * 0.1).integral.intersection(ext)
        if !e.isNull && !e.isEmpty { regions.append(e) }
    }
    // Each Vision request mostly waits on the Neural Engine/GPU, so run the regions concurrently.
    let results = ResultBox<[CGRect]>(count: regions.count)
    DispatchQueue.concurrentPerform(iterations: regions.count) { i in
        results.set(i, Result { try detect(in: image, region: regions[i]) })
    }
    return mergeDuplicates(try results.values().flatMap { $0 })
}

/// Convert a top-left-origin rect (player coordinates) to Core Image coordinates.
public func toCIRect(_ r: CGRect, videoHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: videoHeight - r.minY - r.height, width: r.width, height: r.height)
}

/// Faces mostly inside a wipe are candidates to keep; per wipe only the largest is kept
/// unless keepAll. Everything else is mosaicked.
public func classify(faces: [CGRect], wipes: [CGRect], minInside: Double, keepAll: Bool)
    -> (mosaic: [CGRect], kept: [CGRect])
{
    var mosaic: [CGRect] = []
    var candidates: [Int: [CGRect]] = [:]
    for f in faces {
        let a = area(f)
        let idx = wipes.firstIndex { a > 0 && Double(area(f.intersection($0)) / a) >= minInside }
        if let idx { candidates[idx, default: []].append(f) } else { mosaic.append(f) }
    }
    var kept: [CGRect] = []
    for c in candidates.values {
        if keepAll {
            kept += c
        } else {
            let sorted = c.sorted { area($0) > area($1) }
            kept.append(sorted[0])
            mosaic += sorted.dropFirst()
        }
    }
    return (mosaic, kept)
}

public func padded(_ r: CGRect, _ pad: Double) -> CGRect {
    r.insetBy(dx: -r.width * pad, dy: -r.height * pad)
}

public func autoBlock(_ size: CGSize) -> CGFloat {
    max(2, (max(size.width, size.height) / 60).rounded())
}

/// The whole image in blocks of `block` px, each the average colour of the pixels under it.
/// CIPixellate alone takes the colour at the block centre, so thin high-contrast strokes
/// (text) that move by a pixel flip whole blocks between black and white: heavy flicker when
/// the screen scrolls or the camera moves, and over many frames the samples would show the
/// actual pixels at many positions. Averaging first keeps each block steady.
/// The blocks line up with `origin` (default: the corner of the image).
public func pixellated(_ img: CIImage, block: CGFloat, origin: CGPoint? = nil) -> CIImage {
    let ext = img.extent
    let o = origin ?? ext.origin
    return img.clampedToExtent()
        // CIBoxBlur averages over (radius − 1) px (measured), so this is one block wide.
        .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: block + 1])
        .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: o.x, y: o.y)])
        .cropped(to: ext)
}

/// `rects` (faces) share one grid fixed to the image: a face box jitters a little every
/// frame, and blocks fixed in place do not. Each of `moving` (on-screen text) has its blocks
/// lined up with its anchor (where its line is; its own corner when `anchors` does not match),
/// so they move with the text when the screen scrolls or the camera moves; on a grid fixed to
/// the image the text slid under the blocks and they kept changing (wobbling) instead.
public func applyMosaic(
    _ img: CIImage, rects: [CGRect], moving: [CGRect] = [], anchors: [CGPoint] = [], block: CGFloat
) -> CIImage {
    guard !rects.isEmpty || !moving.isEmpty else { return img }
    let ext = img.extent
    var out = img
    if !rects.isEmpty {
        let pix = pixellated(img, block: block)
        for r in rects {
            let c = r.intersection(ext)
            if !c.isNull && !c.isEmpty { out = pix.cropped(to: c).composited(over: out) }
        }
    }
    return movingBlocks(img, over: out, moving: moving, anchors: anchors, block: block)
}

/// The boxes of `moving` in blocks lined up with their anchors, drawn over `base`.
func movingBlocks(_ img: CIImage, over base: CIImage, moving: [CGRect], anchors: [CGPoint], block: CGFloat) -> CIImage {
    let ext = img.extent
    var out = base
    for (i, r) in moving.enumerated() {
        let c = r.intersection(ext)
        guard !c.isNull && !c.isEmpty else { continue }
        let origin = anchors.count == moving.count ? anchors[i] : r.origin
        out = pixellated(img, block: block, origin: origin).cropped(to: c).composited(over: out)
    }
    return out
}
