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
    /// QR codes (a LINE friend code, a payment code…): found as codes, not as text.
    case qr
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
    /// The four corners Vision found (top left, top right, bottom right, bottom left of the
    /// code or the line), relative to `rect` (0...1 across it). Nil for a line cut at the edge
    /// of the picture (its corners lie outside `rect`).
    var corners: [CGPoint]? = nil

    /// Height of the line itself: across its corners (the larger side, for a line seen in
    /// perspective), else its box. On a slanted line the box is far higher than the line, and
    /// comparing boxes put a line read in part (shorter, so a lower box) apart from itself.
    var lineHeight: CGFloat {
        guard let c = corners, c.count == 4 else { return rect.height }
        let q = place(c, in: rect)
        return max(hypot(q[0].x - q[3].x, q[0].y - q[3].y), hypot(q[1].x - q[2].x, q[1].y - q[2].y))
    }
}

/// One line followed across frames (it may scroll).
public struct TextTrack: Sendable {
    public let id: Int
    var samples: [TextSample]
    /// Readings that do not place the line: Vision gave its text with another line's box
    /// (`droppingMixedUpReadings`). Their text still counts (kinds, words, continuations).
    var offPlace: [TextSample] = []
    /// Parts to hide per kind, relative to the line box (0...1).
    var parts: [TextKind: [CGRect]] = [:]
    /// The most common reading of the line.
    public internal(set) var text = ""
    /// A QR code followed like a line (its samples read `codeText`), not text.
    var isCode = false

    /// Frames where the line was recognized (or pinned while the picture did not change).
    public var sampleFrames: [Int] { samples.map(\.frame) }
    var first: Int { samples.first!.frame }
    var last: Int { samples.last!.frame }

    /// Line boxes at the recognized frames with the jitter of recognition taken out, and how
    /// far the recognized box may lie outside each (see `makeSteady`). Empty: the boxes as read.
    var steady: [(rect: CGRect, slack: CGSize)] = []

    /// A code's corners (relative to its box, as `TextSample.corners`) at the recognized
    /// frames, averaged over `makeSteady`'s window: the corners Vision finds wander a pixel or
    /// two, which a mosaic cut along them would show as a shaking edge.
    var steadyCorners: [[CGPoint]] = []

    /// The slant of the line (radians, Core Image coordinates: positive turns it
    /// counterclockwise) at the recognized frames, averaged as `makeSteady` does. Empty for an
    /// upright line, and for one whose slant is not known well enough: it is then hidden by
    /// its upright box, as before. See `measureTilt`.
    var tilts: [CGFloat] = []
    /// How far a reading in the window of each of `tilts` is from it (at least `minTiltSlack`):
    /// the slant may be off by as much, which turns the ends of a long line off the slanted
    /// box; that much room is added across the line (see `SlantedLine.quad`).
    var tiltSlacks: [CGFloat] = []
    /// The line's own height at the recognized frames (`TextSample.lineHeight`, averaged as
    /// `tilts`). The height found again from the box and the slant shrinks by about the
    /// length × the error of the slant (9 px for 0.5° on a line of 800 px), so the larger of
    /// the two is used.
    var lineHeights: [CGFloat] = []
    /// Hidden by slanted boxes along the line (`SlantedLine`), with parts measured along it.
    var isTilted: Bool { !tilts.isEmpty }

