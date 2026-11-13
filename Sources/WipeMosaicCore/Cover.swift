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
    public init(rect: CGRect, person: Int) {
        self.rect = rect
        self.person = person
    }
}

/// An image (e.g. a cut-out face photo) drawn over a face.
///
/// When the image has a face of its own, that face is laid over the face in the video, so a
/// face photo replaces the face at its size. Otherwise the opaque part of the image (its
/// transparent margin ignored) is laid over the face box. Either way the image is scaled
/// uniformly so its anchor covers the face box times `scale` completely.
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

    public init(cgImage: CGImage) throws {
        let w = cgImage.width, h = cgImage.height
        guard w >= 8, h >= 8 else { throw ToolError("画像が小さすぎます（8×8ピクセル以上にしてください）") }
        self.cgImage = cgImage
        image = CIImage(cgImage: cgImage)

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
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: aw, height: ah))
            return true
        }
        guard drawn else { throw ToolError("画像を読み込めません") }
        // Flip so row 0 is the bottom, like Core Image.
        var flipped = [UInt8](repeating: 0, count: aw * ah)
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

        // A face in the image (detected on the image over grey, so a transparent background
        // does not read as black).
        let ext = image.extent
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: ext)
        let flat = image.composited(over: grey)
        let faces = (try? detectFaces(image: flat, tiles: 1, extraRegions: [])) ?? []
        let largest = faces.max { a, b in a.width * a.height < b.width * b.height }
        let minArea = ext.width * ext.height * 0.02
        if let face = largest, face.width * face.height >= minArea {
            anchor = face
            anchoredOnFace = true
        } else {
            anchor = opaque
            anchoredOnFace = false
        }
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

    /// Share of the face (the ellipse inside a square face box) covered by opaque pixels
    /// (alpha ≥ 50%) when drawn at `scale`. Below 1, part of the real face shows through.
    public func coverage(scale: Double) -> Double {
        let face = CGRect(x: 0, y: 0, width: 100, height: 100)
        let (f, origin) = placement(over: face, scale: scale)
        let ext = image.extent
        let n = 40
        var inside = 0, covered = 0
        for j in 0..<n {
            for i in 0..<n {
                let px = (Double(i) + 0.5) / Double(n), py = (Double(j) + 0.5) / Double(n)
                let dx = px - 0.5, dy = py - 0.5
                guard dx * dx + dy * dy <= 0.25 else { continue }
                inside += 1
                // Point in the face → point in the image → alpha sample.
                let ix = (face.minX + px * face.width - origin.x) / f
                let iy = (face.minY + py * face.height - origin.y) / f
                guard ix >= 0, iy >= 0, ix < ext.width, iy < ext.height else { continue }
                let ax = min(alphaSize.w - 1, Int(ix / ext.width * Double(alphaSize.w)))
                let ay = min(alphaSize.h - 1, Int(iy / ext.height * Double(alphaSize.h)))
                if alpha[ay * alphaSize.w + ax] >= 128 { covered += 1 }
            }
        }
        return inside == 0 ? 0 : Double(covered) / Double(inside)
    }

    /// The image placed over `face`, ready to composite over the frame.
    func drawn(over face: CGRect, scale: Double) -> CIImage {
        let (f, origin) = placement(over: face, scale: scale)
        let resized = f < 1
            ? image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: f, kCIInputAspectRatioKey: 1])
            : image.transformed(by: CGAffineTransform(scaleX: f, y: f))
        let e = resized.extent
        return resized.transformed(by: CGAffineTransform(translationX: origin.x - e.minX, y: origin.y - e.minY))
    }
}

/// Everything that hides one frame: boxes hidden with `render.style`, then stickers on top.
public func applyCover(
    _ img: CIImage, rects: [CGRect], stickers: [StickerBox], render: RenderSettings, block: CGFloat
) -> CIImage {
    var out = render.style == .blur ? applyBlur(img, rects: rects, block: block) : applyMosaic(img, rects: rects, block: block)
    for s in stickers {
        guard let sticker = render.stickers[s.person] else { continue }
        out = sticker.drawn(over: s.rect, scale: render.stickerScale).composited(over: out).cropped(to: img.extent)
    }
    return out
}

/// Blur that keeps no more detail than the mosaic of the same block size: the region is
/// pixellated first (detail removed for good) and the blocks are then blurred smooth, so a
/// sharpening filter cannot bring back what a plain blur would only have spread out.
public func applyBlur(_ img: CIImage, rects: [CGRect], block: CGFloat) -> CIImage {
    guard !rects.isEmpty else { return img }
    let ext = img.extent
    let blurred = img.clampedToExtent()
        .applyingFilter(
            "CIPixellate",
            parameters: [kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: ext.minX, y: ext.minY)]
        )
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: block * 2])
        .cropped(to: ext)
    var out = img
    for r in rects {
        let c = r.intersection(ext)
        if !c.isNull && !c.isEmpty { out = blurred.cropped(to: c).composited(over: out) }
    }
    return out
}

/// Steady boxes for a sticker: a detected face box jitters a little every frame, which a
/// mosaic hides but a picture shows. Within each run of consecutive frames:
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
        while j + 1 < boxes.count, boxes[j + 1] != nil { j += 1 }
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
