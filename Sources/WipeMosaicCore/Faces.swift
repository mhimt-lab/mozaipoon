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
    /// QR codes to mosaic along their four corners (margin included; see `TextMask.codes`).
    public let codes: [[CGPoint]]
    /// Slanted lines of on-screen text to mosaic along their corners (see `TextMask.slanted`).
    public let slanted: [[CGPoint]]
    /// Faces covered by a person's sticker instead of the mosaic (not in `mosaic`).
    public let stickers: [StickerBox]
    public init(
        time: Double, mosaic: [CGRect], kept: [CGRect], exact: [CGRect] = [], exactAnchors: [CGPoint] = [],
        codes: [[CGPoint]] = [], slanted: [[CGPoint]] = [], stickers: [StickerBox] = []
    ) {
        self.time = time
        self.mosaic = mosaic
        self.kept = kept
        self.exact = exact
        self.exactAnchors = exactAnchors
        self.codes = codes
        self.slanted = slanted
        self.stickers = stickers
    }

    /// Faces hidden in this frame, by mosaic or sticker.
    public var faceCount: Int { mosaic.count + stickers.count }
    /// Something is hidden in this frame.
    public var hidesAnything: Bool { !mosaic.isEmpty || hidesText || !stickers.isEmpty }
    /// On-screen text or a QR code is hidden in this frame.
    public var hidesText: Bool { !exact.isEmpty || !codes.isEmpty || !slanted.isEmpty }
}

private func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

/// One detected face: its box (image coordinates) and the head pose Vision reports (radians;
/// nil when not reported). `angle` is filled in by `faceAngles` on some frames.
public struct FaceBox: Sendable {
    public var rect: CGRect
    var roll: Double?
    var yaw: Double?
    /// Tilt of the face, counter-clockwise in Core Image coordinates (radians); nil when not measured.
    public var angle: CGFloat?
}

