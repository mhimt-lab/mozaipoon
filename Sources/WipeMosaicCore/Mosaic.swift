import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public struct ToolError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ message: String) { description = message }
    public var errorDescription: String? { description }
}

/// Settings shared by both modes (wipe / registered faces).
public struct RenderSettings: Sendable {
    /// Expand each face box by this fraction of its size on every side.
    public var pad: Double = 0.45
    /// Mosaic block size in pixels. nil = auto (longest side / 60).
    public var block: Double?
    /// Extra NxN tiled detection passes for small faces (1 = full frame only).
    public var tiles: Int = 3
    /// Seconds before/after a detection during which the mosaic is held.
    public var hold: Double = 0.3
    /// People mode: run the tile passes only every this many seconds (0 = every frame).
    public var tileInterval: Double = 0.1
    /// How boxes without a sticker are hidden (faces and on-screen text).
    public var style: CoverStyle = .mosaic
    /// People mode: person id → image drawn over that person's face instead of the mosaic.
    public var stickers: [Int: Sticker] = [:]
    /// Sticker size: the face box (or the sticker's own face) times this.
    public var stickerScale: Double = 1.2
    public init() {}

    func blockSize(for size: CGSize) -> CGFloat { block.map { CGFloat($0) } ?? autoBlock(size) }
}

/// Wipe mode: mosaic every face except the largest one inside a wipe.
public struct MosaicSettings: Sendable {
    /// Wipe regions in upright video pixels, top-left origin (as seen in players).
    public var wipes: [CGRect]
    public var minInside: Double = 0.8
    public var keepAllInWipe = false
    public var render = RenderSettings()
    public init(wipes: [CGRect]) { self.wipes = wipes }

    func ciWipes(videoHeight: CGFloat) -> [CGRect] { wipes.map { toCIRect($0, videoHeight: videoHeight) } }
}

public struct VideoInfo: @unchecked Sendable {
    public let track: AVAssetTrack
    /// Size of the decoded (stored) frames.
    public let naturalSize: CGSize
    /// Size as displayed (after the track's rotation). All face coordinates use this.
    public let size: CGSize
    public let orientation: CGImagePropertyOrientation
    public let transform: CGAffineTransform
    public let duration: Double
    public let fps: Double
}

/// Map a track's preferredTransform to the orientation that makes stored frames upright.
func orientation(for t: CGAffineTransform) throws -> CGImagePropertyOrientation {
    func eq(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-6 }
    if eq(t.a, 1) && eq(t.b, 0) && eq(t.c, 0) && eq(t.d, 1) { return .up }
    if eq(t.a, 0) && eq(t.b, 1) && eq(t.c, -1) && eq(t.d, 0) { return .right }  // 90° clockwise
    if eq(t.a, 0) && eq(t.b, -1) && eq(t.c, 1) && eq(t.d, 0) { return .left }  // 90° counter-clockwise
    if eq(t.a, -1) && eq(t.b, 0) && eq(t.c, 0) && eq(t.d, -1) { return .down }
    throw ToolError("unsupported video transform (mirrored or non-90° rotation): \(t)")
}

func inverse(_ o: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
    switch o {
    case .right: .left
    case .left: .right
    default: o
    }
}

public func loadVideo(_ asset: AVURLAsset) async throws -> VideoInfo {
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw ToolError("no video track in \(asset.url.lastPathComponent)")
    }
    let (natural, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
    let o = try orientation(for: transform)
    let size = (o == .left || o == .right) ? CGSize(width: natural.height, height: natural.width) : natural
    let duration = try await asset.load(.duration).seconds
    return VideoInfo(
        track: track, naturalSize: natural, size: size, orientation: o, transform: transform,
        duration: duration, fps: Double(fps))
}

public func validateWipes(_ wipes: [CGRect], size: CGSize) throws {
    guard !wipes.isEmpty else { throw ToolError("at least one wipe region is required") }
    for (i, w) in wipes.enumerated() where !CGRect(origin: .zero, size: size).contains(w) {
        throw ToolError("wipe #\(i + 1) \(w) is outside the video (\(Int(size.width))x\(Int(size.height)))")
    }
}

