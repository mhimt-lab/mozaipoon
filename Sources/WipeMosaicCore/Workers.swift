import Foundation

// Worker processes: the same executable started again to do Vision work that does not run
// together inside one process (reading text: TextWorkers.swift; finding faces:
// FaceWorkers.swift). This file is what the two have in common: starting the processes,
// collecting what they write, and noticing when one stops.

/// Call first thing in `main`: when the process was started as a worker, runs it and exits;
/// otherwise returns at once.
public func runWorkerIfRequested() {
    let args = CommandLine.arguments
    guard args.count >= 3 else { return }
    let work: () throws -> Void
    switch args[1] {
    case textWorkerArgument where args.count == 3: work = { try textWorkerMain(video: URL(fileURLWithPath: args[2])) }
    case faceWorkerArgument: work = { try faceWorkerMain(video: URL(fileURLWithPath: args[2]), arguments: Array(args[3...])) }
    default: return
    }
    signal(SIGPIPE, SIG_IGN)  // a closed pipe should fail a write, not kill silently
    do {
        try work()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

/// Runs async work from synchronous code (a worker starts before any run loop).
func waitFor<T>(_ work: @escaping () async throws -> T) throws -> T {
    let box = ResultBox<T>(count: 1)
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.set(0, .success(try await work())) } catch { box.set(0, .failure(error)) }
        done.signal()
    }
    done.wait()
    return try box.values()[0]
}

/// The worker processes of one job. A thread per worker reads what it writes, one record at a
/// time (`start`); the owner keeps the records and hands them out under `state`.
final class WorkerProcesses: @unchecked Sendable {
    let count: Int
    /// Guards the owner's records as well as the workers' state; broadcast when either changes.
    let state = NSCondition()
    /// Each worker's stdin (empty when the workers take none).
    let inputs: [FileHandle]
    private let processes: [Process]
    private let outputs: [FileHandle]
    /// What the workers do, for messages (「文字を読み取る処理」).
    private let label: String
    private var ended: [Bool]
    private var errorText: [String]
    private var failure: String?

    /// Starts `count` workers, worker k with `arguments(k)`; throws when they cannot be started.
    init(executable: URL, count: Int, label: String, takesInput: Bool, arguments: (Int) -> [String]) throws {
        var processes: [Process] = []
        var inputs: [FileHandle] = []
        var outputs: [FileHandle] = []
        var errors: [FileHandle] = []
        for k in 0..<count {
            let p = Process()
            p.executableURL = executable
            p.arguments = arguments(k)
            let input = Pipe(), output = Pipe(), error = Pipe()
            p.standardInput = takesInput ? input : FileHandle.nullDevice
            p.standardOutput = output
            p.standardError = error
            do {
                try p.run()
            } catch {
                for q in processes { q.terminate() }
                throw ToolError("\(label)を始められません（アプリを移動したり入れ替えたりしたときは、アプリを開き直してください）: \(error.localizedDescription)")
            }
            processes.append(p)
            if takesInput {
                // Writing to a worker that died must fail that write, not kill this process
                // (the app) with SIGPIPE.
                guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                    for q in processes { q.terminate() }
                    throw ToolError("\(label)を始められません: \(String(cString: strerror(errno)))")
                }
                inputs.append(input.fileHandleForWriting)
            }
            outputs.append(output.fileHandleForReading)
            errors.append(error.fileHandleForReading)
        }
        self.count = count
        self.label = label
        self.processes = processes
        self.inputs = inputs
        self.outputs = outputs
        ended = Array(repeating: false, count: count)
        errorText = Array(repeating: "", count: count)
        for k in 0..<count {
            errors[k].readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard let self, !d.isEmpty else { h.readabilityHandler = nil; return }
                self.state.withLock { self.errorText[k] = String((self.errorText[k] + String(decoding: d, as: UTF8.self)).suffix(2000)) }
            }
        }
    }

    deinit { terminate() }

    /// Starts reading what the workers write. `record` reads one record of worker k with
    /// `bytes` (exactly that many, nil at the end of the output) and keeps it (under `state`,
    /// with a broadcast); it returns false at the end of the output.
    func start(record: @escaping @Sendable (_ worker: Int, _ bytes: (Int) throws -> Data?) throws -> Bool) {
        for k in 0..<count {
            let reader = Thread { [weak self] in self?.read(worker: k, record: record) }
            reader.name = "\(label) \(k)"
            reader.start()
        }
    }

    /// No more input: the workers exit after their last result.
    func finishInput() {
        for h in inputs { try? h.close() }
    }

    func terminate() {
        finishInput()
        for p in processes where p.isRunning { p.terminate() }
    }

    /// Writes `line` to worker k's stdin.
    func send(_ line: String, to k: Int) throws {
        do {
            try inputs[k].write(contentsOf: Data(line.utf8))
        } catch {
            throw ToolError(state.withLock { workerFailure(k) ?? "\(label) \(k + 1) が途中で止まりました（\(error)）" })
        }
    }

    /// Throws when a record could not be read, or worker k has stopped. Callers hold `state`,
    /// and look for the record they want first: a worker that stopped has written all it had.
    func check(_ k: Int) throws {
        if let f = failure { throw ToolError(f) }
        if ended[k] { throw ToolError(workerFailure(k) ?? "\(label) \(k + 1) が途中で止まりました") }
    }

    /// What `take` gives (under `state`) once it is not nil: waits for worker k to write it.
    func wait<T>(for k: Int, _ take: () throws -> T?) throws -> T {
        state.lock()
        defer { state.unlock() }
        // A frame takes well under a second; a worker silent this long is stuck.
        let deadline = Date(timeIntervalSinceNow: 120)
        while true {
            if let r = try take() { return r }
            try check(k)
            if Task.isCancelled { throw CancellationError() }
            if Date() > deadline { throw ToolError("\(label) \(k + 1) が 2 分以上応答しません") }
            _ = state.wait(until: Date(timeIntervalSinceNow: 0.2))
        }
    }

    private func workerFailure(_ k: Int) -> String? {
        let text = errorText[k].trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : "\(label) \(k + 1) でエラーが起きました: \(text)"
    }

    private func read(worker k: Int, record: (Int, (Int) throws -> Data?) throws -> Bool) {
        let h = outputs[k]
        func bytes(_ n: Int) throws -> Data? {
            var data = Data()
            while data.count < n {
                guard let d = try h.read(upToCount: n - data.count), !d.isEmpty else { return nil }
                data.append(d)
            }
            return data
        }
        do {
            while try record(k, bytes) {}
        } catch {
            state.withLock { failure = failure ?? "\(label) \(k + 1) の結果を受け取れませんでした: \(error)" }
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
