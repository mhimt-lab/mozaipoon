import AVFoundation
import CoreImage
import Foundation
import Vision

// Text recognition in separate processes.
//
// Vision reads one frame at a time per process: more threads, other compute devices or
// smaller images did not make a reading faster or let two run together. Separate processes
// do run together: 4 processes read 4 copies of a 40 s 1080p60 camera video in 49 s, while one
// alone took 38 s (M3 Max, macOS 27.2, 2026-11-14). So `analyzeText` decides which frames to
// read (as before) and hands each one to a worker process: the same executable started with
// `textWorkerArgument`. A worker decodes the video itself up to each frame it is told, reads
// it and sends the observations back archived (`NSKeyedArchiver` keeps everything
// `boundingBox(for:)` needs: the boxes of every character range matched those of the
// original in a test of 2,846 ranges). The results are applied in the original order, so the
// output is the same as reading in one process.

/// Starts an executable as a text-reading worker (see `runWorkerIfRequested`).
public let textWorkerArgument = "--wipe-mosaic-text-worker"

/// Worker processes for `analyzeText`: 4 on a Mac with 16 GB or more and 8 or more cores
/// (each took up to ~130 MB with 1080p and 2560×1600 videos), 2 with 8 GB and 4 cores, else
/// none. `WIPE_MOSAIC_TEXT_WORKERS` overrides it (0 or 1: read in this process; at most 16).
public func textWorkerCount() -> Int {
    if let s = ProcessInfo.processInfo.environment["WIPE_MOSAIC_TEXT_WORKERS"], let n = Int(s) { return min(max(0, n), 16) }
    let memory = ProcessInfo.processInfo.physicalMemory
    let cores = ProcessInfo.processInfo.activeProcessorCount
    // 8 read a 2 min 1080p30 camera video in 88 s, 4 in 111 s, 6 in 95 s, 10 in 87 s (M3 Max
    // with 14 cores and 36 GB, 2026-11-17; the same result each time).
    if memory >= 32 << 30, cores >= 12 { return 8 }
    if memory >= 16 << 30, cores >= 8 { return 4 }
    return memory >= 8 << 30 && cores >= 4 ? 2 : 0
}

/// One recognition: the frame (index and time, to check that a worker read the frame it was
/// asked for), the size of the image and the observations.
struct TextReading {
    let frame: Int
    let time: Double
    let width: Int
    let height: Int
    let observations: [VNRecognizedTextObservation]
    /// Corners of the QR codes (top left, top right, bottom right, bottom left of the code),
    /// in pixels of the frame (bottom-left origin).
    let codes: [[CGPoint]]
}

private struct StopDecoding: Error {}

/// Reads "job frame deep" lines from stdin (frames in increasing order), recognizes each frame and
/// writes the results to stdout: job, frame, the frame's time (the bits of the Double), width,
/// height and byte count (Int64 each, little endian), then the archived text observations and
/// QR code corners (an array of the observations and the corners' numbers, 8 per code).
func textWorkerMain(video: URL) throws {
    let asset = AVURLAsset(url: video)
    let info = try waitFor { try await loadVideo(asset) }
    func next() throws -> (job: Int, frame: Int, deep: Bool)? {
        guard let line = readLine() else { return nil }
        let parts = line.split(separator: " ").compactMap { Int($0) }
        guard parts.count == 3 else { throw ToolError("bad request: \(line)") }
        return (parts[0], parts[1], parts[2] != 0)
    }
    var target = try next()
    guard target != nil else { return }
    let out = FileHandle.standardOutput
    do {
        try forEachFrame(asset: asset, info: info) { i, time, image in
            while let t = target, t.frame == i {
                let reading = try recognizeText(image, frame: i, time: time, deep: t.deep)
                let boxes = reading.codes.flatMap { $0.flatMap { [NSNumber(value: Double($0.x)), NSNumber(value: Double($0.y))] } }
                let data = try NSKeyedArchiver.archivedData(
                    withRootObject: [reading.observations, boxes] as NSArray, requiringSecureCoding: true)
                var header = Data()
                for v in [t.job, t.frame, Int(Int64(bitPattern: time.bitPattern)), reading.width, reading.height, data.count] {
                    withUnsafeBytes(of: Int64(v).littleEndian) { header.append(contentsOf: $0) }
                }
                try out.write(contentsOf: header + data)
                target = try next()
            }
            guard let t = target else { throw StopDecoding() }
            guard t.frame > i else { throw ToolError("frame \(t.frame) asked after frame \(i)") }
        }
    } catch is StopDecoding {
        return
    }
    if let t = target { throw ToolError("frame \(t.frame) not in the video") }
}

