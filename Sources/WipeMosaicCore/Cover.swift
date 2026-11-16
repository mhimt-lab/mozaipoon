import CoreImage
import Foundation
import ImageIO
import Vision

/// How the boxes that are not covered by a sticker are hidden.
public enum CoverStyle: String, Sendable, CaseIterable {
    case mosaic, blur
}

/// A face of one person, covered by that person's sticker image instead of a mosaic.
public struct StickerBox: Sendable {
    public let rect: CGRect  // Core Image coordinates, the face box (no margin)
    public let person: Int
    /// The face was not detected in this frame: the box is followed by tracking, bridged
    /// between two appearances or held at the last known position. The face may be beside
    /// the box, so the mosaic (or blur) is drawn under the sticker with the usual margin.
    public let estimated: Bool
    /// Tilt of the face, counter-clockwise in Core Image coordinates (radians): the sticker is
    /// turned by it around the middle of the box.
    public let angle: CGFloat
    // No defaults: a box rebuilt without `estimated` would lose the mosaic under it, and one
    // without `angle` would stand upright on a tilted face.
    public init(rect: CGRect, person: Int, estimated: Bool, angle: CGFloat) {
        self.rect = rect
        self.person = person
        self.estimated = estimated
        self.angle = angle
    }

    /// The same box moved (e.g. into a source image whose extent does not start at 0).
    public func offsetBy(dx: CGFloat, dy: CGFloat) -> StickerBox {
        StickerBox(rect: rect.offsetBy(dx: dx, dy: dy), person: person, estimated: estimated, angle: angle)
    }
}

/// An image (e.g. a cut-out face photo) drawn over a face.
///
/// When the image has a face of its own, that face is laid over the face in the video, so a
/// face photo replaces the face at its size (a larger photo is cut down to the area around
/// its face first). Otherwise the opaque part of the image (its transparent margin ignored)
/// is laid over the face box. Either way the image is scaled uniformly so its anchor covers
/// the face box times `scale` completely.
public final class Sticker: @unchecked Sendable {
    public let cgImage: CGImage
    public let image: CIImage
    /// Part of `image` laid over the face (image coordinates, bottom-left origin).
    public let anchor: CGRect
    /// The image has a face, and `anchor` is that face.
    public let anchoredOnFace: Bool
    /// Alpha (0…255) at reduced size, row 0 at the bottom, for the coverage check.
    private let alpha: [UInt8]
    private let alphaSize: (w: Int, h: Int)
    /// `image` at 1/2, 1/4… so drawing a small sticker resamples from a near size.
    private let levels: [(scale: CGFloat, image: CIImage)]

    /// Alpha counted as hiding what is under it (a half-transparent image shows the face).
    static let opaqueAlpha: UInt8 = 242
    /// Share of the face ellipse that must be covered, besides the whole core.
    public static let minCoverage = 0.98

    public convenience init(cgImage: CGImage) throws {
        try self.init(cgImage: cgImage, cropToFace: true)
    }

    private init(cgImage source: CGImage, cropToFace: Bool) throws {
        guard source.width >= 8, source.height >= 8 else { throw ToolError("画像が小さすぎます（8×8ピクセル以上にしてください）") }

        // A face in the image (detected over grey, so a transparent background is not black).
        let srcImage = CIImage(cgImage: source)
        let ext0 = srcImage.extent
        let flat = srcImage.composited(over: CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: ext0))
        let faces = (try? detectFaces(image: flat, tiles: 1, extraRegions: [])) ?? []
        let largest = faces.max { a, b in a.width * a.height < b.width * b.height }
        var face = largest.flatMap { $0.width * $0.height >= ext0.width * ext0.height * 0.02 ? $0 : nil }

