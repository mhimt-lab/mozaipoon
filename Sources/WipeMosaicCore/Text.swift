import AVFoundation
import CoreImage
import Vision

/// Kinds of personal information found automatically in on-screen text.
public enum TextKind: String, CaseIterable, Sendable, Identifiable {
    /// Phone, card and account numbers: 6 or more digits, spaces and hyphens allowed.
    case number
    case email
    case url
    /// Postal codes and Japanese addresses.
    case address
    /// Japanese person names with a common family name (see Names.swift).
    case name
    public var id: String { rawValue }
}

/// One recognized line in one recognized frame.
struct TextSample: @unchecked Sendable {
    let frame: Int
    let rect: CGRect  // Core Image coordinates of the upright frame
    let string: String
    /// Kept only for the first sample of each distinct reading in a track (used to find the
    /// boxes of character ranges); long recordings would otherwise hold every result.
    let text: VNRecognizedText?
}

/// One line followed across frames (it may scroll).
public struct TextTrack: Sendable {
    public let id: Int
    fileprivate(set) var samples: [TextSample]
    /// Parts to hide per kind, relative to the line box (0...1).
    fileprivate(set) var parts: [TextKind: [CGRect]] = [:]
    /// The most common reading of the line.
    public fileprivate(set) var text = ""

    /// Frames where the line was recognized (or pinned while the picture did not change).
    public var sampleFrames: [Int] { samples.map(\.frame) }
    var first: Int { samples.first!.frame }
    var last: Int { samples.last!.frame }

    /// Line boxes at the recognized frames with the jitter of recognition taken out, and how
    /// far the recognized box may lie outside each (see `makeSteady`). Empty: the boxes as read.
    fileprivate(set) var steady: [(rect: CGRect, slack: CGSize)] = []

    private func box(_ k: Int) -> CGRect { steady.isEmpty ? samples[k].rect : steady[k].rect }
    private func slack(_ k: Int) -> CGSize { steady.isEmpty ? .zero : steady[k].slack }

    /// Recognition puts the box of the same line a few pixels off every time (±2 px in place
    /// and ±3 px in height were measured), and the mosaic drawn from it shook while the screen
    /// scrolled. Each edge is fitted with straight-line motion over the recognized frames
    /// within `window` seconds; the largest distance from the fit to a recognized edge in that
    /// window is the slack, added to what is hidden (see `motionMargin`), so the hidden box
    /// contains the one drawn from the recognized boxes. Where the fit is off by more than the
    /// line height (a jump the tracker joined, a sudden stop), the recognized box is used.
    /// Made after the line-below and wrap checks, which keep using the recognized boxes.
    mutating func makeSteady(times: [Double], window: Double = 0.25) {
        let ts = samples.map { times[$0.frame] }
        steady = samples.indices.map { k in
            let raw = samples[k].rect
            let near = samples.indices.filter { abs(ts[$0] - ts[k]) <= window + 1e-6 }
            func fit(_ v: (CGRect) -> CGFloat) -> (value: CGFloat, slack: CGFloat) {
                let n = Double(near.count)
                let mt = near.reduce(0) { $0 + ts[$1] } / n
                let mv = near.reduce(0) { $0 + Double(v(samples[$1].rect)) } / n
                let stt = near.reduce(0) { $0 + (ts[$1] - mt) * (ts[$1] - mt) }
                let slope = stt > 1e-12 ? near.reduce(0) { $0 + (ts[$1] - mt) * (Double(v(samples[$1].rect)) - mv) } / stt : 0
                let line = { (t: Double) in mv + slope * (t - mt) }
                let worst = near.map { abs(Double(v(samples[$0].rect)) - line(ts[$0])) }.max() ?? 0
                return (CGFloat(line(ts[k])), CGFloat(worst))
            }
            let x0 = fit(\.minX), x1 = fit(\.maxX), y0 = fit(\.minY), y1 = fit(\.maxY)
            let slack = CGSize(width: max(x0.slack, x1.slack), height: max(y0.slack, y1.slack))
            guard max(slack.width, slack.height) <= raw.height, x1.value > x0.value, y1.value > y0.value else { return (raw, .zero) }
            return (CGRect(x: x0.value, y: y0.value, width: x1.value - x0.value, height: y1.value - y0.value), slack)
        }
    }

    /// Line box at frame `f`: interpolated between recognized frames, and continued for up to
    /// `extend` seconds before the first and after the last one (the line appeared, faded in
    /// or left between two recognized frames; clipped to `bounds` then). Times, not frame
    /// counts: frame rates vary. `anchor`: the corner the mosaic blocks of the line line up
    /// with — where the line is, without the margin or clipping (both change while the line
    /// moves), on whole pixels.
    func line(atFrame f: Int, times: [Double], extend: Double, bounds: CGRect) -> (rect: CGRect, anchor: CGPoint)? {
        func corner(_ r: CGRect) -> CGPoint { CGPoint(x: r.minX.rounded(), y: r.minY.rounded()) }
        let t = times[f]
        if f < first {
            guard times[first] - t <= extend + 1e-6 else { return nil }
            let r0 = box(0)
            guard samples.count > 1 else { return (r0, corner(r0)) }
            let moved = lerp(r0, box(1), -extensionFactor(atFrame: f, times: times))
            return (moved.union(r0).intersection(bounds), corner(moved))
        }
        if f > last {
            guard t - times[last] <= extend + 1e-6 else { return nil }
            let r1 = box(samples.count - 1)
            guard samples.count > 1 else { return (r1, corner(r1)) }
            let moved = lerp(r1, box(samples.count - 2), -extensionFactor(atFrame: f, times: times))
            return (moved.union(r1).intersection(bounds), corner(moved))
        }
        let lo = sampleIndex(atOrAfter: f)
        guard samples[lo].frame != f, lo > 0 else { return (box(lo), corner(box(lo))) }
        let a = samples[lo - 1], b = samples[lo]
        let r = lerp(box(lo - 1), box(lo), CGFloat((t - times[a.frame]) / max(times[b.frame] - times[a.frame], 1e-6)))
        return (r, corner(r))
    }

    func rect(atFrame f: Int, times: [Double], extend: Double, bounds: CGRect) -> CGRect? {
        line(atFrame: f, times: times, extend: extend, bounds: bounds)?.rect
    }

    /// How far (in intervals between the first or last two recognized frames, up to 1.5) frame
    /// `f` before the first or after the last recognized frame is continued.
    private func extensionFactor(atFrame f: Int, times: [Double]) -> CGFloat {
        if f < first {
            return min(1.5, CGFloat((times[first] - times[f]) / max(times[samples[1].frame] - times[first], 1e-6)))
        }
        let prev = samples[samples.count - 2].frame
        return min(1.5, CGFloat((times[f] - times[last]) / max(times[last] - times[prev], 1e-6)))
    }