    /// A line on a screen filmed at an angle is slanted, and its upright box also covers the
    /// lines above and below it. Vision gives each line's corners along the slant, but for a
    /// short line (2 characters) it gives the upright box (0°), so a slant is only taken from
    /// lines at least 2.5 times as long as high. A track is slanted when most of its readings
    /// give a slant, of 2° to 35° (the median): below 2° the upright box is as good; beyond 35°
    /// the line cannot be found again from its box (see `slantedBox`).
    mutating func measureTilt(times: [Double], window: Double = 0.25) {
        tilts = []
        tiltSlacks = []
        lineHeights = []
        guard !isCode else { return }
        // Along the middle of the line, as parts are measured (`relativeBox(along:)`).
        let measured: [CGFloat?] = samples.map { s in
            guard let c = s.corners, c.count == 4 else { return nil }
            let q = place(c, in: s.rect)
            let start = CGPoint(x: (q[0].x + q[3].x) / 2, y: (q[0].y + q[3].y) / 2)
            let end = CGPoint(x: (q[1].x + q[2].x) / 2, y: (q[1].y + q[2].y) / 2)
            let height = s.lineHeight
            guard height > 0, hypot(end.x - start.x, end.y - start.y) >= 2.5 * height else { return nil }
            return atan2(end.y - start.y, end.x - start.x)
        }
        let known = measured.compactMap { $0 }
        guard !known.isEmpty, known.count * 2 >= samples.count else { return }
        let median = known.sorted()[known.count / 2]
        guard abs(median) >= minTilt, abs(median) <= maxTilt else { return }
        let ts = samples.map { times[$0.frame] }
        func within(_ k: Int) -> [Int] { samples.indices.filter { abs(ts[$0] - ts[k]) <= window + 1e-6 } }
        tilts = samples.indices.map { k in
            let near = within(k).compactMap { measured[$0] }
            return near.isEmpty ? median : near.reduce(0, +) / CGFloat(near.count)
        }
        tiltSlacks = samples.indices.map { k in
            max(minTiltSlack, within(k).compactMap { measured[$0].map { abs($0 - tilts[k]) } }.max() ?? abs(median - tilts[k]))
        }
        lineHeights = samples.indices.map { k in
            let near = within(k).filter { measured[$0] != nil }.map { samples[$0].lineHeight }
            return near.isEmpty ? 0 : near.reduce(0, +) / CGFloat(near.count)
        }
    }

    /// The slant at frame `f`: interpolated between recognized frames, the first or last one's
    /// before and after them.
    func tilt(atFrame f: Int, times: [Double]) -> CGFloat {
        guard isTilted else { return 0 }
        if f <= first { return tilts[0] }
        if f >= last { return tilts[tilts.count - 1] }
        let lo = sampleIndex(atOrAfter: f)
        guard samples[lo].frame != f, lo > 0 else { return tilts[lo] }
        let u = CGFloat((times[f] - times[samples[lo - 1].frame]) / max(times[samples[lo].frame] - times[samples[lo - 1].frame], 1e-6))
        return tilts[lo - 1] + (tilts[lo] - tilts[lo - 1]) * u
    }

    /// `tiltSlacks` and `lineHeights` at frame `f`, as `tilt`. Before the first and after the
    /// last recognized frame the slant is held while the line may still be turning: the
    /// change between the last two readings, as far as the line is continued, is added.
    func tiltSlack(atFrame f: Int, times: [Double]) -> CGFloat {
        guard isTilted else { return 0 }
        if f < first || f > last {
            let k = f < first ? 0 : samples.count - 1
            // Read once: no turn measured, and no interval to continue it by.
            guard samples.count > 1 else { return tiltSlacks[k] }
            let j = f < first ? 1 : samples.count - 2
            return tiltSlacks[k] + abs(tilts[k] - tilts[j]) * extensionFactor(atFrame: f, times: times)
        }
        let lo = sampleIndex(atOrAfter: f)
        return samples[lo].frame == f || lo == 0 ? tiltSlacks[lo] : max(tiltSlacks[lo - 1], tiltSlacks[lo])
    }

    func lineHeight(atFrame f: Int, times: [Double]) -> CGFloat {
        guard isTilted else { return 0 }
        if f <= first { return lineHeights[0] }
        if f >= last { return lineHeights[lineHeights.count - 1] }
        let lo = sampleIndex(atOrAfter: f)
        return samples[lo].frame == f || lo == 0 ? lineHeights[lo] : max(lineHeights[lo - 1], lineHeights[lo])
    }