        // A photo larger than the head (upper body, a group…) would be drawn several times
        // the face in the video: keep 2.5× the face around it.
        var cg = source
        if cropToFace, let f = face {
            let keep = scaled(f, 2.5).integral.intersection(ext0)
            if keep.width < ext0.width - 1 || keep.height < ext0.height - 1 {
                // CGImage cropping is top-left based.
                let top = CGRect(x: keep.minX, y: ext0.height - keep.maxY, width: keep.width, height: keep.height)
                if let c = source.cropping(to: top) {
                    cg = c
                    face = f.offsetBy(dx: -keep.minX, dy: -keep.minY)
                }
            }
        }
        cgImage = cg
        image = CIImage(cgImage: cg)
        let w = cg.width, h = cg.height

        // Alpha mask at most 256 px on the long side (row 0 = top in the bitmap).
        let s = min(1, 256 / Double(max(w, h)))
        let aw = max(1, Int((Double(w) * s).rounded())), ah = max(1, Int((Double(h) * s).rounded()))
        var buf = [UInt8](repeating: 0, count: aw * ah)
        let drawn: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: aw, height: ah, bitsPerComponent: 8, bytesPerRow: aw,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: aw, height: ah))
            return true
        }
        guard drawn else { throw ToolError("画像を読み込めません") }
        var flipped = [UInt8](repeating: 0, count: aw * ah)  // row 0 = bottom, like Core Image
        for y in 0..<ah { for x in 0..<aw { flipped[y * aw + x] = buf[(ah - 1 - y) * aw + x] } }
        alpha = flipped
        alphaSize = (aw, ah)

        var minX = aw, minY = ah, maxX = -1, maxY = -1
        for y in 0..<ah { for x in 0..<aw where flipped[y * aw + x] >= 128 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX, maxY >= minY else { throw ToolError("画像がすべて透明です") }
        let fx = Double(w) / Double(aw), fy = Double(h) / Double(ah)
        let opaque = CGRect(
            x: Double(minX) * fx, y: Double(minY) * fy,
            width: Double(maxX - minX + 1) * fx, height: Double(maxY - minY + 1) * fy)
        if let face {
            anchor = face
            anchoredOnFace = true
        } else {
            anchor = opaque
            anchoredOnFace = false
        }

        var lv: [(CGFloat, CIImage)] = [(1, image)]
        var side = max(w, h), k: CGFloat = 1
        while side / 2 >= 32 {
            side /= 2
            k /= 2
            let lw = max(1, Int((CGFloat(w) * k).rounded())), lh = max(1, Int((CGFloat(h) * k).rounded()))
            guard let ctx = CGContext(
                data: nil, width: lw, height: lh, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { break }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: lw, height: lh))
            guard let small = ctx.makeImage() else { break }
            lv.append((k, CIImage(cgImage: small)))
        }
        levels = lv
    }

    public convenience init(contentsOf url: URL) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
            ] as CFDictionary)
        else { throw ToolError("画像を読み込めません: \(url.lastPathComponent)") }
        try self.init(cgImage: cg)
    }

    /// Where the whole image is drawn to cover `face` (video coordinates).
    func placement(over face: CGRect, scale: Double) -> (scale: CGFloat, origin: CGPoint) {
        let target = scaled(face, CGFloat(scale))
        let f = max(target.width / anchor.width, target.height / anchor.height)
        let origin = CGPoint(x: target.midX - anchor.midX * f, y: target.midY - anchor.midY * f)
        return (f, origin)
    }

    /// Fraction of sample points inside an ellipse of `radius` (1 = the ellipse inside a
    /// square face box) covered by (nearly) opaque pixels when drawn at `scale`.
    private func covered(scale: Double, radius: Double) -> Double {
        let face = CGRect(x: 0, y: 0, width: 100, height: 100)
        let (f, origin) = placement(over: face, scale: scale)
        let ext = image.extent
        let n = 128  // finer than the alpha map of a sticker scaled to the face, so a thin slit is sampled
        var inside = 0, hit = 0
        for j in 0..<n {
            for i in 0..<n {
                let px = (Double(i) + 0.5) / Double(n), py = (Double(j) + 0.5) / Double(n)
                let dx = px - 0.5, dy = py - 0.5
                guard dx * dx + dy * dy <= 0.25 * radius * radius else { continue }
                inside += 1
                let ix = (face.minX + px * face.width - origin.x) / f
                let iy = (face.minY + py * face.height - origin.y) / f
                guard ix >= 0, iy >= 0, ix < ext.width, iy < ext.height else { continue }
                let ax = min(alphaSize.w - 1, Int(ix / ext.width * Double(alphaSize.w)))
                let ay = min(alphaSize.h - 1, Int(iy / ext.height * Double(alphaSize.h)))
                if alpha[ay * alphaSize.w + ax] >= Self.opaqueAlpha { hit += 1 }
            }
        }
        return inside == 0 ? 0 : Double(hit) / Double(inside)
    }

    /// Share of the face (the ellipse inside a square face box) covered by nearly opaque
    /// pixels. Hair, ears and the jaw outline are outside this ellipse and may show.
    public func coverage(scale: Double) -> Double { covered(scale: scale, radius: 1) }

    /// The middle of the face (eyes, nose, mouth) is covered completely: a thin transparent
    /// slit across the eyes is a small share of the area but shows who it is.
    public func coversCore(scale: Double) -> Bool { covered(scale: scale, radius: 0.6) >= 1 }

    /// Part of the face shows through or around the image at `scale`.
    public func showsFace(scale: Double) -> Bool {
        // Remembered per scale: checked for every frame drawn.
        if let known = showsLock.withLock({ shows[scale] }) { return known }
        let v = coverage(scale: scale) < Self.minCoverage || !coversCore(scale: scale)
        showsLock.withLock { shows[scale] = v }
        return v
    }
    private var shows: [Double: Bool] = [:]
    private let showsLock = NSLock()

    /// The image placed over `face` and turned by `angle` (radians, counter-clockwise) around
    /// the middle of the face, ready to composite over the frame.
    func drawn(over face: CGRect, scale: Double, angle: CGFloat = 0) -> CIImage {
        let (f, origin) = placement(over: face, scale: scale)
        // Resample from the smallest prepared size that is still at least as large.
        let level = levels.last { $0.scale >= f } ?? levels[0]
        let k = f / level.scale
        let resized = k < 1
            ? level.image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
            : level.image.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let e = resized.extent
        let placed = resized.transformed(by: CGAffineTransform(translationX: origin.x - e.minX, y: origin.y - e.minY))
        // Under a tenth of a degree the turn would only soften the picture.
        guard abs(angle) >= .pi / 1800 else { return placed }
        // Core Image samples the turned image bilinearly, so its edges stay smooth (checked on
        // an opaque square turned 24°: no staircase, 2026-11-16).
        let turn = CGAffineTransform(translationX: face.midX, y: face.midY)
            .rotated(by: angle)
            .translatedBy(x: -face.midX, y: -face.midY)
        return placed.transformed(by: turn)
    }
}