    /// First sample with frame >= f (f within first...last).
    private func sampleIndex(atOrAfter f: Int) -> Int {
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].frame < f { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Margin to add around what is hidden at frame `f`, so the hidden box contains the one
    /// drawn from the recognized boxes (as before the steady boxes) with its margins:
    /// - the slack of the steady boxes, 1.7 times: the fixed margin (0.35 and 0.3 of the line
    ///   height) is taken of the steady height, up to 2 × slack less than the recognized one;
    ///   continued before the first and after the last recognized frame, the error of the
    ///   steady boxes grows with the distance (`(1 + k)` and `k` times the two slacks);
    /// - room for the line moving. Scrolling speeds up and slows down, so between two
    ///   recognized frames the line is not where straight-line motion puts it: 40 % of the
    ///   motion between the recognized boxes. The same over the whole interval (and the larger
    ///   of the two at a recognized frame), so the hidden box does not swell and shrink with
    ///   every recognition — that pulsing made the mosaic wobble while scrolling.
    /// Added to each hidden part (not to the line box, where a narrow part would get only its
    /// share of it).
    func motionMargin(atFrame f: Int, times: [Double]) -> CGSize {
        func scaled(_ a: CGSize, _ k: CGFloat) -> CGSize { CGSize(width: a.width * k, height: a.height * k) }
        func plus(_ a: CGSize, _ b: CGSize) -> CGSize { CGSize(width: a.width + b.width, height: a.height + b.height) }
        func larger(_ a: CGSize, _ b: CGSize) -> CGSize { CGSize(width: max(a.width, b.width), height: max(a.height, b.height)) }
        func s(_ k: Int) -> CGSize { scaled(slack(k), 1.7) }
        guard samples.count > 1 else { return .zero }
        if f < first {
            let k = extensionFactor(atFrame: f, times: times)
            return plus(scaled(s(0), 1 + k), scaled(s(1), k))
        }
        if f > last {
            let k = extensionFactor(atFrame: f, times: times)
            return plus(scaled(s(samples.count - 1), 1 + k), scaled(s(samples.count - 2), k))
        }
        if f == first { return s(0) }
        if f == last { return s(samples.count - 1) }
        let lo = sampleIndex(atOrAfter: f)
        func interval(_ k: Int) -> CGSize {  // from sample k - 1 to sample k
            guard k > 0, k < samples.count else { return .zero }
            let a = samples[k - 1].rect, b = samples[k].rect
            let motion = CGSize(width: abs(b.midX - a.midX) * 0.4, height: abs(b.midY - a.midY) * 0.4)
            return plus(motion, larger(s(k - 1), s(k)))
        }
        guard samples[lo].frame == f else { return interval(lo) }
        return larger(interval(lo), interval(lo + 1))
    }
}

/// Lines with the same text, listed once.
public struct TextEntry: Sendable, Identifiable {
    /// 1-based, in order of first appearance.
    public let id: Int
    public let text: String
    public let trackIDs: [Int]
    public let firstFrame: Int
    public let frameCount: Int
    /// Kinds of personal information found in the line.
    public let kinds: Set<TextKind>
}

/// What to hide: kinds found automatically, words (anywhere in a line) and whole lines.
public struct TextMaskOptions: Sendable, Equatable {
    public var kinds: Set<TextKind>
    public var words: [String]
    /// Entry ids hidden as a whole line.
    public var lines: Set<Int>
    /// Hide every line that was read (a device screen filmed with a camera).
    public var all: Bool
    public init(kinds: Set<TextKind>, words: [String], lines: Set<Int>, all: Bool = false) {
        self.kinds = kinds
        self.words = words
        self.lines = lines
        self.all = all
    }
}

public struct TextMask: Sendable {
    /// Boxes to mosaic for every decoded frame (Core Image coordinates, margin included).
    public let frames: [[CGRect]]
    /// For each box in `frames`, the corner its mosaic blocks line up with (see `TextTrack.line`).
    public let anchors: [[CGPoint]]
    /// Entries that contain one of the words.
    public let wordHits: Set<Int>
    /// Entries with something hidden.
    public let hidden: Set<Int>
    /// For each word (as typed), the number of lines it was found in (see `wordLineCounts`).
    public let wordLines: [String: Int]
    public var isEmpty: Bool { hidden.isEmpty }
}

/// Text found on screen in a video (screen recordings).
public struct ScreenText: Sendable {
    public let times: [Double]
    public let fps: Double
    public let size: CGSize
    public let tracks: [TextTrack]
    public let entries: [TextEntry]
    /// Seconds a line is continued before/after it was recognized.
    let extend: Double

    public func frameIndex(at time: Double) -> Int { WipeMosaicCore.frameIndex(times, at: time) }

    var entryOfTrack: [Int: Int] {
        var m: [Int: Int] = [:]
        for e in entries { for t in e.trackIDs { m[t] = e.id } }
        return m
    }

    /// Frames where track `t` is shown, `extend` seconds before and after included.
    func frameRange(_ t: TextTrack) -> ClosedRange<Int> {
        let lo = times.partitionIndex { $0 >= times[t.first] - extend - 1e-6 }
        let hi = times.partitionIndex { $0 > times[t.last] + extend + 1e-6 } - 1
        return min(lo, t.first)...max(hi, t.last)
    }

    /// Boxes to mosaic for the options.
    public func mask(_ o: TextMaskOptions) -> TextMask { makeMask(o, cancellable: false)! }

    /// Like `mask`, but nil as soon as the task is cancelled (the app makes masks in the
    /// background and cancels outdated ones). Never a partial mask.
    public func maskUnlessCancelled(_ o: TextMaskOptions) -> TextMask? { makeMask(o, cancellable: true) }

    private func makeMask(_ o: TextMaskOptions, cancellable: Bool) -> TextMask? {
        func cancelled() -> Bool { cancellable && Task.isCancelled }
        let bounds = CGRect(origin: .zero, size: size)
        let words = o.words.map(normalizedForMatch).filter { !$0.isEmpty }
        let owner = entryOfTrack
        var frames = [[CGRect]](repeating: [], count: times.count)
        var anchors = [[CGPoint]](repeating: [], count: times.count)
        var wordHits = Set<Int>()
        var hidden = Set<Int>()
        var relsOf: [Int: [CGRect]] = [:]
        func add(_ rels: [CGRect], line: CGRect, anchor: CGPoint, margin: CGSize = .zero, at f: Int) {
            let h = line.height
            for rel in rels {
                let r = CGRect(
                    x: line.minX + rel.minX * line.width, y: line.minY + rel.minY * line.height,
                    width: rel.width * line.width, height: rel.height * line.height)
                frames[f].append(r.insetBy(dx: -h * 0.35 - margin.width, dy: -h * 0.3 - margin.height).intersection(bounds))
                anchors[f].append(anchor)
            }
        }
        for t in tracks {
            if cancelled() { return nil }
            let entry = owner[t.id] ?? 0
            var rels: [CGRect]
            if o.all || o.lines.contains(entry) {
                rels = [whole]
            } else {
                rels = o.kinds.flatMap { t.parts[$0] ?? [] }
                if !words.isEmpty {
                    let w = wordParts(t, words)
                    if !w.isEmpty { wordHits.insert(entry) }
                    rels += w
                }
            }
            if !rels.isEmpty { relsOf[t.id] = mergeOverlapping(rels) }
        }
        // A line that could not be read for a moment (covered by a banner, blurred by motion)
        // continues as a new track, and a line read differently (O90 for 090) is a new track
        // that may match nothing: a track is continued by the nearest one that starts within
        // `maxGap` at the same place with similar text (with `all`, any text). The parts to
        // hide are shared along each chain of continuations, both ways (the misread one may
        // come first), and the mosaic is kept across the gaps. Filmed screens drop lines for
        // longer (glare, focus, fingers); any text at the place counts there.
        let maxGap = o.all ? 6.0 : 3.0
        let byStart = tracks.sorted { $0.first < $1.first }
        let starts = byStart.map(\.first)
        var next: [Int: TextTrack] = [:]  // track id → its continuation
        for a in byStart {
            if cancelled() { return nil }
            let ra = a.samples[a.samples.count - 1].rect
            let ta = times[a.last]
            var k = starts.partitionIndex { $0 > a.last }
            while k < byStart.count, times[byStart[k].first] - ta <= maxGap {
                let b = byStart[k]
                k += 1
                let rb = b.samples[0].rect
                guard hypot(ra.midX - rb.midX, ra.midY - rb.midY) < 1.5 * max(ra.height, rb.height),
                      rb.height > 0.6 * ra.height, rb.height < 1.6 * ra.height,
                      o.all || similarity(normalizedForMatch(a.text), normalizedForMatch(b.text)) >= 0.6
                else { continue }
                next[a.id] = b
                break  // the nearest continuation is enough
            }
        }
        // Forward then backward: every track of a chain ends with the union of its parts.
        for a in byStart {
            guard let b = next[a.id], let ra = relsOf[a.id] else { continue }
            relsOf[b.id] = mergeOverlapping((relsOf[b.id] ?? []) + ra)
        }
        for a in byStart.reversed() {
            guard let b = next[a.id], let rb = relsOf[b.id] else { continue }
            relsOf[a.id] = mergeOverlapping((relsOf[a.id] ?? []) + rb)
        }
        for t in tracks {
            if cancelled() { return nil }
            guard let rels = relsOf[t.id] else { continue }
            hidden.insert(owner[t.id] ?? 0)
            for f in frameRange(t) {
                guard let line = t.line(atFrame: f, times: times, extend: extend, bounds: bounds), !line.rect.isEmpty else { continue }
                add(rels, line: line.rect, anchor: line.anchor, margin: t.motionMargin(atFrame: f, times: times), at: f)
            }
            if let b = next[t.id] {
                let ra = t.samples[t.samples.count - 1].rect, rb = b.samples[0].rect
                let ta = times[t.last], tb = times[b.first]
                for f in (t.last + 1)..<b.first where times[f] > ta + extend && times[f] < tb - extend {
                    let r = lerp(ra, rb, CGFloat((times[f] - ta) / max(tb - ta, 1e-6)))
                    add(rels, line: r, anchor: CGPoint(x: r.minX.rounded(), y: r.minY.rounded()), at: f)
                }
            }
        }
        // Words also count for entries that are hidden as a whole line.
        if !words.isEmpty {
            for t in tracks where o.lines.contains(owner[t.id] ?? 0) && !wordParts(t, words).isEmpty {
                wordHits.insert(owner[t.id] ?? 0)
            }
        }
        if cancelled() { return nil }
        return TextMask(frames: frames, anchors: anchors, wordHits: wordHits, hidden: hidden, wordLines: wordLineCounts(o.words))
    }

