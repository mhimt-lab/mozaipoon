import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WipeMosaicCore

/// A registered photo face, used only to pre-select similar people.
struct RegisteredFace: Identifiable {
    let id: UUID
    let thumbnail: CGImage
    let signature: FaceSignature
}

/// Registered faces are kept on this Mac only:
/// ~/Library/Application Support/WipeMosaic/faces/<uuid>.sig / <uuid>.png
enum FaceStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WipeMosaic/faces", isDirectory: true)
    }

    static func loadAll() -> [RegisteredFace] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
        else { return [] }
        let sigs = files.filter { $0.pathExtension == "sig" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
        return sigs.compactMap { url in
            let base = url.deletingPathExtension()
            guard let id = UUID(uuidString: base.lastPathComponent),
                let data = try? Data(contentsOf: url), let sig = try? FaceSignature(data: data),
                let src = CGImageSourceCreateWithURL(base.appendingPathExtension("png") as CFURL, nil),
                let thumb = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else { return nil }
            return RegisteredFace(id: id, thumbnail: thumb, signature: sig)
        }
    }

    static func save(_ face: RegisteredFace) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.appendingPathComponent(face.id.uuidString)
        try face.signature.data().write(to: base.appendingPathExtension("sig"), options: .atomic)
        try writePNG(face.thumbnail, to: base.appendingPathExtension("png"))
    }

    static func delete(_ id: UUID) throws {
        let base = directory.appendingPathComponent(id.uuidString)
        for ext in ["sig", "png"] {
            let url = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}