/// Everything that hides one frame: boxes hidden with `render.style`, then stickers on top.
/// `rects` are faces (margin included), `text` the on-screen text boxes (see `applyMosaic`),
/// `codes` QR codes and `slanted` slanted lines of text, cut along their corners (blocks lined
/// up with `slantedAnchors`).
public func applyCover(
    _ img: CIImage, rects: [CGRect], text: [CGRect] = [], textAnchors: [CGPoint] = [], codes: [[CGPoint]] = [],
    slanted: [[CGPoint]] = [], slantedAnchors: [CGPoint] = [], stickers: [StickerBox], render: RenderSettings, block: CGFloat
) -> CIImage {
    // The mosaic (or blur) with the usual margin goes under a sticker whose face was not
    // detected in this frame, under one that lets part of the face show (a hole, a
    // half-transparent part, too small), and for a face whose sticker is missing: never a
    // bare face. Only an image that covers the face hides it alone.
    let under = stickers.filter { s in
        guard let sticker = render.stickers[s.person] else { return true }
        return s.estimated || sticker.showsFace(scale: render.stickerScale)
    }.map { padded($0.rect, render.pad) }
    let all = rects + under
    var out = render.style == .blur
        ? applyBlur(img, rects: all, moving: text, anchors: textAnchors, codes: codes, slanted: slanted, slantedAnchors: slantedAnchors, block: block)
        : codeBlocks(
            img, over: slantedBlocks(
                img, over: applyMosaic(img, rects: all, moving: text, anchors: textAnchors, block: block),
                quads: slanted, anchors: slantedAnchors, block: block),
            codes: codes, block: block)
    for s in stickers {
        guard let sticker = render.stickers[s.person] else { continue }
        out = sticker.drawn(over: s.rect, scale: render.stickerScale, angle: s.angle).composited(over: out).cropped(to: img.extent)
    }
    return out
}