    /// For each word, the number of lines (entries) where it was found in any reading, so the
    /// app can show a word that matched nothing (a misreading, 高 for 髙).
    public func wordLineCounts(_ words: [String]) -> [String: Int] {
        let owner = entryOfTrack
        var out: [String: Int] = [:]
        for w in words {
            let n = normalizedForMatch(w)
            guard !n.isEmpty else { continue }
            var lines = Set<Int>()
            for t in tracks where distinctReadings(t).contains(where: { !wordRanges(in: $0.string, words: [n]).isEmpty }) {
                // A track with no line is still a hit (count it on its own), never folded into line 0.
                lines.insert(owner[t.id] ?? -1 - t.id)
            }
            out[w] = lines.count
        }
        return out
    }

    /// Boxes (relative to the line) of every word occurrence, from each distinct reading.
    private func wordParts(_ t: TextTrack, _ words: [String]) -> [CGRect] {
        var out: [CGRect] = []
        for s in distinctReadings(t) {
            for range in wordRanges(in: s.string, words: words) {
                out.append(relativeBox(s, range: range, size: size) ?? whole)
            }
        }
        return out
    }
}

/// Face frames (if any) with the text boxes of the same decoded frames added.
public func withText(_ faces: [FrameFaces], text: ScreenText, mask: TextMask) -> [FrameFaces] {
    if faces.isEmpty {
        return text.times.indices.map {
            FrameFaces(time: text.times[$0], mosaic: [], kept: [], exact: mask.frames[$0], exactAnchors: mask.anchors[$0])
        }
    }
    return faces.map { f in
        let i = text.frameIndex(at: f.time)
        return FrameFaces(time: f.time, mosaic: f.mosaic, kept: f.kept, exact: mask.frames[i], exactAnchors: mask.anchors[i], stickers: f.stickers)
    }
}

// MARK: - Analysis

/// Decode every frame and recognize the text on screen. Recognition (~80–330 ms per frame)
/// runs when the picture changed, at most every `interval` seconds, and at least every
/// `recheck` seconds (a change too small for the thumbnail, such as one digit, is read then);
/// lines are followed between recognized frames by interpolation. With `workers` > 1 the
/// frames are read by that many worker processes (see TextWorkers.swift; the result is the
/// same). `progress` gets the number of frames done.
public func analyzeText(
    asset: AVURLAsset, info: VideoInfo, interval: Double = 0.1, recheck: Double = 1, workers: Int = 0,
    progress: (Int) -> Void
) throws -> ScreenText {
    let bounds = CGRect(origin: .zero, size: info.size)
    var builder = TrackBuilder(size: info.size)
    var times: [Double] = []
    let ctx = CIContext(options: [.cacheIntermediates: false])
    var lastRecognized = Int.min / 2
    var lastTime = -Double.infinity
    var lastThumb: [UInt8]?
    var lastLines: [(CGRect, VNRecognizedText)] = []
    var unchangedUntil: Int?  // last frame identical to the last recognized one

    var pool: TextWorkerPool?
    if workers > 1, let exe = Bundle.main.executableURL {
        pool = try TextWorkerPool(executable: exe, video: asset.url, count: workers)
    }
    defer { pool?.terminate() }
    // What to add to the tracks, in order. A reading done by a worker is applied when it
    // arrives and everything before it has been applied.
    enum Step { case pin(Int), read(frame: Int, job: Int, newSince: Int?) }
    var steps: [Step] = []
    var applied = 0  // steps[..<applied] are in the tracks
    var jobs = 0
    var ownReading: TextReading?  // read in this process (no workers)
    /// Applies the next step; false when it is a worker's reading that has not arrived.
    func step(blocking: Bool) throws -> Bool {
        switch steps[applied] {
        case .pin(let u):
            builder.add(frame: u, lines: lastLines, pin: true)
        case .read(let f, let job, let since):
            let reading: TextReading
            if let pool {
                guard let r = blocking ? try pool.wait(job) : try pool.take(job) else { return false }
                // The worker decodes the video on its own: make sure it read this very frame.
                guard r.frame == f, r.time == times[f] else {
                    throw ToolError("文字を読み取る処理が別のフレームを読みました（\(f) 番目のフレーム \(times[f]) 秒に \(r.frame) 番目 \(r.time) 秒）")
                }
                reading = r
            } else {
                reading = ownReading!
                ownReading = nil
            }
            lastLines = textLines(reading, bounds: bounds)
            // Read again only because time passed: a new line was there since the last
            // reading, too small a change to see (the picture looked the same).
            builder.add(frame: f, lines: lastLines, newSince: since)
        }
        applied += 1
        if applied == steps.count || applied >= 1024 {
            steps.removeFirst(applied)
            applied = 0
        }
        return true
    }
    func done(decoded: Int) -> Int {
        guard applied < steps.count else { return decoded }
        switch steps[applied] {
        case .pin(let u): return u
        case .read(let f, _, _): return f
        }
    }

    try forEachFrame(asset: asset, info: info) { i, t, image in
        times.append(t)
        let thumb = thumbnail(image, ctx)
        let unchanged = lastThumb.map { !differs($0, thumb) } ?? false
        if unchanged, t - lastTime < recheck {
            unchangedUntil = i
        } else if t - lastTime >= interval - 1e-6 {
            // Pin the lines where they were until the picture started to change.
            if let u = unchangedUntil, u > lastRecognized { steps.append(.pin(u)) }
            if let pool {
                // Keep a few readings per worker in flight; more would only pile up results.
                while steps.count - applied >= 8 * workers { _ = try step(blocking: true) }
                try pool.submit(job: jobs, frame: i)
            } else {
                ownReading = try recognizeText(image, frame: i, time: t)
            }
            steps.append(.read(frame: i, job: jobs, newSince: unchanged ? lastRecognized + 1 : nil))
            jobs += 1
            lastRecognized = i
            lastTime = t
            lastThumb = thumb
            unchangedUntil = nil
        }
        while applied < steps.count, try step(blocking: false) {}
        progress(done(decoded: i + 1))
    }
    if let u = unchangedUntil, u > lastRecognized { steps.append(.pin(u)) }
    pool?.finish()
    while applied < steps.count {
        _ = try step(blocking: true)
        progress(done(decoded: times.count))
    }
    progress(times.count)

    var tracks = builder.tracks
    for k in tracks.indices {
        tracks[k].text = mostCommonReading(tracks[k])
        tracks[k].parts = kindParts(tracks[k], size: info.size)
    }
    addContinuations(&tracks, times: times, extend: interval + 0.25, bounds: bounds, size: info.size)
    for k in tracks.indices { tracks[k].makeSteady(times: times) }
    // One entry per distinct text, in order of first appearance.
    var groups: [String: [Int]] = [:]
    var order: [String] = []
    for (k, t) in tracks.enumerated().sorted(by: { $0.element.first < $1.element.first }) {
        let key = normalizedForMatch(t.text)
        if groups[key] == nil { order.append(key) }
        groups[key, default: []].append(k)
    }
    let entries = order.enumerated().map { n, key -> TextEntry in
        let ks = groups[key]!
        return TextEntry(
            id: n + 1, text: tracks[ks[0]].text, trackIDs: ks.map { tracks[$0].id },
            firstFrame: ks.map { tracks[$0].first }.min()!,
            frameCount: ks.reduce(0) { $0 + tracks[$1].last - tracks[$1].first + 1 },
            kinds: Set(ks.flatMap { tracks[$0].parts.keys }))
    }
    // Lines fade in and out over a few frames that cannot be read yet: continue each line a
    // little longer than the time between two recognitions.
    return ScreenText(times: times, fps: info.fps, size: info.size, tracks: tracks, entries: entries, extend: interval + 0.25)
}

func recognizeText(_ image: CIImage, frame: Int, time: Double) throws -> TextReading {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate  // .fast does not read Japanese
    req.recognitionLanguages = ["ja-JP", "en-US"]
    req.usesLanguageCorrection = false  // keeps numbers and addresses as written
    try VNImageRequestHandler(ciImage: image, orientation: .up, options: [:]).perform([req])
    return TextReading(
        frame: frame, time: time, width: Int(image.extent.width), height: Int(image.extent.height), observations: req.results ?? [])
}

/// The lines of one reading: box in the frame and the best candidate.
private func textLines(_ r: TextReading, bounds: CGRect) -> [(CGRect, VNRecognizedText)] {
    r.observations.compactMap { o in
        guard let c = o.topCandidates(1).first, !c.string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let rect = VNImageRectForNormalizedRect(o.boundingBox, r.width, r.height).intersection(bounds)
        return rect.isEmpty ? nil : (rect, c)
    }
}

/// Small grayscale copy of a frame, to tell whether the picture changed.
private func thumbnail(_ image: CIImage, _ ctx: CIContext) -> [UInt8] {
    let width = 160
    let scale = CGFloat(width) / image.extent.width
    let height = max(1, Int((image.extent.height * scale).rounded()))
    let small = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
    var bytes = [UInt8](repeating: 0, count: width * height)
    ctx.render(small, toBitmap: &bytes, rowBytes: width, bounds: CGRect(x: 0, y: 0, width: width, height: height),
               format: .L8, colorSpace: nil)
    return bytes
}

private func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return true }
    var changed = 0
    for k in a.indices where abs(Int(a[k]) - Int(b[k])) > 12 {
        changed += 1
        if changed >= 2 { return true }
    }
    return false
}

