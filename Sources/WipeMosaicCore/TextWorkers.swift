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

/// Starts an executable as a text-reading worker (see `runTextWorkerIfRequested`).
public let textWorkerArgument = "--wipe-mosaic-text-worker"

/// Worker processes for `analyzeText`: 4 on a Mac with 16 GB or more and 8 or more cores
/// (each takes up to ~300 MB), 2 with 8 GB, else none. `WIPE_MOSAIC_TEXT_WORKERS` overrides
/// it (0 or 1: read in this process).
public func textWorkerCount() -> Int {
    if let s = ProcessInfo.processInfo.environment["WIPE_MOSAIC_TEXT_WORKERS"], let n = Int(s) { return max(0, n) }
    let memory = ProcessInfo.processInfo.physicalMemory
    let cores = ProcessInfo.processInfo.activeProcessorCount
    if memory >= 16 << 30, cores >= 8 { return 4 }
    return memory >= 8 << 30 && cores >= 4 ? 2 : 0
}

/// Call first thing in `main`: when the process was started as a text worker, runs it and
/// exits; otherwise returns at once.
public func runTextWorkerIfRequested() {
    let args = CommandLine.arguments
    guard args.count == 3, args[1] == textWorkerArgument else { return }
    signal(SIGPIPE, SIG_IGN)  // a closed pipe should fail a write, not kill silently
    do {
        try textWorkerMain(video: URL(fileURLWithPath: args[2]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("text worker: \(error)\n".utf8))
        exit(1)
    }
}

/// One recognition: the observations and the size of the image they were read from.
struct TextReading {
    let width: Int
    let height: Int
    let observations: [VNRecognizedTextObservation]
}

private struct StopDecoding: Error {}

/// Reads "job frame" lines from stdin (frames in increasing order), recognizes each frame and
/// writes the results to stdout: job, frame, width, height and byte count (Int64 each, little
/// endian), then the archived observations.
private func textWorkerMain(video: URL) throws {
    let asset = AVURLAsset(url: video)
    let info = try waitFor { try await loadVideo(asset) }
    func next() throws -> (job: Int, frame: Int)? {
        guard let line = readLine() else { return nil }
        let parts = line.split(separator: " ").compactMap { Int($0) }
        guard parts.count == 2 else { throw ToolError("bad request: \(line)") }
        return (parts[0], parts[1])
    }
    var target = try next()
    guard target != nil else { return }
    let out = FileHandle.standardOutput
    do {
        try forEachFrame(asset: asset, info: info) { i, _, image in
            while let t = target, t.frame == i {
                let reading = try recognizeText(image)
                let data = try NSKeyedArchiver.archivedData(withRootObject: reading.observations, requiringSecureCoding: true)
                var header = Data()
                for v in [t.job, t.frame, reading.width, reading.height, data.count] {
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

/// Runs async work from synchronous code (the worker starts before any run loop).
private func waitFor<T>(_ work: @escaping () async throws -> T) throws -> T {
    let box = ResultBox<T>(count: 1)
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.set(0, .success(try await work())) } catch { box.set(0, .failure(error)) }
        done.signal()
    }
    done.wait()
    return try box.values()[0]
}

/// Worker processes reading frames for one `analyzeText` call. Jobs go to the workers in turn;
/// a reader thread per worker collects the results.
final class TextWorkerPool: @unchecked Sendable {
    private let processes: [Process]
    private let inputs: [FileHandle]
    private let state = NSCondition()
    private var results: [Int: TextReading] = [:]
    private var ended: [Bool]
    private var errorText: [String]
    private var failure: String?

    /// Starts `count` workers; throws when they cannot be started.
    init(executable: URL, video: URL, count: Int) throws {
        var processes: [Process] = []
        var inputs: [FileHandle] = []
        var outputs: [FileHandle] = []
        var errors: [FileHandle] = []
        for _ in 0..<count {
            let p = Process()
            p.executableURL = executable
            p.arguments = [textWorkerArgument, video.path]
            let input = Pipe(), output = Pipe(), error = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = error
            do {
                try p.run()
            } catch {
                for q in processes { q.terminate() }
                throw error
            }
            // Writing to a worker that died must fail that write, not kill this process (the
            // app) with SIGPIPE.
            processes.append(p)
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                for q in processes { q.terminate() }
                throw ToolError("文字を読み取る処理を始められません: \(String(cString: strerror(errno)))")
            }
            inputs.append(input.fileHandleForWriting)
            outputs.append(output.fileHandleForReading)
            errors.append(error.fileHandleForReading)
        }
        self.processes = processes
        self.inputs = inputs
        ended = Array(repeating: false, count: count)
        errorText = Array(repeating: "", count: count)
        for k in 0..<count {
            errors[k].readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard let self, !d.isEmpty else { h.readabilityHandler = nil; return }
                self.state.withLock { self.errorText[k] = String((self.errorText[k] + String(decoding: d, as: UTF8.self)).suffix(2000)) }
            }
            let reader = Thread { [weak self] in self?.read(outputs[k], worker: k) }
            reader.name = "text worker \(k)"
            reader.start()
        }
    }

    deinit { terminate() }

    /// Asks the next worker in turn to read `frame` as `job`. Frames must increase.
    func submit(job: Int, frame: Int) throws {
        let k = job % inputs.count
        do {
            try inputs[k].write(contentsOf: Data("\(job) \(frame)\n".utf8))
        } catch {
            throw ToolError(state.withLock { workerFailure(k) ?? "文字を読み取る処理 \(k + 1) が途中で止まりました（\(error)）" })
        }
    }

    /// The result of `job` if it has arrived; `wait` blocks until it does. Throws when the
    /// worker reading it stopped first.
    func take(_ job: Int) throws -> TextReading? {
        try state.withLock { try available(job) }
    }

    func wait(_ job: Int) throws -> TextReading {
        state.lock()
        defer { state.unlock() }
        while true {
            if let r = try available(job) { return r }
            if Task.isCancelled { throw CancellationError() }
            _ = state.wait(until: Date(timeIntervalSinceNow: 0.2))
        }
    }

    /// No more jobs: the workers exit after their last result.
    func finish() {
        for h in inputs { try? h.close() }
    }

    func terminate() {
        finish()
        for p in processes where p.isRunning { p.terminate() }
    }

    // Callers hold `state`.
    private func available(_ job: Int) throws -> TextReading? {
        if let f = failure { throw ToolError(f) }
        if let r = results.removeValue(forKey: job) { return r }
        let k = job % inputs.count
        if ended[k] { throw ToolError(workerFailure(k) ?? "文字を読み取る処理 \(k + 1) が途中で止まりました") }
        return nil
    }

    private func workerFailure(_ k: Int) -> String? {
        let text = errorText[k].trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : "文字を読み取る処理 \(k + 1) でエラーが起きました: \(text)"
    }

    private func read(_ h: FileHandle, worker k: Int) {
        func exactly(_ n: Int) throws -> Data? {
            var data = Data()
            while data.count < n {
                guard let d = try h.read(upToCount: n - data.count), !d.isEmpty else { return nil }
                data.append(d)
            }
            return data
        }
        do {
            while let header = try exactly(40) {
                let v = (0..<5).map { i in header.withUnsafeBytes { Int(Int64(littleEndian: $0.loadUnaligned(fromByteOffset: i * 8, as: Int64.self))) } }
                guard let body = try exactly(v[4]) else { break }
                // Our own child wrote this archive; secure decoding rejects the observations'
                // nested time range, so it is decoded without it.
                let u = try NSKeyedUnarchiver(forReadingFrom: body)
                u.requiresSecureCoding = false
                guard let obs = u.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [VNRecognizedTextObservation] else {
                    throw ToolError("unreadable result for frame \(v[1])")
                }
                state.withLock {
                    results[v[0]] = TextReading(width: v[2], height: v[3], observations: obs)
                    state.broadcast()
                }
            }
        } catch {
            state.withLock { failure = failure ?? "文字を読み取る処理 \(k + 1) の結果を受け取れませんでした: \(error)" }
        }
        processes[k].waitUntilExit()
        // Let the last lines of stderr arrive before reporting why it stopped.
        Thread.sleep(forTimeInterval: 0.05)
        state.withLock {
            ended[k] = true
            state.broadcast()
        }
    }
}