/// Upright Core Image frame from a decoded pixel buffer.
func uprightImage(_ pb: CVPixelBuffer, _ info: VideoInfo) -> CIImage {
    let raw = CIImage(cvPixelBuffer: pb)
    return info.orientation == .up ? raw : raw.oriented(info.orientation)
}

/// Decode every video frame once and hand the upright image to `body`.
/// Throws CancellationError when the surrounding task is cancelled.
func forEachFrame(
    asset: AVURLAsset, info: VideoInfo, _ body: (_ index: Int, _ time: Double, _ image: CIImage) throws -> Void
) throws {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: info.track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw ToolError("cannot read video track") }
    reader.add(output)
    guard reader.startReading() else {
        throw ToolError("cannot start reading: \(reader.error.map { "\($0)" } ?? "unknown error")")
    }
    defer { if reader.status == .reading { reader.cancelReading() } }

    var index = 0
    while let sample = output.copyNextSampleBuffer() {
        if Task.isCancelled { throw CancellationError() }
        try autoreleasepool {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { return }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            try body(index, t, uprightImage(pb, info))
            index += 1
        }
    }
    guard reader.status == .completed else {
        throw ToolError("reading stopped: \(reader.error.map { "\($0)" } ?? "status \(reader.status.rawValue)")")
    }
    guard index > 0 else { throw ToolError("no frames decoded") }
}

/// Decode every frame and detect faces. The full frame (and extra regions) are searched on
/// every frame; the tile passes for small faces, which cost ~9 of the ~10 Vision requests,
/// only every `tileInterval` seconds (0 = every frame). Callers must bridge the frames in
/// between (track interpolation or hold). Several frames are detected concurrently so CPU
/// work (cropping) overlaps the Vision requests. `body` is called once per frame, in order.
/// `batch` 4–6 was fastest; 8 was ~15% slower with identical results (1080p60, 2 min, M3 Max,
/// 2026-11-14: 2 → 102s, 3 → 93s, 4–6 → 89–90s, 8 → 105s, 16 → 100s).
func forEachFrameDetecting(
    asset: AVURLAsset, info: VideoInfo, tiles: Int, tileInterval: Double = 0, extraRegions: [CGRect],
    batch: Int = 4,
    _ body: (_ index: Int, _ time: Double, _ image: CIImage, _ faces: [CGRect]) throws -> Void
) throws {
    let tileEvery = max(1, Int((tileInterval * max(info.fps, 1)).rounded()))
    var pending: [(index: Int, time: Double, image: CIImage)] = []
    func flush() throws {
        guard !pending.isEmpty else { return }
        let items = pending
        let results = ResultBox<[CGRect]>(count: items.count)
        DispatchQueue.concurrentPerform(iterations: items.count) { k in
            let t = items[k].index % tileEvery == 0 ? tiles : 1
            results.set(k, Result { try detectFaces(image: items[k].image, tiles: t, extraRegions: extraRegions) })
        }
        let faces = try results.values()
        pending.removeAll(keepingCapacity: true)
        for (k, f) in items.enumerated() { try body(f.index, f.time, f.image, faces[k]) }
    }
    try forEachFrame(asset: asset, info: info) { i, t, img in
        pending.append((i, t, img))
        if pending.count >= batch { try flush() }
    }
    try flush()
}

/// Detection results indexed by presentation time for lookup during rendering.
struct FaceIndex: Sendable {
    let frames: [FrameFaces]  // sorted by time

    private func firstIndex(atOrAfter t: Double) -> Int {
        var lo = 0, hi = frames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].time < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Mosaic rects for the frame shown at `t`, plus every detection within ±hold.
    /// The displayed source frame (latest at or before t) is always included.
    func mosaicRects(at t: Double, hold: Double) -> [CGRect] {
        guard !frames.isEmpty else { return [] }
        let eps = 1e-3
        var rects: [CGRect] = []
        let after = firstIndex(atOrAfter: t + eps)
        let displayed = max(0, after - 1)
        rects += frames[displayed].mosaic
        var i = firstIndex(atOrAfter: t - hold - eps)
        while i < frames.count, frames[i].time <= t + hold + eps {
            if i != displayed { rects += frames[i].mosaic }
            i += 1
        }
        return rects
    }