/// Matches the lines of each recognized frame to the lines of earlier ones.
/// A line may be missed by up to `maxMissed` recognitions in a row (counted in recognitions,
/// not frames: a still picture is not recognized again, however long it lasts).
private struct TrackBuilder {
    let size: CGSize
    var maxMissed = 2
    var tracks: [TextTrack] = []
    private var pass = 0
    private var lastPass: [Int] = []  // per track

    init(size: CGSize) { self.size = size }

    /// `pin`: the lines of the last recognition again, at the last frame before the picture
    /// changed. Not a new recognition, so it does not count toward `maxMissed`.
    /// `newSince`: lines not matched to a track have been there since this frame.
    mutating func add(frame: Int, lines: [(CGRect, VNRecognizedText)], pin: Bool = false, newSince: Int? = nil) {
        if !pin { pass += 1 }
        let open = tracks.indices.filter { tracks[$0].last < frame && pass - lastPass[$0] <= maxMissed + 1 }
        let matches = matchLines(
            lines.map { ($0.0, $0.1.string) },
            to: open.map { (tracks[$0].samples.last!.rect, tracks[$0].samples.last!.string, tracks[$0].last) },
            frame: frame, size: size)
        var usedLines = Set<Int>()
        for (l, o) in matches {
            let k = open[o]
            usedLines.insert(l)
            let (rect, text) = lines[l]
            let isNew = !tracks[k].samples.contains { $0.string == text.string }
            tracks[k].samples.append(TextSample(frame: frame, rect: rect, string: text.string, text: isNew ? text : nil))
            lastPass[k] = pass
        }
        for (l, (rect, text)) in lines.enumerated() where !usedLines.contains(l) {
            var samples = [TextSample(frame: frame, rect: rect, string: text.string, text: text)]
            if let since = newSince, since < frame {
                samples.insert(TextSample(frame: since, rect: rect, string: text.string, text: nil), at: 0)
            }
            tracks.append(TextTrack(id: tracks.count, samples: samples))
            lastPass.append(pass)
        }
    }
}

/// Pairs the lines of one recognition with open tracks (line index → track index in
/// `tracks`): similar text (≥ 0.6) at a similar height, within 35 % of the picture. Pairs of
/// the same text (≥ 0.95) are made first. A pair of merely similar text must then move like
/// one of those (or not move): a line that could not be read for a moment was otherwise
/// joined to another line sharing part of its text far away ("https://example.com/…" to
/// "hanako.yamada@example.com" 660 px off), and the box swept across the screen between
/// the two places as a huge rectangle. Only text that appears once (in this recognition and
/// among the open tracks) sets the motion; it is compared per frame elapsed (a track may
/// come back after missed recognitions) and on the nearer edge (a line cut at the picture
/// edge or read with a word more changes its width). With no pair of the same text, any
/// similar pair is accepted as before.
func matchLines(
    _ lines: [(rect: CGRect, string: String)], to tracks: [(rect: CGRect, string: String, frame: Int)],
    frame: Int, size: CGSize
) -> [(line: Int, track: Int)] {
    let lineKeys = lines.map { normalizedForMatch($0.string) }
    let trackKeys = tracks.map { normalizedForMatch($0.string) }
    var pairs: [(cost: Double, sim: Double, line: Int, track: Int)] = []
    for (l, line) in lines.enumerated() {
        for (k, prev) in tracks.enumerated() {
            let ratio = line.rect.height / max(prev.rect.height, 1)
            guard ratio > 0.6 && ratio < 1.6 else { continue }
            let dx = abs(line.rect.midX - prev.rect.midX) / size.width
            let dy = abs(line.rect.midY - prev.rect.midY) / size.height
            guard dx < 0.35 && dy < 0.35 else { continue }
            let sim = similarity(lineKeys[l], trackKeys[k])
            guard sim >= 0.6 else { continue }
            pairs.append(((1 - sim) * 2 + dx + dy, sim, l, k))
        }
    }
    pairs.sort { $0.cost < $1.cost }
    var result: [(line: Int, track: Int)] = []
    var usedLines = Set<Int>(), usedTracks = Set<Int>()
    func take(_ p: (cost: Double, sim: Double, line: Int, track: Int)) {
        usedLines.insert(p.line)
        usedTracks.insert(p.track)
        result.append((p.line, p.track))
    }
    for p in pairs where p.sim >= 0.95 && !usedLines.contains(p.line) && !usedTracks.contains(p.track) { take(p) }
    // Motion per frame elapsed of the pairs of text that appears once.
    var lineCount: [String: Int] = [:], trackCount: [String: Int] = [:]
    for k in lineKeys { lineCount[k, default: 0] += 1 }
    for k in trackKeys { trackCount[k, default: 0] += 1 }
    func motion(_ l: Int, _ k: Int) -> (v: CGVector, frames: CGFloat) {
        let a = tracks[k].rect, b = lines[l].rect, n = CGFloat(max(1, frame - tracks[k].frame))
        return (CGVector(dx: (b.midX - a.midX) / n, dy: (b.midY - a.midY) / n), n)
    }
    func agrees(_ a: (v: CGVector, frames: CGFloat), _ b: (v: CGVector, frames: CGFloat), tolerance: CGFloat) -> Bool {
        let n = max(a.frames, b.frames)
        return abs(a.v.dx - b.v.dx) * n <= tolerance && abs(a.v.dy - b.v.dy) * n <= tolerance
    }
    var refs = result.indices.filter { lineCount[lineKeys[result[$0].line]] == 1 && trackCount[lineKeys[result[$0].line]] == 1 }
    // The same text may be on screen twice with one of them not read this time ("https://…"
    // in two messages): a pair of the same text that moves unlike every other one (and is
    // not still) is not trusted either. It is judged like a merely similar pair below.
    if refs.count >= 2 {
        let ms = refs.map { motion(result[$0].line, result[$0].track) }
        var rejected = Set<Int>()
        for (i, r) in refs.enumerated() {
            let tolerance = max(1.5 * tracks[result[r].track].rect.height, 0.02 * size.height)
            let still = abs(ms[i].v.dx) * ms[i].frames <= tolerance && abs(ms[i].v.dy) * ms[i].frames <= tolerance
            if !still && !ms.indices.contains(where: { $0 != i && agrees(ms[$0], ms[i], tolerance: tolerance) }) { rejected.insert(r) }
        }
        for r in rejected {
            usedLines.remove(result[r].line)
            usedTracks.remove(result[r].track)
        }
        refs = refs.filter { !rejected.contains($0) }
        let kept = Set(result.indices).subtracting(rejected)
        let order = result.indices.filter { kept.contains($0) }
        let remap = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        result = order.map { result[$0] }
        refs = refs.compactMap { remap[$0] }
    }
    let motions = refs.map { motion(result[$0].line, result[$0].track) }
    func movesLikeTheOthers(_ l: Int, _ k: Int) -> Bool {
        guard !motions.isEmpty else { return true }
        let a = tracks[k].rect, b = lines[l].rect, n = CGFloat(max(1, frame - tracks[k].frame))
        let tolerance = max(1.5 * a.height, 0.02 * size.height)
        let dxs = [b.minX - a.minX, b.maxX - a.maxX], dys = [b.minY - a.minY, b.maxY - a.maxY]
        if dxs.map(abs).min()! <= tolerance && dys.map(abs).min()! <= tolerance { return true }  // not moving
        return motions.contains { m in
            // Over more frames than the pair measured, the speed may have changed: more room.
            let t = tolerance * max(1, n / m.frames)
            return dxs.map { abs($0 - m.v.dx * n) }.min()! <= t && dys.map { abs($0 - m.v.dy * n) }.min()! <= t
        }
    }
    for p in pairs where !usedLines.contains(p.line) && !usedTracks.contains(p.track) && movesLikeTheOthers(p.line, p.track) {
        take(p)
    }
    return result
}