/// Detect faces in one region; returns boxes in the image's coordinates.
private func detect(in image: CIImage, region: CGRect) throws -> [FaceBox] {
    let crop = image.cropped(to: region)
        .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
    let req = VNDetectFaceRectanglesRequest()
    try VNImageRequestHandler(ciImage: crop, orientation: .up, options: [:]).perform([req])
    return (req.results ?? []).map {
        FaceBox(
            rect: VNImageRectForNormalizedRect($0.boundingBox, Int(region.width), Int(region.height))
                .offsetBy(dx: region.minX, dy: region.minY),
            roll: $0.roll?.doubleValue, yaw: $0.yaw?.doubleValue)
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

/// Merge boxes that describe the same face (from full frame and tiles) into their union
/// (the pose of the largest box is kept).
private func mergeDuplicates(_ faces: [FaceBox]) -> [FaceBox] {
    var merged: [FaceBox] = []
    for f in faces.sorted(by: { area($0.rect) > area($1.rect) }) {
        let r = f.rect
        if let i = merged.firstIndex(where: {
            let inter = area($0.rect.intersection(r))
            return inter > 0 && inter / min(area($0.rect), area(r)) >= 0.5
        }) {
            merged[i].rect = merged[i].rect.union(r)
        } else {
            merged.append(f)
        }
    }
    return merged
}

/// Full frame + grid tiles + each extra region (the wipes, slightly enlarged), merged.
/// Wipes get their own pass because a second person inside the wipe is the case where
/// a miss would leave someone other than the presenter unmasked.
public func detectFaces(image: CIImage, tiles: Int, extraRegions: [CGRect]) throws -> [CGRect] {
    try detectFaceBoxes(image: image, tiles: tiles, extraRegions: extraRegions).map(\.rect)
}

/// `detectFaces` with the head pose of each face.
func detectFaceBoxes(image: CIImage, tiles: Int, extraRegions: [CGRect]) throws -> [FaceBox] {
    let ext = image.extent
    var regions = [ext] + tileRects(ext, tiles: tiles)
    for r in extraRegions {
        let e = r.insetBy(dx: -r.width * 0.1, dy: -r.height * 0.1).integral.intersection(ext)
        if !e.isNull && !e.isEmpty { regions.append(e) }
    }
    // Each Vision request mostly waits on the Neural Engine/GPU, so run the regions concurrently.
    let results = ResultBox<[FaceBox]>(count: regions.count)
    DispatchQueue.concurrentPerform(iterations: regions.count) { i in
        results.set(i, Result { try detect(in: image, region: regions[i]) })
    }
    return mergeDuplicates(try results.values().flatMap { $0 })
}

/// The tilt of each face (see `FaceBox.angle`; nil when it cannot be measured).
/// Vision's roll comes with every face but measured only about half of a tilt to one side
/// (a frame turned +20°: roll +5…+13°; −20°: −16…−20°), while the line through the eyes
/// followed both sides within ~2° (街角の3人, 2026-11-16). The eye line goes wrong on a face
/// turned to the side (one eye hidden, perspective: −17° where roll said −3°, at yaw 27°),
/// so it is used on faces turned less than 15°, roll beyond 30°, and a mix in between so the
/// value does not jump as the head turns. Faces under 40 px get roll only (landmarks unreliable).
func faceAngles(in image: CIImage, faces: [FaceBox]) -> [CGFloat?] {
    let ext = image.extent
    let degree = Double.pi / 180
    var eyes = [Double?](repeating: nil, count: faces.count)
    let candidates = faces.indices.filter { faces[$0].rect.width >= 40 && abs(faces[$0].yaw ?? 0) < 30 * degree }
    if !candidates.isEmpty {
        let inputs = candidates.map { i -> VNFaceObservation in
            let r = faces[i].rect
            let norm = CGRect(
                x: (r.minX - ext.minX) / ext.width, y: (r.minY - ext.minY) / ext.height,
                width: r.width / ext.width, height: r.height / ext.height)
            return VNFaceObservation(
                requestRevision: VNDetectFaceRectanglesRequestRevision3, boundingBox: norm,
                roll: faces[i].roll.map { NSNumber(value: $0) }, yaw: faces[i].yaw.map { NSNumber(value: $0) })
        }
        let req = VNDetectFaceLandmarksRequest()
        req.inputFaceObservations = inputs
        if (try? VNImageRequestHandler(ciImage: image, orientation: .up, options: [:]).perform([req])) != nil {
            for o in req.results ?? [] {
                // The result for each input face: the one whose box is nearest.
                guard let k = inputs.indices.min(by: {
                    hypot(inputs[$0].boundingBox.midX - o.boundingBox.midX, inputs[$0].boundingBox.midY - o.boundingBox.midY)
                        < hypot(inputs[$1].boundingBox.midX - o.boundingBox.midX, inputs[$1].boundingBox.midY - o.boundingBox.midY)
                }) else { continue }
                let size = CGSize(width: ext.width, height: ext.height)
                func centre(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
                    guard let p = region?.pointsInImage(imageSize: size), !p.isEmpty else { return nil }
                    return CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
                }
                guard let a = centre(o.landmarks?.leftEye), let b = centre(o.landmarks?.rightEye) else { continue }
                var angle = atan2(Double(b.y - a.y), Double(b.x - a.x))
                // The line through the eyes, whichever way round the eyes are listed.
                if angle > .pi / 2 { angle -= .pi } else if angle < -.pi / 2 { angle += .pi }
                eyes[candidates[k]] = angle
            }
        }
    }
    return faces.indices.map { i in
        let f = faces[i]
        guard let roll = f.roll else { return eyes[i].map { CGFloat($0) } }
        guard let eye = eyes[i], abs(eye - roll) <= 25 * degree else { return CGFloat(roll) }
        let w = min(1, max(0, (30 * degree - abs(f.yaw ?? 0)) / (15 * degree)))
        return CGFloat(w * eye + (1 - w) * roll)
    }
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