    /// Boxes for the frame shown at `t` that are drawn without the face margin, and the
    /// corners their mosaic blocks line up with.
    func exactRects(at t: Double) -> (rects: [CGRect], anchors: [CGPoint]) {
        guard !frames.isEmpty else { return ([], []) }
        let f = frames[max(0, firstIndex(atOrAfter: t + 1e-3) - 1)]
        return (f.exact, f.exactAnchors)
    }

    /// Faces to mosaic at `t` (± hold, with the margin).
    func faceRects(at t: Double, hold: Double, pad: Double) -> [CGRect] {
        mosaicRects(at: t, hold: hold).map { padded($0, pad) }
    }

    /// Faces covered by a sticker in the frame shown at `t` (held per person already, so no
    /// ±hold here: drawing a picture at several past positions would show several faces).
    func stickerBoxes(at t: Double) -> [StickerBox] {
        guard !frames.isEmpty else { return [] }
        return frames[max(0, firstIndex(atOrAfter: t + 1e-3) - 1)].stickers
    }
}

/// Wipe mode pass 1: decode every frame and classify faces.
public func scanFaces(
    asset: AVURLAsset, info: VideoInfo, settings: MosaicSettings, progress: (Int) -> Void
) throws -> [FrameFaces] {
    let wipes = settings.ciWipes(videoHeight: info.size.height)
    var frames: [FrameFaces] = []
    try forEachFrameDetecting(asset: asset, info: info, tiles: settings.render.tiles, extraRegions: wipes) { i, t, _, faces in
        let c = classify(faces: faces, wipes: wipes, minInside: settings.minInside, keepAll: settings.keepAllInWipe)
        frames.append(FrameFaces(time: t, mosaic: c.mosaic, kept: c.kept))
        progress(i + 1)
    }
    return frames.sorted { $0.time < $1.time }
}

public func fileType(for url: URL) throws -> AVFileType {
    switch url.pathExtension.lowercased() {
    case "mov": return .mov
    case "mp4", "m4v": return .mp4
    default: throw ToolError("output extension must be .mov or .mp4")
    }
}

/// Exact frame at `at` (tolerance 0), already upright.
public func frameImage(asset: AVURLAsset, at: Double, tolerance: Double = 0) async throws -> (CGImage, Double) {
    let gen = AVAssetImageGenerator(asset: asset)
    let tol = CMTime(seconds: tolerance, preferredTimescale: 600)
    gen.requestedTimeToleranceBefore = tol
    gen.requestedTimeToleranceAfter = tol
    gen.appliesPreferredTrackTransform = true
    let (cg, actual) = try await gen.image(at: CMTime(seconds: at, preferredTimescale: 600))
    return (cg, actual.seconds)
}

/// A labelled box for previews.
public struct PreviewBox: Sendable {
    public enum Kind: Sendable { case wipe, kept, mosaic }
    public let rect: CGRect  // Core Image coordinates
    public let kind: Kind
    public init(rect: CGRect, kind: Kind) {
        self.rect = rect
        self.kind = kind
    }
}

public struct PreviewResult: @unchecked Sendable {
    public let image: CGImage
    public let mosaicCount: Int
    public let keptCount: Int
    public let time: Double
}

