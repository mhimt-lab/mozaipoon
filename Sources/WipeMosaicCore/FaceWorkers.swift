import AVFoundation
import CoreImage
import Foundation

// Face detection in separate processes.
//
// As with text (TextWorkers.swift), Vision's face detection does not go faster with more
// threads in one process, but separate processes do run together: the faces of a 2 min 1080p30
// camera video were found in 71 s by one process, and four processes each finding them at
// once took 97 s (2.9 times the work in the time; M3 Max, macOS 27.2, 2026-11-17). So
// `forEachFrameDetecting` starts worker processes: the same executable started with
// `faceWorkerArgument`. Worker k of n decodes the video itself and detects the faces of the
// frames whose index is k modulo n, exactly as one process does for every frame; this
// process decodes the frames too (decoding is under 1 % of the time) and takes each frame's
// faces from the worker that has them. The result is the same as detecting in one process.

/// Starts an executable as a face-detecting worker (see `runWorkerIfRequested`).
public let faceWorkerArgument = "--wipe-mosaic-face-worker"

/// Worker processes for `forEachFrameDetecting`: 4 on a Mac with 16 GB or more and 8 or more
/// cores, 2 with 8 GB and 4 cores, else none (as `textWorkerCount` was first set).
/// `WIPE_MOSAIC_FACE_WORKERS` overrides it (0 or 1: detect in this process; at most 16).
public func faceWorkerCount() -> Int {
    if let s = ProcessInfo.processInfo.environment["WIPE_MOSAIC_FACE_WORKERS"], let n = Int(s) { return min(max(0, n), 16) }
    let memory = ProcessInfo.processInfo.physicalMemory
    let cores = ProcessInfo.processInfo.activeProcessorCount
    if memory >= 16 << 30, cores >= 8 { return 4 }
    return memory >= 8 << 30 && cores >= 4 ? 2 : 0
}

/// What a worker is told on its command line, after `faceWorkerArgument` and the video: which
/// frames are its own and how to detect (the arguments of `forEachFrameDetecting`; the
/// intervals as the bits of the Doubles, so they are the same numbers).
struct FaceWorkerTask {
    var worker: Int
    var count: Int
    var tiles: Int
    var tileInterval: Double
    var angleInterval: Double?
    var extraRegions: [CGRect]

    var arguments: [String] {
        var a = [worker, count, tiles].map(String.init)
        a.append(String(tileInterval.bitPattern))
        a.append(angleInterval.map { String($0.bitPattern) } ?? "-")
        for r in extraRegions { a += [r.minX, r.minY, r.width, r.height].map { String(Double($0).bitPattern) } }
        return a
    }

    init(worker: Int, count: Int, tiles: Int, tileInterval: Double, angleInterval: Double?, extraRegions: [CGRect]) {
        self.worker = worker
        self.count = count
        self.tiles = tiles
        self.tileInterval = tileInterval
        self.angleInterval = angleInterval
        self.extraRegions = extraRegions
    }

    init?(arguments a: [String]) {
        guard a.count >= 5, (a.count - 5) % 4 == 0, let worker = Int(a[0]), let count = Int(a[1]), let tiles = Int(a[2]),
            let tileBits = UInt64(a[3]), count > 0, (0..<count).contains(worker), tiles > 0
        else { return nil }
        var regions: [CGRect] = []
        for k in stride(from: 5, to: a.count, by: 4) {
            let v = a[k..<k + 4].compactMap { UInt64($0).map { CGFloat(Double(bitPattern: $0)) } }
            guard v.count == 4 else { return nil }
            regions.append(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
        }
        var angle: Double?
        if a[4] != "-" {
            guard let bits = UInt64(a[4]) else { return nil }
            angle = Double(bitPattern: bits)
        }
        self.init(worker: worker, count: count, tiles: tiles, tileInterval: Double(bitPattern: tileBits), angleInterval: angle, extraRegions: regions)
    }
}

/// The faces of one frame as a worker sends them: frame, the frame's time (the bits of the
/// Double) and the number of faces (Int64 each, little endian), then for each face its box (x,
/// y, width, height), roll, yaw and angle (Doubles; NaN for none).
private let faceRecordHeader = 24
private let faceRecordDoubles = 7

func encodeFaces(frame: Int, time: Double, faces: [FaceBox]) -> Data {
    var data = Data(capacity: faceRecordHeader + faces.count * faceRecordDoubles * 8)
    for v in [Int64(frame), Int64(bitPattern: time.bitPattern), Int64(faces.count)] {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }
    for f in faces {
        let values: [Double] = [
            Double(f.rect.minX), Double(f.rect.minY), Double(f.rect.width), Double(f.rect.height),
            f.roll ?? .nan, f.yaw ?? .nan, f.angle.map { Double($0) } ?? .nan,
        ]
        for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
    }
    return data
}

func decodeFaces(_ body: Data, count: Int) -> [FaceBox] {
    func value(_ i: Int) -> Double {
        Double(bitPattern: UInt64(littleEndian: body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self) }))
    }
    return (0..<count).map { n in
        let v = (0..<faceRecordDoubles).map { value(n * faceRecordDoubles + $0) }
        return FaceBox(
            rect: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), roll: v[4].isNaN ? nil : v[4], yaw: v[5].isNaN ? nil : v[5],
            angle: v[6].isNaN ? nil : CGFloat(v[6]))
    }
}