    /// The slanted line at frame `f`, from the boxes `line` would give: the line box, and
    /// before the first and after the last recognized frame both where it was seen and where
    /// its motion takes it (`line` gives their union, from which no slanted line can be found;
    /// the two are covered as one by `SlantedLine.quad`). Also the boxes, to tell a line cut
    /// at the picture's edge. Nil where `line` gives nothing or no slanted line has the box.
    func slantedLines(atFrame f: Int, times: [Double], extend: Double) -> (lines: [SlantedLine], boxes: [CGRect])? {
        var boxes: [CGRect]
        if f < first || f > last {
            let before = f < first
            guard (before ? times[first] - times[f] : times[f] - times[last]) <= extend + 1e-6 else { return nil }
            let k = before ? 0 : samples.count - 1
            boxes = [box(k)]
            if samples.count > 1 { boxes.append(lerp(box(k), box(before ? 1 : samples.count - 2), -extensionFactor(atFrame: f, times: times))) }
        } else {
            guard let r = line(atFrame: f, times: times, extend: extend, bounds: .infinite)?.rect else { return nil }
            boxes = [r]
        }
        let angle = tilt(atFrame: f, times: times), height = lineHeight(atFrame: f, times: times)
        let lines = boxes.compactMap { SlantedLine(box: $0, angle: angle, height: height) }
        return lines.count == boxes.count ? (lines, boxes) : nil
    }

    private func box(_ k: Int) -> CGRect { steady.isEmpty ? samples[k].rect : steady[k].rect }
    private func slack(_ k: Int) -> CGSize { steady.isEmpty ? .zero : steady[k].slack }