/// Worker processes reading frames for one `analyzeText` call. Jobs go to the workers in turn;
/// a reader thread per worker collects the results.
final class TextWorkerPool: @unchecked Sendable {
    private let workers: WorkerProcesses
    private var results: [Int: TextReading] = [:]  // by job, under `workers.state`

    /// Starts `count` workers; throws when they cannot be started.
    init(executable: URL, video: URL, count: Int) throws {
        workers = try WorkerProcesses(executable: executable, count: count, label: "文字を読み取る処理", takesInput: true) { _ in
            [textWorkerArgument, video.path]
        }
        workers.start { [weak self] k, bytes in
            guard let self, let header = try bytes(48) else { return false }
            let v = (0..<6).map { i in header.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(fromByteOffset: i * 8, as: Int64.self)) } }
            // Anything else written to stdout would show up here as a nonsense header.
            guard v[0] >= 0, v[0] % Int64(count) == Int64(k), v[1] >= 0, v[3] > 0, v[4] > 0, (0...(256 << 20)).contains(v[5]) else {
                throw ToolError("unexpected output: \(v)")
            }
            guard let body = try bytes(Int(v[5])) else { return false }
            // Our own child wrote this archive; secure decoding rejects the observations'
            // nested time range, so it is decoded without it.
            let u = try NSKeyedUnarchiver(forReadingFrom: body)
            u.requiresSecureCoding = false
            guard let root = u.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [Any], root.count == 2,
                let obs = root[0] as? [VNRecognizedTextObservation], let numbers = root[1] as? [NSNumber], numbers.count % 8 == 0
            else {
                throw ToolError("unreadable result for frame \(v[1])")
            }
            let n = numbers.map { CGFloat($0.doubleValue) }
            let codes = stride(from: 0, to: n.count, by: 8).map { k in (0..<4).map { CGPoint(x: n[k + 2 * $0], y: n[k + 2 * $0 + 1]) } }
            let reading = TextReading(
                frame: Int(v[1]), time: Double(bitPattern: UInt64(bitPattern: v[2])), width: Int(v[3]), height: Int(v[4]),
                observations: obs, codes: codes)
            self.workers.state.withLock {
                self.results[Int(v[0])] = reading
                self.workers.state.broadcast()
            }
            return true
        }
    }

    /// Asks the next worker in turn to read `frame` as `job`. Frames must increase.
    func submit(job: Int, frame: Int, deep: Bool) throws {
        try workers.send("\(job) \(frame) \(deep ? 1 : 0)\n", to: job % workers.count)
    }

    /// The result of `job` if it has arrived; `wait` blocks until it does. Throws when the
    /// worker reading it stopped first.
    func take(_ job: Int) throws -> TextReading? {
        try workers.state.withLock {
            if let r = results.removeValue(forKey: job) { return r }
            try workers.check(job % workers.count)
            return nil
        }
    }

    func wait(_ job: Int) throws -> TextReading {
        try workers.wait(for: job % workers.count) { results.removeValue(forKey: job) }
    }

    /// No more jobs: the workers exit after their last result.
    func finish() { workers.finishInput() }

    func terminate() { workers.terminate() }
}
