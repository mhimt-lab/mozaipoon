import CoreImage
import Foundation
import ImageIO
import Vision

/// Vision has no public face-identity API. A generic image feature print of a face crop is
/// used instead, in two flavours (measured on synthetic faces, 2026-11-12):
/// - `.appearance`: wide colour crop incl. hair/clothes. Separates people well *within one
///   video* (same clothes), so it is used to group tracks into people.
/// - `.identity`: tighter greyscale crop. Weak but less clothes-dependent; only used to
///   *suggest* which people match a registered photo. Never trusted without the user.
public enum SignatureKind: Sendable {
    case appearance, identity

    var cropScale: CGFloat { self == .appearance ? 1.5 : 1.15 }
    var mono: Bool { self == .identity }
}

public struct FaceSignature: @unchecked Sendable {
    let observation: VNFeaturePrintObservation

    public func data() throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    public init(data: Data) throws {
        guard
            let obs = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
        else { throw ToolError("invalid face signature data") }
        observation = obs
    }

    init(_ observation: VNFeaturePrintObservation) { self.observation = observation }
}

public func faceSignature(in image: CIImage, face: CGRect, kind: SignatureKind) throws -> FaceSignature {
    let side = max(face.width, face.height) * kind.cropScale
    let crop = CGRect(x: face.midX - side / 2, y: face.midY - side / 2, width: side, height: side)
        .integral.intersection(image.extent)
    guard !crop.isNull, crop.width >= 4, crop.height >= 4 else { throw ToolError("face too small") }
    var ci = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    if kind.mono { ci = ci.applyingFilter("CIPhotoEffectMono") }
    let req = VNGenerateImageFeaturePrintRequest()
    req.imageCropAndScaleOption = .scaleFill
    try VNImageRequestHandler(ciImage: ci, options: [:]).perform([req])
    guard let obs = req.results?.first else { throw ToolError("feature print failed") }
    return FaceSignature(obs)
}

public func distance(_ a: FaceSignature, _ b: FaceSignature) throws -> Float {
    var d: Float = 0
    try a.observation.computeDistance(&d, to: b.observation)
    return d
}

public struct PhotoFace: @unchecked Sendable {
    public let signature: FaceSignature  // .identity
    /// Square crop of the face (for list thumbnails).
    public let thumbnail: CGImage
    /// Number of faces found in the photo (the largest one is used).
    public let faceCount: Int
}

/// Crop a square face thumbnail of `size` points from an image (Core Image coordinates).
func thumbnail(_ image: CIImage, face: CGRect, size: CGFloat = 160) throws -> CGImage {
    let side = max(face.width, face.height) * 1.4
    let crop = CGRect(x: face.midX - side / 2, y: face.midY - side / 2, width: side, height: side)
        .integral.intersection(image.extent)
    let s = size / max(crop.width, crop.height)
    let t = image.cropped(to: crop)
        .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        .transformed(by: CGAffineTransform(scaleX: s, y: s))
    guard let cg = CIContext().createCGImage(t, from: t.extent) else { throw ToolError("cannot make thumbnail") }
    return cg
}

/// Register a face from a photo: the largest face in the image is used.
public func faceFromPhoto(_ url: URL) throws -> PhotoFace {
    guard let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
        throw ToolError("画像を読み込めません: \(url.lastPathComponent)")
    }
    let image = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
    let faces = try detectFaces(image: image, tiles: 2, extraRegions: [])
    let area: (CGRect) -> CGFloat = { $0.width * $0.height }
    guard let face = faces.max(by: { area($0) < area($1) }) else {
        throw ToolError("顔が見つかりません: \(url.lastPathComponent)")
    }
    return PhotoFace(
        signature: try faceSignature(in: image, face: face, kind: .identity),
        thumbnail: try thumbnail(image, face: face), faceCount: faces.count)
}