/// Blur that keeps no more detail than the mosaic of the same block size: the region is
/// pixellated first (detail removed for good) and the blocks are then blurred smooth, so a
/// sharpening filter cannot bring back what a plain blur would only have spread out.
/// Inside each box the blur is complete; it fades out over a short distance outside, so the
/// edge does not look like a pasted grey square.
public func applyBlur(
    _ img: CIImage, rects: [CGRect], moving: [CGRect] = [], anchors: [CGPoint] = [], codes: [[CGPoint]] = [],
    slanted: [[CGPoint]] = [], slantedAnchors: [CGPoint] = [], block: CGFloat
) -> CIImage {
    let ext = img.extent
    let boxes = (rects + moving).map { $0.intersection(ext) }.filter { !$0.isNull && !$0.isEmpty }
    let lines = slanted.filter { !$0.isEmpty && boundingBox($0).intersects(ext) }  // for the masks
    let codeQuads = codes.filter { !$0.isEmpty && boundingBox($0).intersects(ext) }
    let quads = codeQuads + lines
    guard !boxes.isEmpty || !quads.isEmpty else { return img }
    // Blocks as in `applyMosaic` (text blocks move with the text): over the whole image when
    // there are faces, else over the picture as it is (outside the boxes it only shows in the
    // short fade).
    let blocks = codeBlocks(
        img, over: slantedBlocks(
            img, over: movingBlocks(img, over: rects.isEmpty ? img : pixellated(img, block: block), moving: moving, anchors: anchors, block: block),
            quads: slanted, anchors: slantedAnchors, block: block),
        codes: codeQuads, block: block)
    let blurred = blocks.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: block])
        .cropped(to: ext)
    let fade = max(2, block / 3)
    var hard = CIImage.empty(), wide = CIImage.empty()
    for b in boxes {
        hard = CIImage(color: .white).cropped(to: b).composited(over: hard)
        wide = CIImage(color: .white).cropped(to: b.insetBy(dx: -2 * fade, dy: -2 * fade)).composited(over: wide)
    }
    for q in quads {
        hard = filledQuad(q).composited(over: hard)
        wide = filledQuad(isDrawableQuad(q) ? outset(q, by: 2 * fade) : q).composited(over: wide)
    }
    // The soft mask is blurred from the boxes widened by 2× the fade, so it is still ~0.98 at
    // a box's edge and falls smoothly from there. Blurred from the boxes themselves it was
    // 0.5 at the edge: the step from the full blur inside to half outside showed as a
    // straight-cut rectangle.
    let soft = wide.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: fade])
    // Fully blurred inside the boxes (max with the hard mask), fading out only outside them.
    let mask = soft.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: hard]).cropped(to: ext)
    return blurred.applyingFilter(
        "CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: mask]
    ).cropped(to: ext)
}

/// At most this many mosaic blocks across a QR code, whatever the block size: blocks finer
/// than the code's modules leave it readable. A code over most of a screen recording, hidden
/// with 8 or 16 px blocks, was still decoded in every frame; with at most 6, 8 or 10 blocks a
/// side, also with 4 px blocks, in none (21- and 39-module codes of 300–1000 px, 2026-11-16).
let maxCodeBlocks: CGFloat = 6