// MARK: - Finding personal information

private func mostCommonReading(_ t: TextTrack) -> String {
    var count: [String: Int] = [:]
    for s in t.samples { count[s.string, default: 0] += 1 }
    return count.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!.key
}

/// One sample per distinct reading of the line (readings differ when recognition errs), the
/// one with the recognized text (for the boxes of character ranges) when there is one.
private func distinctReadings(_ t: TextTrack) -> [TextSample] {
    var out: [TextSample] = []
    var at: [String: Int] = [:]
    for s in t.samples {
        if let i = at[s.string] {
            if out[i].text == nil, s.text != nil { out[i] = s }
        } else {
            at[s.string] = out.count
            out.append(s)
        }
    }
    return out
}

/// Parts of the line to hide per kind. Every reading is checked, so a line is covered for its
/// whole track when any frame read the information correctly.
private func kindParts(_ t: TextTrack, size: CGSize) -> [TextKind: [CGRect]] {
    var out: [TextKind: [CGRect]] = [:]
    for s in distinctReadings(t) {
        for (kind, range) in findKinds(in: s.string) {
            // No box for the range: hide the whole line rather than drop what was found.
            out[kind, default: []].append(relativeBox(s, range: range, size: size) ?? whole)
        }
    }
    return out.mapValues(mergeOverlapping)
}

/// Information often continues on the next line: an address (building name, room number)
/// that matches no pattern by itself, and an email address, URL or number wrapped at any
/// point ("hanako.yamada@" / "example.com", "example" / ".com/yamada", "sato.ichi" /
/// "ro@example.jp", "080-0000-" / "2222"). Only one line further, from lines whose own text
/// matched, so a long paragraph is not swallowed.
/// - the line below an address: the whole line
/// - two lines whose last and first words, joined, make an email address, URL or number
///   across the join: both words
private func addContinuations(_ tracks: inout [TextTrack], times: [Double], extend: Double, bounds: CGRect, size: CGSize) {
    let readings = tracks.map(distinctReadings)
    let lasts: [[(TextSample, Range<String.Index>)]] = readings.map { $0.compactMap { s in trailingWord(s.string).map { (s, $0) } } }
    let firsts: [[(TextSample, Range<String.Index>)]] = readings.map { $0.compactMap { s in leadingWord(s.string).map { (s, $0) } } }
    var changes: [(Int, TextKind, [CGRect])] = []
    for a in tracks.indices {
        let address = tracks[a].parts[.address] != nil
        guard address || !lasts[a].isEmpty else { continue }
        let (ta0, ta1) = (times[tracks[a].first] - extend, times[tracks[a].last] + extend)
        for b in tracks.indices where b != a && (address || !firsts[b].isEmpty) {
            // On screen at the same time (cheap, before comparing words or places).
            guard ta0 <= times[tracks[b].last], times[tracks[b].first] <= ta1 else { continue }
            if address, isLine(tracks[b], below: tracks[a], times: times, extend: extend, bounds: bounds) {
                changes.append((b, .address, [whole]))
            }
            guard !lasts[a].isEmpty, !firsts[b].isEmpty else { continue }
            var found: [(TextKind, TextSample, Range<String.Index>, TextSample, Range<String.Index>)] = []
            for (sa, ra) in lasts[a] {
                for (sb, rb) in firsts[b] {
                    if let kind = wrappedKind(String(sa.string[ra]), String(sb.string[rb])) { found.append((kind, sa, ra, sb, rb)) }
                }
            }
            guard !found.isEmpty, isLine(tracks[b], below: tracks[a], times: times, extend: extend, bounds: bounds)
            else { continue }
            for (kind, sa, ra, sb, rb) in found {
                changes.append((a, kind, [relativeBox(sa, range: ra, size: size) ?? whole]))
                changes.append((b, kind, [relativeBox(sb, range: rb, size: size) ?? whole]))
            }
        }
    }
    for (k, kind, parts) in changes where !parts.isEmpty {
        tracks[k].parts[kind] = mergeOverlapping((tracks[k].parts[kind] ?? []) + parts)
    }
}

/// Letters, digits, brackets and the symbols of addresses, URLs and numbers; "@" may have
/// spaces around it as read ("hanako.yamada @"), and so may groups of digits ("090 12").
private let wordChars = "(?:[A-Za-z0-9０-９._%+\\-‐－ー−/?=&#~:()（）\\[\\]]|\\s{0,2}[@＠]\\s{0,2}|(?<=[0-9０-９)）])\\s+(?=[0-9０-９(（]))+"

/// The first word of letters, digits and symbols of a line.
func leadingWord(_ s: String) -> Range<String.Index>? {
    guard let r = s.range(of: "^\\s*" + wordChars, options: .regularExpression) else { return nil }
    let start = s[r].firstIndex { !$0.isWhitespace } ?? r.lowerBound
    return start..<r.upperBound
}

/// The last word of letters, digits and symbols of a line.
func trailingWord(_ s: String) -> Range<String.Index>? {
    guard let r = s.range(of: wordChars + "\\s*$", options: .regularExpression) else { return nil }
    var end = r.upperBound
    while end > r.lowerBound, s[s.index(before: end)].isWhitespace { end = s.index(before: end) }
    return r.lowerBound..<end
}

