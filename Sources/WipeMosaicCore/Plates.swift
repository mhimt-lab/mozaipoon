import AVFoundation
import CoreImage
import Vision

/// Share of `analyzeText`'s progress given to following plates (shown also for a video
/// without any, which then jumps over it).
let plateProgressShare = 0.1
/// Long side of the frames a plate is followed in (`followPlates`), in pixels.
let plateFollowSize: CGFloat = 1280
/// How long before a plate's first reading and after its last one it is followed, in seconds.
let plateFollowReach = 1.5
// The frames a plate is followed in are gray (one byte a pixel), and every one is kept for
// following back (`plateFollowReach` of them: about 80 MB for 16:9 at 60 a second, in
// proportion to the frame rate). Kept 30 a second, a fast car moved half its plate's width
// between two, and the tracker lost it after one frame back (a street video).

/// Least confidence of the tracker to take its box for a plate's. Below it twice in a row, the
/// plate is let go: once is let pass (a fast car blurred for a frame: followed back over the
/// frames kept 30 a second then, the confidence fell to 0.36 at one and was 0.57 at the next).
let plateFollowConfidence: Float = 0.4
/// Seconds between the boxes added to a followed plate's track.
let plateFollowStep = 0.1
/// Seconds a followed plate is held on past its box at an end the tracker followed it the whole
/// `plateFollowReach` (`TextTrack.heldBriefly`); where it lost the plate or the plate left the
/// picture, it is held on as other lines. Held on as long as other lines, with its motion carried on
/// (1.5 times the distance between its last two boxes), a car crossing the picture fast was
/// hidden by a band across a third of it (a street video).
let plateHeldExtend = 0.2
/// Largest growth of a followed plate's box over the box of its reading: a car coming nearer
/// grows, but the tracker's box also drifts in size.
let plateMaxGrowth: CGFloat = 2