/// Slanted lines of text in blocks of `block` px along the slant, drawn over `base`: the
/// picture is turned upright about each line's anchor (where the line starts, without the
/// margin), made into blocks lined up with the anchor, turned back and cut along the quad.
/// The blocks move and turn with the line, and the room around it (which changes as the line
/// moves) only changes where the quad is cut: blocks counted across the whole quad, with it
/// as their origin, shifted and stretched whenever the room changed, and the mosaic shimmered.
/// A quad that cannot be drawn so (or without its anchor) is hidden by its upright box.
func slantedBlocks(_ img: CIImage, over base: CIImage, quads: [[CGPoint]], anchors: [CGPoint], block: CGFloat) -> CIImage {
    let ext = img.extent
    var out = base
    for (i, q) in quads.enumerated() where !q.isEmpty && boundingBox(q).intersects(ext) {
        let box = boundingBox(q).intersection(ext)
        guard isDrawableQuad(q), anchors.count == quads.count else {
            out = pixellated(img, block: block, origin: box.origin).cropped(to: box).composited(over: out)
            continue
        }
        let a = anchors[i], angle = atan2(q[1].y - q[0].y, q[1].x - q[0].x)
        let upright = CGAffineTransform(translationX: a.x, y: a.y).rotated(by: -angle).translatedBy(x: -a.x, y: -a.y)
        let blocks = img.clampedToExtent().transformed(by: upright)
            // As `pixellated`: each block is the average of its pixels.
            .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: block + 1])
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: a.x, y: a.y)])
            .transformed(by: upright.inverted())
            .cropped(to: box.insetBy(dx: -2, dy: -2))
        out = blocks.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: filledQuad(q),
        ]).cropped(to: ext)
    }
    return out.cropped(to: ext)
}

/// The quad can be straightened and drawn: 4 finite corners making a convex quad of some size.
/// Anything else (corners in the wrong order, a code seen edge on) is hidden by its box.
func isDrawableQuad(_ q: [CGPoint]) -> Bool {
    guard q.count == 4, q.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), abs(signedArea(q)) >= 4 else { return false }
    let turns = q.indices.map { i -> CGFloat in
        let a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4]
        return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
    }
    return turns.allSatisfy { $0 > 0 } || turns.allSatisfy { $0 < 0 }
}

/// QR codes in blocks cut along each code, drawn over `base`: the code (with its margin) is
/// straightened to an upright rectangle, made into whole blocks of about `block` px (3 to
/// `maxCodeBlocks` a side), and put back where it lies. A slanted code filmed at an angle is
/// covered by a slanted quad with blocks that follow the code, instead of the upright box
/// around it, which also hid the text beside it; the blocks move with the code, so they do not
/// change while the camera moves. A quad that cannot be drawn so is hidden by its box.
func codeBlocks(_ img: CIImage, over base: CIImage, codes: [[CGPoint]], block: CGFloat) -> CIImage {
    let ext = img.extent
    var out = base
    for q in codes where !q.isEmpty && boundingBox(q).intersects(ext) {
        if let b = quadBlocks(img, q, block: block) {
            out = b.composited(over: out)
        } else {
            let box = boundingBox(q).intersection(ext)
            let b = max(block, max(box.width, box.height) / maxCodeBlocks)
            out = pixellated(img, block: b, origin: box.origin).cropped(to: box).composited(over: out)
        }
    }
    return out.cropped(to: ext)
}