/// The kind of information that `upper` (the end of a line) and `lower` (the start of the
/// next) make when joined, if a match crosses the join.
func wrappedKind(_ upper: String, _ lower: String) -> TextKind? {
    let u = upper.filter { !$0.isWhitespace }, l = lower.filter { !$0.isWhitespace }
    guard !u.isEmpty, !l.isEmpty else { return nil }
    let joined = u + l
    let join = joined.index(joined.startIndex, offsetBy: u.count)
    let crossing = findKinds(in: joined).filter { $0.1.lowerBound < join && $0.1.upperBound > join }.map(\.0)
    return [TextKind.email, .url, .number].first(where: crossing.contains)
}

/// `b` is the next line under `a`, at a frame where both are on screen (each continued
/// `extend` seconds, as when hidden): one where both were read if there is one, else one
/// where either was read (the other's place interpolated, or held where it was read: while
/// scrolling, two lines read once each at different frames are not matched). Overlapping `a`
/// sideways, with 1.5 lines to spare on either side (a wrapped value in a column, a centered
/// or right-aligned address). Two
/// lines that were never read together still match within `extend` (glare or a finger may
/// cover them in turn); a line of the next screen at the same place is hidden too then.
private func isLine(_ b: TextTrack, below a: TextTrack, times: [Double], extend: Double, bounds: CGRect) -> Bool {
    guard times[a.first] - extend <= times[b.last], times[b.first] - extend <= times[a.last] else { return false }
    let fa = Set(a.sampleFrames), fb = Set(b.sampleFrames)
    let both = fa.intersection(fb)
    for f in both.sorted() + fa.symmetricDifference(fb).sorted() {
        guard let ra = a.rect(atFrame: f, times: times, extend: extend, bounds: bounds),
              let rb = b.rect(atFrame: f, times: times, extend: extend, bounds: bounds)
        else { continue }
        let h = ra.height
        let gap = ra.minY - rb.maxY  // Core Image coordinates: y grows upward
        let column = rb.maxX > ra.minX - 1.5 * h && rb.minX < ra.maxX + 1.5 * h
        if gap > -0.3 * h, gap < 0.8 * h, column, rb.height > 0.7 * h, rb.height < 1.4 * h {
            return true
        }
    }
    return false
}

private let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

/// Box of a character range relative to the line box.
private func relativeBox(_ s: TextSample, range: Range<String.Index>, size: CGSize) -> CGRect? {
    guard let box = try? s.text?.boundingBox(for: range) else { return nil }
    let b = VNImageRectForNormalizedRect(box.boundingBox, Int(size.width), Int(size.height))
    let r = s.rect
    guard r.width > 0, r.height > 0, !b.isEmpty else { return nil }
    // Vertically the whole line; horizontally the range (Vision's range boxes are often short).
    let x0 = max(0, (b.minX - r.minX) / r.width), x1 = min(1, (b.maxX - r.minX) / r.width)
    guard x1 > x0 else { return nil }
    return CGRect(x: x0, y: 0, width: x1 - x0, height: 1)
}

func mergeOverlapping(_ rects: [CGRect]) -> [CGRect] {
    var out: [CGRect] = []
    for r in rects.sorted(by: { $0.minX < $1.minX }) {
        if let i = out.firstIndex(where: { $0.intersects(r) || $0.maxX >= r.minX - 0.01 && $0.minX <= r.maxX }) {
            out[i] = out[i].union(r)
        } else {
            out.append(r)
        }
    }
    return out
}

private let patterns: [(TextKind, NSRegularExpression)] = {
    let digit = "[0-9０-９]"
    let sep = "[\\-‐－ーｰ−\\s()（）.．]"
    let defs: [(TextKind, String)] = [
        (.email, "[A-Za-z0-9._%+\\-]+\\s{0,2}[@＠]\\s{0,2}[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}"),
        (.url, "(?i)(?:https?://|www\\.)[^\\s　]+"),
        (.url, "(?i)[A-Za-z0-9\\-]+(?:\\.[A-Za-z0-9\\-]+)*\\.(?:com|net|org|jp|io|me|info|biz|co|app|dev|ee|ly|gl|tokyo|uk|us|tv|ai|gg|cc|to|fm|so|xyz|site|online|shop|link|page)(?![A-Za-z0-9\\-])(?:/[^\\s　]*)?"),
        (.number, "(?:(?<![A-Za-zＡ-Ｚａ-ｚ])[A-Za-zＡ-Ｚａ-ｚ]{1,4}[\\-‐－]?)?\(digit)(?:\(digit)|\(sep)){4,}\(digit)"),
        (.address, "〒\\s?\(digit){3}[\\-‐－ーｰ−]\(digit){4}|(?<![0-9０-９\\-‐－ーｰ−])\(digit){3}[\\-‐－ーｰ−]\(digit){4}(?![0-9０-９\\-‐－ーｰ−])"),
        (.address, "(?:東京都|北海道|(?:京都|大阪)府|[^\\s　、。]{2,3}県)[^\\s　、。]*"),
        (.address, "[^\\s　、。]{1,6}[市区町村郡][^\\s　、。]*[0-9０-９一二三四五六七八九十丁目番地号][^\\s　、。]*"),
    ]
    return defs.map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }
}()

/// Personal information in one line: (kind, range).
func findKinds(in s: String) -> [(TextKind, Range<String.Index>)] {
    let ns = NSRange(s.startIndex..., in: s)
    var out: [(TextKind, Range<String.Index>)] = []
    for (kind, re) in patterns {
        for m in re.matches(in: s, range: ns) {
            guard let r = Range(m.range, in: s) else { continue }
            if kind == .number && s[r].filter(\.isNumber).count < 6 { continue }
            // The rest of the line after the start of an address is still the address
            // (ward, town, building); the patterns stop at the first unusual character.
            out.append((kind, kind == .address ? r.lowerBound..<s.endIndex : r))
        }
    }
    out += nameRanges(in: s).map { (.name, $0) }
    return out
}

/// Ranges of `words` (normalized with `normalizedForMatch`) in `s`, ignoring spaces, letter
/// case and full/half width (recognition drops or adds spaces).
func wordRanges(in s: String, words: [String]) -> [Range<String.Index>] {
    var chars: [Character] = []
    var index: [String.Index] = []
    for i in s.indices where !s[i].isWhitespace {
        // One character may unify into several ("㈱" → "(株)"); each points back to it.
        for c in String(s[i]).precomposedStringWithCompatibilityMapping.lowercased() where !c.isWhitespace {
            chars.append(c)
            index.append(i)
        }
    }
    var out: [Range<String.Index>] = []
    for w in words {
        let wc = Array(w)
        guard !wc.isEmpty, wc.count <= chars.count else { continue }
        var k = 0
        while k + wc.count <= chars.count {
            if Array(chars[k..<(k + wc.count)]) == wc {
                out.append(index[k]..<withFollowingName(s, after: s.index(after: index[k + wc.count - 1])))
                k += wc.count
            } else {
                k += 1
            }
        }
    }
    return out
}

/// A family name is usually followed by the given name ("鈴木 次郎", "佐藤一郎"): extend a word
/// over an optional space and up to 4 kanji or katakana. Hiragana (particles, さん) stops it.
private func withFollowingName(_ s: String, after end: String.Index) -> String.Index {
    var i = end
    while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
    var out = end, n = 0
    while i < s.endIndex, n < 4, isNameCharacter(s[i]) {
        i = s.index(after: i)
        out = i
        n += 1
    }
    return out
}

private func isNameCharacter(_ c: Character) -> Bool {
    guard let u = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
    switch u.value {
    case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x3005: return true  // kanji, 々
    case 0x30A1...0x30FA, 0x30FC: return true  // katakana, ー
    default: return false
    }
}

