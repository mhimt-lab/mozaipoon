import Foundation

/// Containers AVFoundation cannot open (e.g. MXF from Sony FX6 / FX3 / Venice) are rewrapped
/// into a temporary .mov with ffmpeg — streams are copied, not re-encoded, so the picture and
/// sound are unchanged. Everything stays on this Mac. Requires ffmpeg (Homebrew).
enum Remux {
    static var ffmpeg: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WipeMosaic-remux", isDirectory: true)
    }

    /// Rewrap `input` into a new .mov (first video stream + every audio stream).
    static func toMOV(_ input: URL) async throws -> URL {
        guard let ffmpeg else {
            throw RemuxError("この形式を開くには ffmpeg が必要です（ターミナルで brew install ffmpeg）。または MP4・MOV に変換してから追加してください。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let out = directory.appendingPathComponent(UUID().uuidString + ".mov")
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-nostdin", "-v", "error", "-i", input.path, "-map", "0:v:0", "-map", "0:a?", "-c", "copy", "-f", "mov", out.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                p.terminationHandler = { _ in c.resume() }
                do { try p.run() } catch { c.resume(throwing: error) }
            }
        } onCancel: {
            p.terminate()
        }
        guard p.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: out)
            let detail = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .split(separator: "\n").last.map(String.init) ?? ""
            throw RemuxError("読み込める形式に変換できませんでした。\(detail)")
        }
        return out
    }

    static func remove(_ url: URL?) {
        guard let url, url.path.hasPrefix(directory.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Leftovers from a previous run (e.g. after a crash).
    static func removeAll() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "mov" {
            try? fm.removeItem(at: f)
        }
    }
}

struct RemuxError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