    /// Recognition puts the box of the same line a few pixels off every time (±2 px in place
    /// and ±3 px in height were measured), and the mosaic drawn from it shook while the screen
    /// scrolled. Each edge is fitted with straight-line motion over the recognized frames
    /// within `window` seconds; the largest distance from the fit to a recognized edge in that
    /// window is the slack, added to what is hidden (see `motionMargin`), so the hidden box
    /// contains the one drawn from the recognized boxes. Where the fit is off by more than the
    /// line height (a jump the tracker joined, a sudden stop), the recognized box is used.
    /// Made after the line-below and wrap checks, which keep using the recognized boxes, and
    /// after `measureTilt`.
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
            // Measured on the line's own height: a slanted line's box is many times higher.
            let limit = isTilted ? max(lineHeights[k], 1) : raw.height
            guard max(slack.width, slack.height) <= limit, x1.value > x0.value, y1.value > y0.value else { return (raw, .zero) }
            return (CGRect(x: x0.value, y: y0.value, width: x1.value - x0.value, height: y1.value - y0.value), slack)
        }
        guard isCode, samples.allSatisfy({ $0.corners?.count == 4 }) else { return }
        // Vision names the corners after the code's own top left: turned by a quarter, read
        // mirrored or as another code, the same corner comes under another name, and averaging
        // or interpolating by name would shrink the quad. Each reading is matched to the one
        // before it first.
        var aligned = [samples[0].corners!]
        for k in samples.indices.dropFirst() { aligned.append(alignedCorners(samples[k].corners!, to: aligned[k - 1])) }
        steadyCorners = samples.indices.map { k in
            let near = samples.indices.filter { abs(ts[$0] - ts[k]) <= window + 1e-6 }
            return (0..<4).map { c in
                CGPoint(x: near.reduce(0) { $0 + aligned[$1][c].x } / CGFloat(near.count),
                        y: near.reduce(0) { $0 + aligned[$1][c].y } / CGFloat(near.count))
            }
        }
    }

    /// A code's corners at frame `f` (pixels), as `line` places its box: interpolated between
    /// recognized frames, and before the first and after the last one both where it was last
    /// seen and where its motion takes it (the box `line` gives there is the union of the two,
    /// which would stretch the code). Across a cut between two recognized frames the code
    /// jumps instead: where it was before the cut, where it is after. Nil for text and outside
    /// the frames `line` covers.
    func codeQuads(atFrame f: Int, times: [Double], extend: Double, cuts: [Int] = []) -> [[CGPoint]]? {
        guard isCode, steadyCorners.count == samples.count else { return nil }
        let t = times[f]
        if f < first || f > last {
            let before = f < first
            guard (before ? times[first] - t : t - times[last]) <= extend + 1e-6 else { return nil }
            let k = before ? 0 : samples.count - 1
            let end = place(steadyCorners[k], in: box(k))
            guard samples.count > 1 else { return [end] }
            let moved = lerp(box(k), box(before ? 1 : samples.count - 2), -extensionFactor(atFrame: f, times: times))
            return [end, place(steadyCorners[k], in: moved)]
        }
        let lo = sampleIndex(atOrAfter: f)
        guard samples[lo].frame != f, lo > 0 else { return [place(steadyCorners[lo], in: box(lo))] }
        let between = cuts.filter { $0 > samples[lo - 1].frame && $0 <= samples[lo].frame }
        if let c0 = between.first, let c1 = between.last {
            // Between two cuts, a third shot: where it was before and where it is after.
            let before = place(steadyCorners[lo - 1], in: box(lo - 1)), after = place(steadyCorners[lo], in: box(lo))
            return f < c0 ? [before] : f >= c1 ? [after] : [before, after]
        }
        let u = CGFloat((t - times[samples[lo - 1].frame]) / max(times[samples[lo].frame] - times[samples[lo - 1].frame], 1e-6))
        return [place(lerpPoints(steadyCorners[lo - 1], steadyCorners[lo], u), in: lerp(box(lo - 1), box(lo), u))]
    }

    /// Corners and box where the code was last seen (`last`) or first seen (`first`), for
    /// joining two tracks of a code across a gap.
    func codeEnd(last: Bool) -> (corners: [CGPoint], box: CGRect)? {
        guard isCode, steadyCorners.count == samples.count else { return nil }
        let k = last ? samples.count - 1 : 0
        return (steadyCorners[k], box(k))
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
    /// QR codes to mosaic for every decoded frame: four corners each, margin included, cut
    /// along the code as it lies (slanted, in perspective) instead of the upright box around it.
    public let codes: [[[CGPoint]]]
    /// Slanted lines (and parts of them) to mosaic for every decoded frame: four corners each,
    /// margin included, along the line on a screen filmed at an angle (see `TextTrack.measureTilt`).
    public let slanted: [[[CGPoint]]]
    /// For each quad in `slanted`, where its line starts (bottom left, without the margin): the
    /// mosaic blocks of the quad line up with it along the slant (see `slantedBlocks`).
    public let slantedAnchors: [[CGPoint]]
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
    /// The same for a QR code: longer, because a code filmed with a camera is found only while
    /// it is sharp enough to read (focus, motion blur, glare), and a code is hidden whole.
    static let codeExtend = 1.0
    func extend(_ t: TextTrack) -> Double { t.isCode ? max(extend, Self.codeExtend) : extend }
    /// Frames where the picture changes at once (a cut, a switch to another layout): the first
    /// frame after each change.
    let cuts: [Int]

    /// Room around a code `dt` seconds after (or before) it was last found: the camera moves
    /// it meanwhile, more the longer it goes unseen — up to a quarter of its side by 0.5 s.
    static func codeGrowth(_ q: [CGPoint], seconds dt: Double) -> CGFloat {
        0.25 * sqrt(abs(signedArea(q))) * CGFloat(min(1, max(0, dt) / 0.5))
    }

    public func frameIndex(at time: Double) -> Int { WipeMosaicCore.frameIndex(times, at: time) }

    var entryOfTrack: [Int: Int] {
        var m: [Int: Int] = [:]
        for e in entries { for t in e.trackIDs { m[t] = e.id } }
        return m
    }

    /// Frames where track `t` is shown, `extend` seconds before and after included.
    func frameRange(_ t: TextTrack) -> ClosedRange<Int> {
        let lo = times.partitionIndex { $0 >= times[t.first] - extend(t) - 1e-6 }
        let hi = times.partitionIndex { $0 > times[t.last] + extend(t) + 1e-6 } - 1
        return min(lo, t.first)...max(hi, t.last)
    }

    /// Track id → the track that continues it: one that starts within `maxGap` (6 s with
    /// `all` and for a QR code, else 3 s) at the same place (centres less than 1.5 line heights
    /// apart, 3 box heights for a code), of a similar height, with similar text (any text with
    /// `all`). For a line the first to start; for a code the nearest, since two codes side by
    /// side are often read by turns (the first to start was then the other code, and the quad
    /// moved off this one). A code only continues a code. Nil when cancelled.
    func continuations(of tracks: [TextTrack], all: Bool, cancelled: () -> Bool = { false }) -> [Int: TextTrack]? {
        Self.continuations(of: tracks, times: times, all: all, cancelled: cancelled)
    }

    static func continuations(
        of tracks: [TextTrack], times: [Double], all: Bool, cancelled: () -> Bool = { false }
    ) -> [Int: TextTrack]? {
        let maxGap = all ? 6.0 : 3.0, maxCodeGap = 6.0
        let byStart = tracks.sorted { $0.first < $1.first }
        let starts = byStart.map(\.first)
        var next: [Int: TextTrack] = [:]
        for a in byStart {
            if cancelled() { return nil }
            let ra = a.samples[a.samples.count - 1].rect
            let ta = times[a.last]
            var k = starts.partitionIndex { $0 > a.last }
            var nearest: (track: TextTrack, distance: CGFloat)?
            while k < byStart.count, times[byStart[k].first] - ta <= (a.isCode ? maxCodeGap : maxGap) {
                let b = byStart[k]
                k += 1
                let rb = b.samples[0].rect
                let d = hypot(ra.midX - rb.midX, ra.midY - rb.midY)
                guard a.isCode == b.isCode,
                      d < (a.isCode ? 3 : 1.5) * max(ra.height, rb.height),
                      b.samples[0].lineHeight > 0.6 * a.samples[a.samples.count - 1].lineHeight,
                      b.samples[0].lineHeight < 1.6 * a.samples[a.samples.count - 1].lineHeight,
                      all || similarity(normalizedForMatch(a.text), normalizedForMatch(b.text)) >= 0.6
                else { continue }
                if !a.isCode {
                    nearest = (b, d)
                    break  // the first continuation is enough
                }
                if nearest.map({ d < $0.distance }) ?? true { nearest = (b, d) }
            }
            if let n = nearest { next[a.id] = n.track }
        }
        return next
    }

    /// The entries of QR codes: one per place a code was found at (a code and the codes that
    /// continue it, found again after it could not be read).
    public var codeEntryIDs: Set<Int> { Set(entries.filter { $0.kinds.contains(.qr) }.map(\.id)) }

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
        var codes = [[[CGPoint]]](repeating: [], count: times.count)
        var slanted = [[[CGPoint]]](repeating: [], count: times.count)
        var slantedAnchors = [[CGPoint]](repeating: [], count: times.count)
        var wordHits = Set<Int>()
        var hidden = Set<Int>()
        var relsOf: [Int: [CGRect]] = [:]
        // A slanted line (its `rels` measured along it) is hidden by slanted boxes along it.
        // Where that cannot be drawn (cut at the picture's edge, a box no slanted line has),
        // the whole upright box is hidden by `add` (`rels` = [whole]): a part measured along the
        // line is no part of that. False then.
        func addSlanted(_ rels: [CGRect], lines: [SlantedLine], boxes: [CGRect], slack: CGFloat, margin: CGSize, at f: Int) -> Bool {
            guard let anchorLine = lines.last, boxes.allSatisfy({ bounds.insetBy(dx: 1, dy: 1).contains($0) }) else { return false }
            let m = max(margin.width, margin.height)
            var quads: [[CGPoint]] = []
            for rel in rels {
                // The same room as an upright line, of the slanted line's height.
                let q = SlantedLine.quad(lines, rel: rel, along: anchorLine.height * 0.35 + m, across: anchorLine.height * 0.3 + m, slack: slack)
                guard isDrawableQuad(q) else { return false }
                quads.append(q)
            }
            slanted[f] += quads
            slantedAnchors[f] += quads.map { _ in anchorLine.start }
            return true
        }
        func add(_ rels: [CGRect], line: CGRect, anchor: CGPoint, margin: CGSize = .zero, code: Bool = false, at f: Int) {
            let h = line.height
            // A line gets room for letters that stick out of its box; a code's box is the code
            // itself, and its blank border (a tenth of the side for a small code) is enough.
            let mx = code ? h * 0.1 : h * 0.35, my = code ? h * 0.1 : h * 0.3
            for rel in rels {
                let r = CGRect(
                    x: line.minX + rel.minX * line.width, y: line.minY + rel.minY * line.height,
                    width: rel.width * line.width, height: rel.height * line.height)
                let c = r.insetBy(dx: -mx - margin.width, dy: -my - margin.height).intersection(bounds)
                guard !c.isNull, !c.isEmpty else { continue }  // moved off the picture
                frames[f].append(c)
                anchors[f].append(anchor)
            }
        }
        // A code is hidden whole, with its blank border (a tenth of its side for a small code)
        // and the room for motion around it.
        func addCode(_ q: [CGPoint], margin: CGSize, extra: CGFloat = 0, at f: Int) {
            // A quad that is not convex (corners out of order) is hidden by its box.
            let b = boundingBox(q)
            let quad = isDrawableQuad(q) ? q : [CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY),
                                                 CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.minX, y: b.minY)]
            codes[f].append(outset(quad, by: 0.1 * sqrt(max(abs(signedArea(quad)), b.width * b.height / 2)) + max(margin.width, margin.height) + extra))
        }
        for t in tracks {
            if cancelled() { return nil }
            let entry = owner[t.id] ?? 0
            var rels: [CGRect]
            if o.all || o.lines.contains(entry) {
                rels = [whole]
            } else {
                rels = o.kinds.flatMap { t.parts[$0] ?? [] }
                if !words.isEmpty, !t.isCode {
                    let w = wordParts(t, words)
                    if !w.isEmpty { wordHits.insert(entry) }
                    rels += w
                }
            }
            if !rels.isEmpty { relsOf[t.id] = mergeOverlapping(rels) }
        }
        // A line that could not be read for a moment (covered by a banner, blurred by motion)
        // continues as a new track, and a line read differently (O90 for 090) is a new track
        // that may match nothing: a track is continued by the first one that starts within
        // `maxGap` at the same place with similar text (with `all`, any text). The parts to
        // hide are shared along each chain of continuations, both ways (the misread one may
        // come first), and the mosaic is kept across the gaps. Filmed screens drop lines for
        // longer (glare, focus, fingers); any text at the place counts there.
        // A QR code goes unread while the camera is out of focus or moving: up to 6 s, and up to
        // 3 box heights away (the camera moves meanwhile).
        guard let next = continuations(of: tracks, all: o.all, cancelled: cancelled) else { return nil }
        let byStart = tracks.sorted { $0.first < $1.first }
        // Forward then backward: every track of a chain ends with the union of its parts.
        // Parts of a slanted line are measured along it, of an upright one across its box: from
        // one to the other, the whole line is shared.
        for a in byStart {
            guard let b = next[a.id], let ra = relsOf[a.id] else { continue }
            relsOf[b.id] = mergeOverlapping((relsOf[b.id] ?? []) + (a.isTilted == b.isTilted ? ra : [whole]))
        }
        for a in byStart.reversed() {
            guard let b = next[a.id], let rb = relsOf[b.id] else { continue }
            relsOf[a.id] = mergeOverlapping((relsOf[a.id] ?? []) + (a.isTilted == b.isTilted ? rb : [whole]))
        }
        // A code continued by another is not held on past its last reading nor before the
        // other's first: the place in between comes from the two (below). Held there, it stayed
        // a second where the code was before a cut to another layout, beside the code.
        let continued = Set(next.values.filter(\.isCode).map(\.id))
        for t in tracks {
            if cancelled() { return nil }
            guard let rels = relsOf[t.id] else { continue }
            hidden.insert(owner[t.id] ?? 0)
            for f in frameRange(t) {
                if t.isCode, (f > t.last && next[t.id] != nil) || (f < t.first && continued.contains(t.id)) { continue }
                if let quads = t.codeQuads(atFrame: f, times: times, extend: extend(t), cuts: cuts) {
                    let m = t.motionMargin(atFrame: f, times: times)
                    let dt = f < t.first ? times[t.first] - times[f] : times[f] - times[t.last]
                    for q in quads { addCode(q, margin: m, extra: Self.codeGrowth(q, seconds: dt), at: f) }
                    continue
                }
                if t.isTilted, let s = t.slantedLines(atFrame: f, times: times, extend: extend(t)),
                   addSlanted(rels, lines: s.lines, boxes: s.boxes, slack: t.tiltSlack(atFrame: f, times: times),
                              margin: t.motionMargin(atFrame: f, times: times), at: f) {
                    continue
                }
                if t.isTilted {
                    guard let line = t.line(atFrame: f, times: times, extend: extend(t), bounds: bounds), !line.rect.isEmpty else { continue }
                    add([whole], line: line.rect, anchor: line.anchor, margin: t.motionMargin(atFrame: f, times: times), at: f)
                    continue
                }
                guard let line = t.line(atFrame: f, times: times, extend: extend(t), bounds: bounds), !line.rect.isEmpty else { continue }
                add(rels, line: line.rect, anchor: line.anchor, margin: t.motionMargin(atFrame: f, times: times), code: t.isCode, at: f)
            }
            if let b = next[t.id] {
                let ra = t.samples[t.samples.count - 1].rect, rb = b.samples[0].rect
                let ta = times[t.last], tb = times[b.first]
                // A code moves with the camera meanwhile, not at a steady speed: half the
                // distance between the two places, across or down (the larger for a code), is
                // added around it.
                let gapMargin = t.isCode ? CGSize(width: abs(rb.midX - ra.midX) / 2, height: abs(rb.midY - ra.midY) / 2) : .zero
                let ends = t.codeEnd(last: true).flatMap { a in b.codeEnd(last: false).map { (a, $0) } }
                // Across a cut the code jumps: before it, it is where it was last seen, after it
                // where it is found next (each continued with its motion, as before and after a
                // track). Without one it moves between the two places.
                let gapCuts = cuts.filter { $0 > t.last && $0 <= b.first }
                for f in (t.last + 1)..<b.first where t.isCode || (times[f] > ta + extend(t) && times[f] < tb - extend(b)) {
                    let u = CGFloat((times[f] - ta) / max(tb - ta, 1e-6))
                    if let (ea, eb) = ends {
                        if let c0 = gapCuts.first, let c1 = gapCuts.last {
                            if f < c1 || c0 == c1 && f < c0 {
                                for q in t.codeQuads(atFrame: f, times: times, extend: .infinity) ?? [] {
                                    addCode(q, margin: t.motionMargin(atFrame: f, times: times), extra: Self.codeGrowth(q, seconds: times[f] - ta), at: f)
                                }
                            }
                            if f >= c0 && (f >= c1 || c0 != c1) {
                                for q in b.codeQuads(atFrame: f, times: times, extend: .infinity) ?? [] {
                                    addCode(q, margin: b.motionMargin(atFrame: f, times: times), extra: Self.codeGrowth(q, seconds: tb - times[f]), at: f)
                                }
                            }
                            continue
                        }
                        // Between the two places with all the room from the first frame: a code
                        // missed while blurred by motion has started moving then (room growing in
                        // over 0.25 s, tried for a steadier mosaic, left it out of the box), and
                        // also where it was and where it is next, as long as a code is held there.
                        let near = min(times[f] - ta, tb - times[f])
                        let q = place(lerpPoints(ea.corners, alignedCorners(eb.corners, to: ea.corners), u), in: lerp(ea.box, eb.box, u))
                        addCode(q, margin: gapMargin, extra: Self.codeGrowth(q, seconds: near), at: f)
                        for q in t.codeQuads(atFrame: f, times: times, extend: extend(t)) ?? [] {
                            addCode(q, margin: t.motionMargin(atFrame: f, times: times), extra: Self.codeGrowth(q, seconds: times[f] - ta), at: f)
                        }
                        for q in b.codeQuads(atFrame: f, times: times, extend: extend(b)) ?? [] {
                            addCode(q, margin: b.motionMargin(atFrame: f, times: times), extra: Self.codeGrowth(q, seconds: tb - times[f]), at: f)
                        }
                        continue
                    }
                    let r = lerp(ra, rb, u)
                    let anchor = CGPoint(x: r.minX.rounded(), y: r.minY.rounded())
                    if t.isTilted || b.isTilted {
                        // Slanted on both sides: slanted between them, turning from one slant to
                        // the other (half the turn is added as slack: it need not turn evenly).
                        // Else the whole upright box.
                        let a0 = t.isTilted ? t.tilts[t.tilts.count - 1] : 0, a1 = b.isTilted ? b.tilts[0] : 0
                        if t.isTilted && b.isTilted,
                           let line = SlantedLine(box: r, angle: a0 + (a1 - a0) * u,
                                                  height: max(t.lineHeights[t.lineHeights.count - 1], b.lineHeights[0])),
                           addSlanted(rels, lines: [line], boxes: [r],
                                      slack: max(t.tiltSlacks[t.tiltSlacks.count - 1], b.tiltSlacks[0]) + abs(a1 - a0) / 2, margin: .zero, at: f) {
                            continue
                        }
                        add([whole], line: r, anchor: anchor, at: f)
                        continue
                    }
                    add(rels, line: r, anchor: anchor, margin: gapMargin, code: t.isCode, at: f)
                }
            }
        }
        // Words also count for entries that are hidden as a whole line.
        if !words.isEmpty {
            for t in tracks where !t.isCode && o.lines.contains(owner[t.id] ?? 0) && !wordParts(t, words).isEmpty {
                wordHits.insert(owner[t.id] ?? 0)
            }
        }
        if cancelled() { return nil }
        return TextMask(
            frames: frames, anchors: anchors, codes: codes, slanted: slanted, slantedAnchors: slantedAnchors, wordHits: wordHits, hidden: hidden, wordLines: wordLineCounts(o.words))
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
            for t in tracks where !t.isCode && distinctReadings(t).contains(where: { !wordRanges(in: $0.string, words: [n]).isEmpty }) {
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
                out.append(relativeBox(s, range: range, size: size, along: t.isTilted) ?? whole)
            }
        }
        return out
    }
}

/// Face frames (if any) with the text boxes of the same decoded frames added.
public func withText(_ faces: [FrameFaces], text: ScreenText, mask: TextMask) -> [FrameFaces] {
    if faces.isEmpty {
        return text.times.indices.map {
            FrameFaces(
                time: text.times[$0], mosaic: [], kept: [], exact: mask.frames[$0], exactAnchors: mask.anchors[$0], codes: mask.codes[$0],
                slanted: mask.slanted[$0], slantedAnchors: mask.slantedAnchors[$0])
        }
    }
    return faces.map { f in
        let i = text.frameIndex(at: f.time)
        return FrameFaces(
            time: f.time, mosaic: f.mosaic, kept: f.kept, exact: mask.frames[i], exactAnchors: mask.anchors[i], codes: mask.codes[i], slanted: mask.slanted[i],
            slantedAnchors: mask.slantedAnchors[i], stickers: f.stickers)
    }
}
