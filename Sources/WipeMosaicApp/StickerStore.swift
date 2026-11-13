import CoreGraphics
import Foundation
import WipeMosaicCore

/// An image the user chose to put over a person's face.
struct StickerItem: Identifiable {
    let id: UUID
    let sticker: Sticker
}

/// Stickers are kept on this Mac only, so they can be used again in other videos:
/// ~/Library/Application Support/WipeMosaic/stickers/<uuid>.png
enum StickerStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WipeMosaic/stickers", isDirectory: true)
    }

    static func loadAll() -> [StickerItem] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
        else { return [] }
        let pngs = files.filter { $0.pathExtension == "png" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
        return pngs.compactMap { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                let s = try? Sticker(contentsOf: url)
            else { return nil }
            return StickerItem(id: id, sticker: s)
        }
    }

    static func save(_ item: StickerItem) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePNG(item.sticker.cgImage, to: directory.appendingPathComponent(item.id.uuidString).appendingPathExtension("png"))
    }

    static func delete(_ id: UUID) throws {
        let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("png")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