extension Array {
    /// First index whose element satisfies `pred` (the array is sorted so that `pred` is
    /// false, then true).
    func partitionIndex(_ pred: (Element) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if pred(self[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}

/// For comparing text: compatibility forms unified (full-width letters and digits), spaces
/// removed, lower case.
func normalizedForMatch(_ s: String) -> String {
    String(s.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }).lowercased()
}

/// 1 − edit distance / longer length.
private func similarity(_ a: String, _ b: String) -> Double {
    if a == b { return 1 }
    let x = Array(a), y = Array(b)
    guard !x.isEmpty, !y.isEmpty else { return 0 }
    var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
    for i in 1...x.count {
        cur[0] = i
        for j in 1...y.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
        }
        swap(&prev, &cur)
    }
    return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
}

// MARK: - Self check (see SelfCheck.swift)

/// Synthetic tracks for the rules of `mask` and `addContinuations` (no recognition needed).
func selfCheckMask() -> [String] {
    var failures: [String] = []
    func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
    let size = CGSize(width: 1000, height: 1000)
    let bounds = CGRect(origin: .zero, size: size)
    let times = (0..<120).map { Double($0) / 30 }
    func track(_ id: Int, _ frames: ClosedRange<Int>, y: CGFloat, _ text: String, x: CGFloat = 100) -> TextTrack {
        var t = TextTrack(id: id, samples: [frames.lowerBound, frames.upperBound].map {
            TextSample(frame: $0, rect: CGRect(x: x, y: y, width: 600, height: 40), string: text, text: nil)
        })
        t.text = text
        return t
    }
    func screen(_ tracks: [TextTrack]) -> ScreenText {
        let entries = tracks.map {
            TextEntry(id: $0.id + 1, text: $0.text, trackIDs: [$0.id], firstFrame: $0.first,
                      frameCount: $0.last - $0.first + 1, kinds: Set($0.parts.keys))
        }
        return ScreenText(times: times, fps: 30, size: size, tracks: tracks, entries: entries, extend: 0.1)
    }
    let all = Set(TextKind.allCases)
    let phone = CGRect(x: 0.1, y: 0, width: 0.3, height: 1), link = CGRect(x: 0.6, y: 0, width: 0.3, height: 1)

    // A chain read differently: misread first (nothing found), then the phone number, then a
    // misread with only the URL. Every track gets both parts, and the gaps stay hidden.
    var a = track(0, 0...10, y: 500, "電話 O9O-1234-5678 https://x.jp")
    var b = track(1, 20...30, y: 500, "電話 090-1234-5678 https://x.jp")
    var c = track(2, 40...50, y: 500, "電話 O9O-1234-S678 https://x.jp")
    a.parts = [:]
    b.parts = [.number: [phone], .url: [link]]
    c.parts = [.url: [link]]
    let m = screen([a, b, c]).mask(TextMaskOptions(kinds: all, words: [], lines: []))
    expect(m.frames[5].count == 2, "chain: misread first track gets both parts (\(m.frames[5].count))")
    expect(m.frames[45].count == 2, "chain: later track keeps the earlier parts (\(m.frames[45].count))")
    expect(!m.frames[15].isEmpty && !m.frames[35].isEmpty, "chain: gaps hidden")
    expect(m.hidden == [1, 2, 3], "chain: all entries hidden (\(m.hidden.sorted()))")

    // Not a continuation: other text at the place.
    var e = track(0, 0...10, y: 500, "電話 090-1234-5678")
    e.parts = [.number: [phone]]
    var f = track(1, 20...30, y: 500, "まったく別の文章がここに出ています")
    f.parts = [:]
    let m3 = screen([e, f]).mask(TextMaskOptions(kinds: all, words: [], lines: []))
    expect(m3.frames[25].isEmpty, "chain: other text is not hidden")

    // An address continues on the line below, also while scrolling with the two lines read at
    // different frames. (Wrapped URLs need recognized text with boxes: checked on screen.mov.)
    var addr = TextTrack(id: 0, samples: [
        TextSample(frame: 0, rect: CGRect(x: 100, y: 600, width: 600, height: 40), string: "東京都みほん区", text: nil),
        TextSample(frame: 30, rect: CGRect(x: 100, y: 300, width: 600, height: 40), string: "東京都みほん区", text: nil),
    ])
    addr.parts = [.address: [CGRect(x: 0, y: 0, width: 1, height: 1)]]
    let below = TextTrack(id: 1, samples: [
        TextSample(frame: 3, rect: CGRect(x: 100, y: 540, width: 500, height: 40), string: "テストハイツ402", text: nil),
        TextSample(frame: 27, rect: CGRect(x: 100, y: 270, width: 500, height: 40), string: "テストハイツ402", text: nil),
    ])
    var tracks = [addr, below]
    addContinuations(&tracks, times: times, extend: 0.1, bounds: bounds, size: size)
    expect(tracks[1].parts[.address] != nil, "address: the line below is hidden")
    // Each line read once, at different frames (glare moving over a filmed screen).
    var once = TextTrack(id: 0, samples: [
        TextSample(frame: 10, rect: CGRect(x: 100, y: 600, width: 600, height: 40), string: "東京都みほん区", text: nil)])
    once.parts = [.address: [CGRect(x: 0, y: 0, width: 1, height: 1)]]
    let onceBelow = TextTrack(id: 1, samples: [
        TextSample(frame: 13, rect: CGRect(x: 100, y: 550, width: 500, height: 40), string: "テストハイツ402", text: nil)])
    var tracks2 = [once, onceBelow]
    addContinuations(&tracks2, times: times, extend: 0.35, bounds: bounds, size: size)
    expect(tracks2[1].parts[.address] != nil, "address: lines read once at different frames")
    // Two lines shown together but read at different frames (glare, a finger), each read
    // twice: still the line below.
    var upper = track(0, 10...11, y: 600, "東京都みほん区")
    upper.parts = [.address: [whole]]
    var tracks3 = [upper, track(1, 12...13, y: 555, "テストハイツ402")]
    addContinuations(&tracks3, times: times, extend: 0.35, bounds: bounds, size: size)
    expect(tracks3[1].parts[.address] != nil, "address: lines shown together, read at different frames")
    // A centered address (an order screen): the shorter line below is not left-aligned.
    var centered = [upper, track(1, 10...11, y: 555, "テストハイツ402", x: 300)]
    addContinuations(&centered, times: times, extend: 0.35, bounds: bounds, size: size)
    expect(centered[1].parts[.address] != nil, "address: centered line below")
    // A long line under a short address (a centered or right-aligned value column), and a
    // line starting a little right of a short one.
    var short = track(0, 10...11, y: 600, "東京都渋谷区", x: 300)
    short.parts = [.address: [whole]]
    var longBelow = [short, track(1, 10...11, y: 555, "神宮前1-2-3 テストハイツ402号室", x: 100)]
    addContinuations(&longBelow, times: times, extend: 0.35, bounds: bounds, size: size)
    expect(longBelow[1].parts[.address] != nil, "address: longer centered line below")
    var tiny = TextTrack(id: 0, samples: [10, 11].map {
        TextSample(frame: $0, rect: CGRect(x: 100, y: 600, width: 30, height: 40), string: "東京都", text: nil)
    })
    tiny.parts = [.address: [whole]]
    var indentedBelow = [tiny, track(1, 10...11, y: 555, "テストハイツ402", x: 140)]
    addContinuations(&indentedBelow, times: times, extend: 0.35, bounds: bounds, size: size)
    expect(indentedBelow[1].parts[.address] != nil, "address: line below starting right of a short one")
    // A short address with the line below starting a little right of its end.
    var shortRight = TextTrack(id: 0, samples: [10, 11].map {
        TextSample(frame: $0, rect: CGRect(x: 100, y: 600, width: 100, height: 40), string: "東京都", text: nil)
    })
    shortRight.parts = [.address: [whole]]
    var rightBelow = [shortRight, track(1, 10...11, y: 555, "テストハイツ402", x: 210)]
    addContinuations(&rightBelow, times: times, extend: 0.35, bounds: bounds, size: size)
    expect(rightBelow[1].parts[.address] != nil, "address: line below starting just right of a short one")
    // Wrapped email address, URL and number through addContinuations (no recognized text:
    // the words are hidden with whole-line boxes).
    for (u, l) in [("共有先は example", ".com/private/yamada"), ("電話は 080-0000-", "2222 です"),
                   ("メールは sato.ichi", "ro@example.jp です")] {
        var w = [track(0, 0...10, y: 600, u), track(1, 0...10, y: 555, l, x: 140)]
        addContinuations(&w, times: times, extend: 0.35, bounds: bounds, size: size)
        expect(!w[0].parts.isEmpty && !w[1].parts.isEmpty, "wrap through addContinuations: \(u) / \(l)")
    }
    var plain = [track(0, 0...10, y: 600, "よろしくお願いします"), track(1, 0...10, y: 555, "はい")]
    addContinuations(&plain, times: times, extend: 0.35, bounds: bounds, size: size)
    expect(plain[0].parts.isEmpty && plain[1].parts.isEmpty, "wrap: ordinary lines are not hidden")

    // Steady boxes: a line read every 3 frames while scrolling 2 px a frame, its box off by a
    // few pixels each time, then speeding up, then a jump the tracker joined. What is hidden
    // must still contain what the recognized boxes alone hid (interpolated, continued before
    // and after, with the old margins), at every frame; and the blocks must move with the line.
    let jit: [CGFloat] = [0, 2, -2, 1, -1, 2, 0, -2, 1, -1, 0, 2, -1]
    let jitH: [CGFloat] = [0, 3, -3, 2, -2, 0, 3, -1, -3, 1, 2, -2, 0]
    let sampleFrames = Array(stride(from: 6, through: 96, by: 3))
    var scroll = TextTrack(id: 0, samples: sampleFrames.enumerated().map { i, f in
        var y = 200 + 2 * CGFloat(f) + jit[i % jit.count]
        if f > 48 { y += 0.04 * CGFloat((f - 48) * (f - 48)) }
        if f >= 75 { y += 160 }
        return TextSample(frame: f, rect: CGRect(x: 100 + jit[(i + 4) % jit.count], y: y, width: 600, height: 40 + jitH[i % jitH.count]),
                          string: "090-1234-5678", text: nil)
    })
    scroll.text = "090-1234-5678"
    scroll.parts = [.number: [phone]]
    let extendS = 0.1
    func oldHidden(_ f: Int) -> CGRect? {  // the recognized boxes and margins alone
        let sm = scroll.samples, t = times[f]
        var line: CGRect, margin = CGSize.zero
        if f < sm[0].frame {
            guard times[sm[0].frame] - t <= extendS + 1e-6 else { return nil }
            let k = min(1.5, CGFloat((times[sm[0].frame] - t) / (times[sm[1].frame] - times[sm[0].frame])))
            line = lerp(sm[0].rect, sm[1].rect, -k).union(sm[0].rect).intersection(bounds)
        } else if f > sm[sm.count - 1].frame {
            let a = sm[sm.count - 2], b = sm[sm.count - 1]
            guard t - times[b.frame] <= extendS + 1e-6 else { return nil }
            let k = min(1.5, CGFloat((t - times[b.frame]) / (times[b.frame] - times[a.frame])))
            line = lerp(b.rect, a.rect, -k).union(b.rect).intersection(bounds)
        } else if let b = sm.firstIndex(where: { $0.frame >= f }), sm[b].frame != f, b > 0 {
            let ra = sm[b - 1].rect, rb = sm[b].rect
            let u = (t - times[sm[b - 1].frame]) / (times[sm[b].frame] - times[sm[b - 1].frame])
            line = lerp(ra, rb, CGFloat(u))
            let spread = CGFloat(1.6 * u * (1 - u))
            margin = CGSize(width: abs(rb.midX - ra.midX) * spread, height: abs(rb.midY - ra.midY) * spread)
        } else {
            line = sm.first { $0.frame == f }!.rect
        }
        let h = line.height
        let r = CGRect(x: line.minX + phone.minX * line.width, y: line.minY + phone.minY * line.height,
                       width: phone.width * line.width, height: phone.height * line.height)
        return r.insetBy(dx: -h * 0.35 - margin.width, dy: -h * 0.3 - margin.height).intersection(bounds)
    }
    scroll.makeSteady(times: times)
    expect(!scroll.steady.isEmpty && scroll.steady.contains { $0.slack != .zero }, "steady: boxes are fitted")
    let sm = screen([scroll]).mask(TextMaskOptions(kinds: all, words: [], lines: []))
    for f in times.indices {
        guard let old = oldHidden(f), !old.isEmpty else { continue }
        let new = sm.frames[f]
        expect(new.contains { $0.insetBy(dx: -0.01, dy: -0.01).contains(old) },
               "steady: frame \(f) hides what the recognized boxes hid (\(old) in \(new))")
        expect(sm.anchors[f].count == new.count, "steady: an anchor for every box at frame \(f)")
    }
    let ys = (8...44).compactMap { sm.anchors[$0].first?.y }
    let steps = zip(ys, ys.dropFirst()).map { $1 - $0 }
    expect(ys.count == 37 && steps.allSatisfy { abs($0 - 2) <= 1 }, "steady: blocks move with the line (steps \(steps))")

    // Matching lines to tracks while scrolling 26 px per recognition (3 frames).
    let scr = CGSize(width: 900, height: 1900)
    func box(_ y: CGFloat, x: CGFloat = 60, w: CGFloat = 580) -> CGRect { CGRect(x: x, y: y, width: w, height: 44) }
    let body = ["おはようございます", "送り先の住所は", "ありがとうございます", "了解です"]
    var prevTracks = body.enumerated().map { (box(400 + CGFloat($0) * 150), $1, 60) }
    prevTracks.append((box(1800), "山田 花子", 60))  // fixed header
    prevTracks.append((box(500, x: 240, w: 600), "https://example.com/share/abc123", 60))
    // The URL is not read this time; the same URL in another message 660 px away is.
    var now = body.enumerated().map { (box(426 + CGFloat($0) * 150), $1) }
    now.append((box(1800), "山田 花子"))
    now.append((box(1160), "https://example.com/share/abc123"))
    var got = matchLines(now, to: prevTracks, frame: 63, size: scr)
    expect(!got.contains { $0.line == 5 }, "match: the same text far away, moving unlike the rest, is not joined")
    expect(got.count == 5, "match: the other lines are joined (\(got.count))")
    // A line misread (similar text) is joined when it moves with the rest, not when it jumps.
    now[1] = (box(576), "送り先の住所わ")
    got = matchLines(now, to: prevTracks, frame: 63, size: scr)
    expect(got.contains { $0.line == 1 && $0.track == 1 }, "match: misread line moving with the rest is joined")
    now[1] = (box(1176), "送り先の住所わ")
    got = matchLines(now, to: prevTracks, frame: 63, size: scr)
    expect(!got.contains { $0.line == 1 }, "match: misread line far off is not joined")
    // Back after two missed recognitions: three times the motion.
    var late = prevTracks
    late[2] = (box(400 + 2 * 150 - 52), "ありがとうございます", 54)
    now[1] = (box(576), "送り先の住所は")
    now[2] = (box(726), "ありがとうごさいます")
    got = matchLines(now, to: late, frame: 63, size: scr)
    expect(got.contains { $0.line == 2 && $0.track == 2 }, "match: a line back after missed recognitions is joined")
    // A line cut at the picture edge (narrower) moving sideways with the rest.
    let side = [(box(400, x: 100), "おはようございます", 60), (box(600, x: 100), "ありがとうございます", 60),
                (box(800, x: 100, w: 700), "電話は 090-1234-5678 です", 60)]
    let sideNow = [(box(400, x: 40), "おはようございます"), (box(600, x: 40), "ありがとうございます"),
                   (box(800, x: 40, w: 500), "電話は 090-1234-56")]
    got = matchLines(sideNow, to: side, frame: 63, size: scr)
    expect(got.contains { $0.line == 2 && $0.track == 2 }, "match: a line cut at the edge is joined by its other edge")
    // No pair of the same text: similar text is joined as before.
    got = matchLines([(box(1000), "送り先の住所わ")], to: [(box(400), "送り先の住所は", 60)], frame: 63, size: scr)
    expect(got.count == 1, "match: without a reference, a similar line is joined as before")
    return failures
}