/// Recognition reads a plate on a moving car only now and then (blurred, small, half a second
/// apart where the picture changes little): on real street videos it was left showing between
/// its readings, and before the first and after the last one (2026-11-16). Each plate found (a
/// number line, or a line under a plate's upper line, `markPlatePairs`) is followed by Vision's
/// object tracker in frames of `plateFollowSize`, the tracker started on the frame of a reading:
/// - forward from each reading to the next (started again at each; where its box is then more
///   than 1.5 line heights off the reading, it had drifted, and its boxes since the last
///   reading are dropped; where it lost the plate before the next reading, its boxes are kept
///   only if the last one is near the line between the two readings), up to
///   `plateFollowReach` after the last one;
/// - back from the first reading, over the frames kept, up to `plateFollowReach`;
/// while the tracker is sure of it (`plateFollowConfidence`), until the middle of its box
/// leaves the picture, and not across a cut. A box every `plateFollowStep` is added to the
/// track (the reading's size, grown as the tracker's box up to `plateMaxGrowth`; the corners
/// of the reading), which then moves with the plate. Only the times around plates are decoded
/// again: the plates whose times (with `plateFollowReach` either side) overlap, one stretch
/// at a time. `progress` gets the share done (0...1).
func followPlates(
    _ tracks: inout [TextTrack], asset: AVURLAsset, info: VideoInfo, times: [Double], cuts: [Int],
    progress: (Double) -> Void
) throws {
    let seeds = tracks.indices.filter { k in
        let t = tracks[k]
        return !t.isCode && t.parts[.plate] != nil && t.samples.contains { s in
            s.string.contains(where: \.isNumber) && plateTopRegex.firstMatch(in: s.string, range: NSRange(s.string.startIndex..., in: s.string)) == nil
        }
    }.sorted { tracks[$0].first < tracks[$1].first }
    guard !seeds.isEmpty, !times.isEmpty else { return }
    let size = info.size
    let scale = min(1, plateFollowSize / max(size.width, size.height))
    let small = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    let bounds = CGRect(origin: .zero, size: size)
    let cutSet = Set(cuts)
    let ctx = CIContext(options: [.cacheIntermediates: false])
    let gray = CGColorSpaceCreateDeviceGray()
    func normalized(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX / size.width, y: r.minY / size.height, width: r.width / size.width, height: r.height / size.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    func frameRect(_ n: CGRect) -> CGRect {
        CGRect(x: n.minX * size.width, y: n.minY * size.height, width: n.width * size.width, height: n.height * size.height)
    }

    /// One plate followed one way from a reading.
    struct Follower {
        let track: Int
        var request: VNTrackObjectRequest
        var handler = VNSequenceRequestHandler()
        let reading: TextSample
        var size: CGSize  // of the box added, from the reading's
        var lastAdded: Double
        var found: [TextSample] = []
        var done = false
        var unsure = false  // the last frame's confidence was below `plateFollowConfidence`
        /// Waits for the next reading, close by: no box would be added before it.
        var idle = false
        /// Followed the whole `plateFollowReach` (or to the end or start of the video).
        var reached = false
    }
    /// A follower of track `k` from its reading `s`, the tracker started on that frame (`image`);
    /// idle if `next`, the time of the track's next reading, is close.
    func start(_ k: Int, from s: TextSample, on image: () throws -> CGImage, time t: Double, next: Double? = nil) rethrows -> Follower {
        let r = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: normalized(s.rect)))
        r.trackingLevel = .accurate
        var f = Follower(track: k, request: r, reading: s, size: s.rect.size, lastAdded: t)
        if let next, next - t <= 1.5 * plateFollowStep + 1e-6 {
            f.idle = true
            return f
        }
        if (try? f.handler.perform([r], on: image())) != nil, let o = r.results?.first as? VNDetectedObjectObservation {
            f.request.inputObservation = o
        }
        return f
    }
    /// The tracker's box in `image` and whether it is sure of it, nil when it failed (counted
    /// as losing the plate, which is then held on as other lines).
    func track(_ f: inout Follower, _ image: CGImage) -> (box: CGRect, sure: Bool)? {
        guard (try? f.handler.perform([f.request], on: image)) != nil,
              let o = f.request.results?.first as? VNDetectedObjectObservation
        else { return nil }
        f.request.inputObservation = o
        return (frameRect(o.boundingBox), o.confidence >= plateFollowConfidence)
    }
    /// Follows `f` into `image` (frame `i` at `t`); false once it stops.
    func follow(_ f: inout Follower, _ image: CGImage, frame i: Int, time t: Double) -> Bool {
        guard let (box, sure) = track(&f, image), sure || !f.unsure else { return false }
        f.unsure = !sure
        guard sure else { return true }
        let mid = CGPoint(x: box.midX, y: box.midY)
        func add() {
            let rect = CGRect(x: mid.x - f.size.width / 2, y: mid.y - f.size.height / 2, width: f.size.width, height: f.size.height)
            // Not clipped to the picture (the mosaic is): clipped, the plate's box shrinks, and so
            // does the part above the number it is widened by.
            f.found.append(TextSample(frame: i, rect: rect, string: f.reading.string, text: nil,
                                      corners: bounds.contains(rect) ? f.reading.corners : nil, tracked: true))
            f.lastAdded = t
        }
        // Left the picture: its box there is added, and it is held on as other lines (the motion
        // carried on goes out of the picture).
        guard bounds.contains(mid) else {
            if abs(t - f.lastAdded) > 1e-6 { add() }
            return false
        }
        // At the picture's edge the tracker's box turns out of shape (three times as high as the
        // plate, a street video): the size is kept there.
        if bounds.insetBy(dx: 2, dy: 2).contains(box) {
            let r = f.reading.rect
            let k = min(plateMaxGrowth, max(1, sqrt(box.width * box.height / max(r.width * r.height, 1))))
            f.size = CGSize(width: r.width * k, height: r.height * k)
        }
        if abs(t - f.lastAdded) >= plateFollowStep - 1e-6 { add() }
        return true
    }

    var added: [Int: [TextSample]] = [:]
    var held: [Int: (before: Bool, after: Bool)] = [:]
    struct Finished: Error {}
    // Stretches of overlapping plate times.
    var groups: [[Int]] = []
    var groupEnd = -Double.infinity
    for k in seeds {
        let from = times[tracks[k].first] - plateFollowReach, to = times[tracks[k].last] + plateFollowReach
        if groups.isEmpty || from > groupEnd {
            groups.append([k])
            groupEnd = to
        } else {
            groups[groups.count - 1].append(k)
            groupEnd = max(groupEnd, to)
        }
    }
    func span(_ group: [Int]) -> (first: Double, last: Double) {
        (group.map { times[tracks[$0].first] }.min()! - plateFollowReach, group.map { times[tracks[$0].last] }.max()! + plateFollowReach)
    }
    let groupTime = groups.reduce(0.0) { $0 + span($1).last - span($1).first }
    var doneTime = 0.0
    /// Follows the plates `group` over their stretch of the video.
    func run(_ group: [Int]) throws {
        // Readings by frame, for each track.
        var readingAt: [Int: [Int: TextSample]] = [:]
        var readingFrames: [Int: [Int]] = [:]
        for k in group {
            for s in tracks[k].samples where !s.tracked { readingAt[k, default: [:]][s.frame] = s }
            readingFrames[k] = readingAt[k, default: [:]].keys.sorted()
        }
        /// Time of track `k`'s next reading after frame `i`.
        func nextReading(_ k: Int, after i: Int) -> Double? {
            guard let fs = readingFrames[k] else { return nil }
            let j = fs.partitionIndex { $0 > i }
            return j < fs.count ? times[fs[j]] : nil
        }
        let firstTimes = group.map { times[tracks[$0].first] }.sorted()
        // Frames kept for following back: the last `plateFollowReach` seconds.
        var kept: [(frame: Int, time: Double, image: CGImage)] = []
        var forward: [Follower] = []
        let (first, last) = span(group)
        let byFirst = Dictionary(grouping: group, by: { tracks[$0].first })
        // Followers that lost their plate before its next reading, checked there.
        var pending: [Int: Follower] = [:]
        func finish(_ f: Follower, at i: Int) {
            if !f.reached, readingAt[f.track]?.keys.contains(where: { $0 > i }) == true {
                pending[f.track] = f
                return
            }
            added[f.track, default: []] += f.found
            held[f.track, default: (false, false)].after = f.reached  // the last follower's
        }
        /// The boxes of `f`, lost before the reading `s` (at `t`), if the last one is near the
        /// line between its reading and `s` (cars move nearly straight in half a second; the
        /// tracker gone onto another car while the plate was hidden is not).
        func check(_ f: Follower, next s: TextSample, time t: Double) {
            guard let b = f.found.last else { return }
            let t0 = times[f.reading.frame], tb = times[b.frame]
            let expected = lerp(f.reading.rect, s.rect, CGFloat((tb - t0) / max(t - t0, 1e-6)))
            let off = hypot(b.rect.midX - expected.midX, b.rect.midY - expected.midY)
            if off <= 3 * max(f.reading.rect.height, s.rect.height) { added[f.track, default: []] += f.found }
        }
        // From a frame's own time: the reader gives the first frame it reads the time it starts
        // reading at.
        let from = times[max(0, times.partitionIndex { $0 >= first } - 1)]
        var read = 0
        do {
            try forEachFrame(asset: asset, info: info, from: from) { _, t, image in
                read += 1
                let i = times.partitionIndex { $0 >= t - 1e-4 }
                guard i < times.count, t <= last + 1e-6 else { throw Finished() }
                guard abs(times[i] - t) < 1e-3 else {
                    if read == 1 { return }  // its time moved to where reading started

                    throw ToolError("ナンバープレートを追う処理が別のフレームを読みました（\(t) 秒。\(i) 番目のフレームは \(times[i]) 秒）")
                }
                progress(min(1, (doneTime + max(0, t - first)) / max(groupTime, 1e-6)))
                // Made only for a frame a plate is followed in, or kept for following back.
                var made: CGImage?
                func frame() throws -> CGImage {
                    if let made { return made }
                    let shrunk = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    guard let cg = ctx.createCGImage(shrunk, from: CGRect(origin: .zero, size: small), format: .L8, colorSpace: gray) else {
                        throw ToolError("ナンバープレートを追うための縮小画像を作れませんでした（\(t) 秒）")
                    }
                    made = cg
                    return cg
                }
                for n in forward.indices where !forward[n].done {
                    let k = forward[n].track
                    if let s = readingAt[k]?[i] {
                        // Drifted off the plate since the last reading: those boxes dropped (the
                        // plate is interpolated between the readings there).
                        if !forward[n].idle, let (box, _) = track(&forward[n], try frame()),
                           hypot(box.midX - s.rect.midX, box.midY - s.rect.midY) > 1.5 * s.rect.height {
                            forward[n].found = []
                        }
                        added[k, default: []] += forward[n].found
                        forward[n] = try start(k, from: s, on: frame, time: t, next: nextReading(k, after: i))
                        continue
                    }
                    if forward[n].idle { continue }
                    if t > times[tracks[k].last] + plateFollowReach {
                        forward[n].reached = true
                        forward[n].done = true
                    } else if try cutSet.contains(i) || !follow(&forward[n], frame(), frame: i, time: t) {
                        forward[n].done = true
                    }
                    if forward[n].done { finish(forward[n], at: i) }
                }
                forward.removeAll(where: \.done)
                for k in byFirst[i] ?? [] {
                    let s = tracks[k].samples[0]
                    // Back over the frames kept, not across a cut.
                    var back = try start(k, from: s, on: frame, time: t)
                    var reached = true
                    var after = i
                    for p in kept.reversed() {
                        if t - p.time > plateFollowReach + 1e-6 { break }
                        if cuts.contains(where: { $0 > p.frame && $0 <= after }) || !follow(&back, p.image, frame: p.frame, time: p.time) {
                            reached = back.reached
                            break
                        }
                        after = p.frame
                    }
                    // The frames kept fall short of the reach only at the start of the video.
                    if reached, let oldest = kept.first, t - oldest.time < plateFollowReach - 2 / max(info.fps, 1), oldest.frame > 0 { reached = false }
                    added[k, default: []] += back.found
                    held[k, default: (false, false)].before = reached
                    forward.append(try start(k, from: s, on: frame, time: t, next: nextReading(k, after: i)))
                }
                // A plate lost between its readings is followed again from the next one.
                for k in group where !forward.contains(where: { $0.track == k }) {
                    guard let s = readingAt[k]?[i], i != tracks[k].first else { continue }
                    if let f = pending.removeValue(forKey: k) { check(f, next: s, time: t) }
                    forward.append(try start(k, from: s, on: frame, time: t, next: nextReading(k, after: i)))
                }
                let j = firstTimes.partitionIndex { $0 > t + 1e-6 }
                if j < firstTimes.count, firstTimes[j] - t <= plateFollowReach + 1e-6 { kept.append((i, t, try frame())) }
                kept.removeAll { t - $0.time > plateFollowReach + 1e-6 }
            }
        } catch is Finished {}
        // At the end of the video: nothing more to follow.
        for var f in forward {
            f.reached = true
            finish(f, at: times.count)
        }
        for f in pending.values { added[f.track, default: []] += f.found }
        doneTime += last - first
    }
    for group in groups { try run(group) }
    for (k, more) in added {
        tracks[k].addFollowed(more, heldBriefly: held[k, default: (false, false)])
        tracks[k].measureTilt(times: times)
    }
    // A plate's upper line (`markPlatePairs`) over a followed number at all its readings: the
    // number's mosaic covers it, and where the number was followed on past its end (by
    // `plateHeldExtend` or more), the line is held on briefly there. Held on as other lines,
    // with a fast car's motion carried on, it hid a band across a third of the picture.
    let followed = seeds.filter { added[$0] != nil }
    for k in tracks.indices where !seeds.contains(k) && !tracks[k].isCode && tracks[k].parts[.plate] != nil {
        let top = tracks[k]
        let under = followed.first { m in
            top.samples.allSatisfy { s in
                guard let b = tracks[m].samples.min(by: { abs($0.frame - s.frame) < abs($1.frame - s.frame) }),
                      abs(times[b.frame] - times[s.frame]) <= plateFollowStep + 1e-6 else { return false }
                return b.rect.maxY <= s.rect.minY + 0.5 * s.rect.height && s.rect.minY - b.rect.maxY <= 2 * b.rect.height
                    && abs(b.rect.midX - s.rect.midX) <= max(b.rect.width, s.rect.width)
            }
        }
        guard let m = under else { continue }
        tracks[k].addFollowed([], heldBriefly: (times[top.first] - times[tracks[m].first] >= plateHeldExtend - 1e-6,
                                                times[tracks[m].last] - times[top.last] >= plateHeldExtend - 1e-6))
    }
    progress(1)
}