/// Draw boxes over an image that already has the mosaic applied.
func annotate(_ img: CIImage, boxes: [PreviewBox], pad: Double) throws -> CGImage {
    let ctx = CIContext()
    guard let base = ctx.createCGImage(img, from: img.extent),
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let g = CGContext(
            data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ToolError("cannot render preview") }
    g.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
    let lw = max(3, img.extent.height / 270)
    g.setLineWidth(lw)
    for b in boxes {
        switch b.kind {
        case .wipe:
            g.setStrokeColor(CGColor(red: 0, green: 0.85, blue: 0.3, alpha: 1))
            g.setLineDash(phase: 0, lengths: [lw * 4, lw * 2])
            g.stroke(b.rect)
        case .kept:
            g.setStrokeColor(CGColor(red: 0, green: 0.85, blue: 0.3, alpha: 1))
            g.setLineDash(phase: 0, lengths: [])
            g.stroke(b.rect)
        case .mosaic:
            g.setStrokeColor(CGColor(red: 1, green: 0.15, blue: 0.15, alpha: 1))
            g.setLineDash(phase: 0, lengths: [])
            g.stroke(padded(b.rect, pad))
        }
    }
    guard let out = g.makeImage() else { throw ToolError("cannot render preview") }
    return out
}

/// Wipe mode single-frame preview (no --hold smoothing).
public func renderPreview(asset: AVURLAsset, info: VideoInfo, at: Double, settings: MosaicSettings) async throws
    -> PreviewResult
{
    let (cg, actual) = try await frameImage(asset: asset, at: at)
    let img = CIImage(cgImage: cg)
    let wipes = settings.ciWipes(videoHeight: img.extent.height)
    let faces = try detectFaces(image: img, tiles: settings.render.tiles, extraRegions: wipes)
    let c = classify(faces: faces, wipes: wipes, minInside: settings.minInside, keepAll: settings.keepAllInWipe)
    let mosaicked = applyCover(
        img, rects: c.mosaic.map { padded($0, settings.render.pad) }, stickers: [], render: settings.render,
        block: settings.render.blockSize(for: info.size))
    let boxes =
        wipes.map { PreviewBox(rect: $0, kind: .wipe) } + c.kept.map { PreviewBox(rect: $0, kind: .kept) }
        + c.mosaic.map { PreviewBox(rect: $0, kind: .mosaic) }
    return PreviewResult(
        image: try annotate(mosaicked, boxes: boxes, pad: settings.render.pad),
        mosaicCount: c.mosaic.count, keptCount: c.kept.count, time: actual)
}

public func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw ToolError("cannot write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw ToolError("cannot write \(url.path)") }
}

/// A stretch where fewer faces were mosaicked than on both sides: a likely missed detection.
public struct Dip: Sendable, Identifiable {
    public var id: Double { start }
    public let start: Double
    public let end: Double
    public let count: Int
    public let around: Int
}

/// Flag frames whose mosaic count is lower than the max within `window` seconds on BOTH
/// sides. Faces leaving or entering the screen are not flagged (only one side is higher).
/// Continuous misses cannot be found this way; the output still needs a human review.
public func findDips(_ frames: [FrameFaces], window: Double = 1.0) -> [Dip] {
    let n = frames.count
    guard n > 2 else { return [] }
    var flagged: [(Int, Int)] = []  // (index, around)
    var lo = 0, hi = 0
    for i in 0..<n {
        let t = frames[i].time
        while frames[lo].time < t - window { lo += 1 }
        while hi + 1 < n && frames[hi + 1].time <= t + window { hi += 1 }
        let left = frames[lo..<i].map(\.faceCount).max() ?? 0
        let right = i + 1 <= hi ? (frames[(i + 1)...hi].map(\.faceCount).max() ?? 0) : 0
        let around = min(left, right)
        if frames[i].faceCount < around { flagged.append((i, around)) }
    }
    var dips: [Dip] = []
    var k = 0
    while k < flagged.count {
        var j = k
        while j + 1 < flagged.count && flagged[j + 1].0 == flagged[j].0 + 1 { j += 1 }
        let idx = flagged[k].0...flagged[j].0
        dips.append(
            Dip(
                start: frames[idx.lowerBound].time, end: frames[idx.upperBound].time,
                count: idx.map { frames[$0].faceCount }.min() ?? 0,
                around: flagged[k...j].map(\.1).max() ?? 0))
        k = j + 1
    }
    return dips
}