private func quadBlocks(_ img: CIImage, _ q: [CGPoint], block: CGFloat) -> CIImage? {
    guard isDrawableQuad(q) else { return nil }
    func v(_ p: CGPoint) -> CIVector { CIVector(x: p.x, y: p.y) }
    let flat = img.clampedToExtent().applyingFilter("CIPerspectiveCorrection", parameters: [
        "inputTopLeft": v(q[0]), "inputTopRight": v(q[1]), "inputBottomRight": v(q[2]), "inputBottomLeft": v(q[3]),
    ])
    let fe = flat.extent
    guard fe.width >= 1, fe.height >= 1, fe.width.isFinite, fe.height.isFinite else { return nil }
    let nx = min(maxCodeBlocks, max(3, (fe.width / block).rounded()))
    let ny = min(maxCodeBlocks, max(3, (fe.height / block).rounded()))
    // Blocks of `block` px on the straightened code: its size changes, the block count does not.
    let grid = flat
        .transformed(by: CGAffineTransform(translationX: -fe.minX, y: -fe.minY))
        .transformed(by: CGAffineTransform(scaleX: nx * block / fe.width, y: ny * block / fe.height))
        .cropped(to: CGRect(x: 0, y: 0, width: nx * block, height: ny * block))
    return pixellated(grid, block: block, origin: .zero).applyingFilter("CIPerspectiveTransform", parameters: [
        "inputTopLeft": v(q[0]), "inputTopRight": v(q[1]), "inputBottomRight": v(q[2]), "inputBottomLeft": v(q[3]),
    ])
}

/// White inside the quad (its box when it cannot be drawn as a quad), clear outside: filled
/// with Core Graphics (edges smoothed) into a bitmap of the quad's box. A small white image
/// stretched onto the quad (`CIPerspectiveTransform`) left 1 px streaks along whole rows of
/// the picture beside long thin quads (slanted lines) when the frame was rendered in tiles.
func filledQuad(_ q: [CGPoint]) -> CIImage {
    let box = boundingBox(q).integral
    guard isDrawableQuad(q), box.width >= 1, box.height >= 1, box.width * box.height <= 64_000_000,
          let ctx = CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return CIImage(color: .white).cropped(to: boundingBox(q)) }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.move(to: CGPoint(x: q[0].x - box.minX, y: q[0].y - box.minY))
    for p in q.dropFirst() { ctx.addLine(to: CGPoint(x: p.x - box.minX, y: p.y - box.minY)) }
    ctx.closePath()
    ctx.fillPath()
    guard let gray = ctx.makeImage() else { return CIImage(color: .white).cropped(to: boundingBox(q)) }
    // White where filled, clear elsewhere.
    return CIImage(cgImage: gray).applyingFilter("CIMaskToAlpha").transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY))
}

/// Steady boxes for a sticker: a detected face box jitters a little every frame, which a
/// mosaic hides but a picture shows. Within each run of consecutive frames (a run also
/// ends at a jump — a cut to the same person elsewhere or much closer — so the average
/// never straddles two places and blows the box up to cover both):
/// 1. the centre is averaged over ±`centreFrames` and the size over ±`sizeFrames`
///    (centred, so steady motion is followed without lag);
/// 2. the margin each frame needs so its box still contains the frame's own face box is
///    found, then the largest need within ±2×`marginFrames` is averaged over ±`marginFrames`.
///    Every value in that average is at least the frame's own need, so the face stays
///    covered, while the margin changes smoothly instead of jumping frame by frame (growing
///    the box to each frame's face box directly brought the jitter back).
func steadyBoxes(_ boxes: [CGRect?], centreFrames: Int, sizeFrames: Int, marginFrames: Int) -> [CGRect?] {
    var out = [CGRect?](repeating: nil, count: boxes.count)
    func mean(_ v: [CGFloat], _ r: ClosedRange<Int>) -> CGFloat { r.map { v[$0] }.reduce(0, +) / CGFloat(r.count) }
    var i = 0
    while i < boxes.count {
        guard boxes[i] != nil else { i += 1; continue }
        var j = i
        while j + 1 < boxes.count, let next = boxes[j + 1], !isJump(boxes[j]!, next) { j += 1 }
        let run = (i...j).map { boxes[$0]! }
        let n = run.count
        func window(_ k: Int, _ r: Int) -> ClosedRange<Int> { max(0, k - r)...min(n - 1, k + r) }
        let cx = run.map(\.midX), cy = run.map(\.midY), w = run.map(\.width), h = run.map(\.height)
        let smooth = (0..<n).map { k -> CGRect in
            let c = window(k, centreFrames), s = window(k, sizeFrames)
            let mw = mean(w, s), mh = mean(h, s)
            return CGRect(x: mean(cx, c) - mw / 2, y: mean(cy, c) - mh / 2, width: mw, height: mh)
        }
        let need = (0..<n).map { k -> CGFloat in
            let s = smooth[k], r = run[k]
            return max(0, s.minX - r.minX, r.maxX - s.maxX, s.minY - r.minY, r.maxY - s.maxY)
        }
        let held = (0..<n).map { k in window(k, 2 * marginFrames).map { need[$0] }.max() ?? 0 }
        for k in 0..<n {
            let m = mean(held, window(k, marginFrames))
            out[i + k] = smooth[k].insetBy(dx: -m, dy: -m).union(run[k])  // union: rounding only
        }
        i = j + 1
    }
    return out
}