/// A worker: detects the faces of its frames and writes them to stdout, in order.
func faceWorkerMain(video: URL, arguments: [String]) throws {
    guard let task = FaceWorkerTask(arguments: arguments) else { throw ToolError("bad request: \(arguments)") }
    let asset = AVURLAsset(url: video)
    let info = try waitFor { try await loadVideo(asset) }
    let out = FileHandle.standardOutput
    try forEachFrameDetecting(
        asset: asset, info: info, tiles: task.tiles, tileInterval: task.tileInterval, extraRegions: task.extraRegions,
        angleInterval: task.angleInterval, workers: 0, only: { $0 % task.count == task.worker }
    ) { i, t, _, faces in
        try out.write(contentsOf: encodeFaces(frame: i, time: t, faces: faces))
    }
}

/// Worker processes detecting the faces of one video; `faces(frame:time:)` hands the results
/// out in the order of the frames.
final class FaceWorkerPool: @unchecked Sendable {
    private let workers: WorkerProcesses
    private var results: [Int: (time: Double, faces: [FaceBox])] = [:]  // by frame, under `workers.state`

    /// Starts `count` workers; throws when they cannot be started.
    init(executable: URL, video: URL, count: Int, tiles: Int, tileInterval: Double, angleInterval: Double?, extraRegions: [CGRect]) throws {
        workers = try WorkerProcesses(executable: executable, count: count, label: "顔を探す処理", takesInput: false) { k in
            [faceWorkerArgument, video.path] + FaceWorkerTask(
                worker: k, count: count, tiles: tiles, tileInterval: tileInterval, angleInterval: angleInterval, extraRegions: extraRegions
            ).arguments
        }
        workers.start { [weak self] k, bytes in
            guard let self, let header = try bytes(faceRecordHeader) else { return false }
            let v = (0..<3).map { i in header.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(fromByteOffset: i * 8, as: Int64.self)) } }
            // Anything else written to stdout would show up here as a nonsense header.
            guard v[0] >= 0, v[0] % Int64(count) == Int64(k), (0...100_000).contains(v[2]) else { throw ToolError("unexpected output: \(v)") }
            var body = Data()
            if v[2] > 0 {
                guard let b = try bytes(Int(v[2]) * faceRecordDoubles * 8) else { return false }
                body = b
            }
            let faces = decodeFaces(body, count: Int(v[2]))
            self.workers.state.withLock {
                self.results[Int(v[0])] = (Double(bitPattern: UInt64(bitPattern: v[1])), faces)
                self.workers.state.broadcast()
            }
            return true
        }
    }

    func terminate() { workers.terminate() }

    /// The faces of `frame` (decoded here at `time`), waiting for its worker. Throws when the
    /// worker stopped first, or read another frame there (its time differs).
    func faces(frame: Int, time: Double) throws -> [FaceBox] {
        let k = frame % workers.count
        let r = try workers.wait(for: k) { results.removeValue(forKey: frame) }
        guard r.time == time else {
            throw ToolError("顔を探す処理 \(k + 1) が別のフレームを読みました（\(frame) 番目：\(r.time) 秒と \(time) 秒）")
        }
        return r.faces
    }
}