/// Steady tilt for a sticker, per frame of `boxes` (the steadied boxes of one person; nil:
/// not on screen, angle 0). The tilt measured ~10 times a second wobbles by ±2–3° between
/// measurements (街角の3人, 2026-11-16), which turns a picture visibly back and forth. Within each
/// run of `boxes` (as in `steadyBoxes`): frames without a measured tilt take the nearest one
/// in the run (upright when the run has none), a median over ±0.15 s drops single wrong
/// readings, then a centred mean over ±0.3 s smooths what is left without lagging behind a
/// head that tilts (measured on a picture turned ±24° every 4 s: within 3° of the head, the
/// frame-to-frame change itself changing by 0.068° rms). Limited to ±45°: Vision finds hardly any face tilted further.
func steadyAngles(_ boxes: [CGRect?], _ angles: [CGFloat?], fps: Double) -> [CGFloat] {
    var out = [CGFloat](repeating: 0, count: boxes.count)
    let medianFrames = max(1, Int((0.15 * fps).rounded())), meanFrames = max(1, Int((0.3 * fps).rounded()))
    var i = 0
    while i < boxes.count {
        guard boxes[i] != nil else { i += 1; continue }
        var j = i
        while j + 1 < boxes.count, let next = boxes[j + 1], !isJump(boxes[j]!, next) { j += 1 }
        let known = (i...j).filter { angles[$0] != nil }
        if !known.isEmpty {
            // Nearest measured frame for each frame of the run (known is sorted).
            var filled = [CGFloat](), k = 0
            for f in i...j {
                while k + 1 < known.count, abs(known[k + 1] - f) <= abs(known[k] - f) { k += 1 }
                filled.append(min(.pi / 4, max(-.pi / 4, angles[known[k]]!)))
            }
            let n = filled.count
            // Narrowed symmetrically near the ends of the run: a one-sided window there would
            // pull the tilt toward where the head goes next (−3° on an upright head, 2026-11-16).
            func window(_ m: Int, _ r: Int) -> ClosedRange<Int> { let h = min(r, m, n - 1 - m); return (m - h)...(m + h) }
            let median = (0..<n).map { m -> CGFloat in
                let v = window(m, medianFrames).map { filled[$0] }.sorted()
                return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
            }
            for m in 0..<n {
                let w = window(m, meanFrames)
                out[i + m] = w.map { median[$0] }.reduce(0, +) / CGFloat(w.count)
            }
        }
        i = j + 1
    }
    return out
}

/// The face moved too far or changed size too much in one frame to be the same shot
/// (the distance is the one used to link detections into tracks).
private func isJump(_ a: CGRect, _ b: CGRect) -> Bool {
    let sa = max(a.width, a.height), sb = max(b.width, b.height)
    let ratio = max(sa, sb) / max(1, min(sa, sb))
    return hypot(a.midX - b.midX, a.midY - b.midY) > 0.75 * max(sa, sb) || ratio > 1.5
}
