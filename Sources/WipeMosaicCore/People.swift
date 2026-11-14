import AVFoundation
import CoreImage
import Vision

public struct Detection: Sendable {
    public let frame: Int
    public let rect: CGRect  // Core Image coordinates of the upright frame
    /// true when the face detector missed this frame and the box comes from following the
    /// head region (object tracking), e.g. a profile view during fast motion.
    public var tracked = false
}

/// One continuous appearance of a face.
public struct FaceTrack: Sendable {
    public let id: Int
    public fileprivate(set) var detections: [Detection] = []
    fileprivate var appearance: [FaceSignature] = []
    fileprivate var identity: [FaceSignature] = []
    fileprivate var lastSample: Int?

    var lastFrame: Int { detections.last!.frame }
    var lastRect: CGRect { detections.last!.rect }
    /// Every frame from the first to the last detection (gaps inside a track are short).
    var span: ClosedRange<Int> { detections.first!.frame...lastFrame }

    /// The face was not really seen around frame `f`: the box comes from object tracking, or
    /// from interpolating over a gap longer than `maxGap` frames. Short gaps (frames between
    /// tile passes for small faces, a single missed detection) count as seen.
    func isEstimated(atFrame f: Int, maxGap: Int) -> Bool {
        guard let i = firstDetection(atOrAfter: f) else { return true }
        let b = detections[i]
        if b.frame == f { return b.tracked }
        guard i > 0 else { return true }
        let a = detections[i - 1]
        return a.tracked || b.tracked || b.frame - a.frame > maxGap
    }

    func isTracked(atFrame f: Int) -> Bool {
        firstDetection(atOrAfter: f).map { detections[$0].frame == f ? detections[$0].tracked : true } ?? true
    }

    /// Index of the first detection at or after frame `f` (binary search: called for every
    /// frame of the track).
    private func firstDetection(atOrAfter f: Int) -> Int? {
        guard let last = detections.last, last.frame >= f else { return nil }
        var lo = 0, hi = detections.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if detections[mid].frame < f { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Box at frame `f`, linearly interpolated between detections; nil outside the track.
    /// Small faces are only searched on some frames (tile passes), and a detection can be
    /// missed, so the face is assumed to stay on screen between two detections of a track.
    func rect(atFrame f: Int) -> CGRect? {
        guard span.contains(f), let lo = firstDetection(atOrAfter: f) else { return nil }
        let b = detections[lo]
        guard b.frame != f, lo > 0 else { return b.rect }
        let a = detections[lo - 1]
        return lerp(a.rect, b.rect, CGFloat(f - a.frame) / CGFloat(b.frame - a.frame))
    }
}

/// Tracks grouped as one person.
public struct Person: Sendable, Identifiable {
    /// 1-based, ordered by screen time (longest first).
    public let id: Int
    public let trackIDs: [Int]
    public let frameCount: Int
    public let firstFrame: Int
    /// Up to 4 large faces from different tracks, for thumbnails.
    public let samples: [Detection]
    fileprivate let identity: [FaceSignature]
    /// Other people who may be the same person (appearance close, never on screen together),
    /// nearest first. Shown as a hint; checking this person also checks them.
    public let similar: [Int]
}

public struct VideoFaces: Sendable {
    public let times: [Double]
    public let tracks: [FaceTrack]
    public let people: [Person]
    public let fps: Double
    let maxGapFrames: Int

    /// Person id for every track id.
    public var personOfTrack: [Int: Int] {
        var m: [Int: Int] = [:]
        for p in people { for t in p.trackIDs { m[t] = p.id } }
        return m
    }

    public func frameIndex(at time: Double) -> Int { WipeMosaicCore.frameIndex(times, at: time) }

    /// Faces present in one frame with their person id.
    public func faces(atFrame f: Int) -> [(rect: CGRect, person: Int)] {
        let owner = personOfTrack
        var out: [(CGRect, Int)] = []
        for t in tracks {
            if let r = t.rect(atFrame: f) { out.append((r, owner[t.id] ?? 0)) }
        }
        return out
    }

    /// Per-frame mosaic/other boxes for the selected people.
    /// - Gaps inside a track (frames without a tile pass, missed detections) are interpolated.
    /// - Boxes from object tracking are enlarged, as they are less exact than detections.
    /// - For selected people, a gap of up to `bridge` seconds between two of their tracks is
    ///   filled (interpolated, enlarged), and the mosaic stays `endHold` seconds before each
    ///   appearance and after each disappearance at the nearest known position.
    /// - Each selected person gets one steadied box per frame (the face itself first, then a
    ///   bridge, then a hold position), so the mosaic, blur or sticker does not jitter with
    ///   the detector. People in `stickered` get it in `FrameFaces.stickers`, the others in
    ///   `mosaic`. A box that lost to a better one in the same frame (a hold position while
    ///   the face is already seen elsewhere) is still mosaicked as it is, in case the two
    ///   tracks are not the same person after all.
    public func frames(
        selected: Set<Int>, endHold: Double = 1.0, bridge: Double = 2.0, stickered: Set<Int> = []
    ) -> [FrameFaces] {
        let owner = personOfTrack
        let n = times.count
        let fps = max(self.fps, 1)
        let holdFrames = Int((endHold * fps).rounded())
        let bridgeFrames = Int((bridge * fps).rounded())
        let estimateGap = max(2, Int((0.25 * fps).rounded()))
        var mosaic = [[CGRect]](repeating: [], count: n)
        var other = [[CGRect]](repeating: [], count: n)
        // The best box per selected person and frame, with its priority: 0 detected face,
        // 1 followed by tracking, 2 bridge between two appearances, 3 held position.
        var best: [Int: [(rect: CGRect, rank: Int)?]] = [:]
        for p in selected { best[p] = Array(repeating: nil, count: n) }
        func add(_ r: CGRect, person: Int, frame f: Int, rank: Int) {
            guard let cur = best[person]![f] else { return best[person]![f] = (r, rank) }
            // The other box (a held position next to the face, or two held positions of one
            // person far apart) stays mosaicked as it is rather than being merged into a box
            // that would cover both.
            // Spelled out: the Xcode 26.6 compiler (release CI) crashes on the equivalent ternary
            // whose branches are tuples with and without labels.
            let win: (rect: CGRect, rank: Int)
            let lose: CGRect
            if rank < cur.rank { win = (r, rank); lose = cur.rect } else { win = cur; lose = r }
            best[person]![f] = win
            if !win.rect.contains(lose) { mosaic[f].append(lose) }
        }
        var selectedTracks: [Int: [FaceTrack]] = [:]
        for t in tracks {
            let person = owner[t.id] ?? -1
            let isSelected = selected.contains(person)
            if isSelected { selectedTracks[person, default: []].append(t) }
            for f in t.span {
                guard let r = t.rect(atFrame: f) else { continue }
                guard isSelected else { other[f].append(r); continue }
                let box = t.isTracked(atFrame: f) ? scaled(r, 1.25) : r
                add(box, person: person, frame: f, rank: t.isEstimated(atFrame: f, maxGap: estimateGap) ? 1 : 0)
            }
        }
        for (person, ts) in selectedTracks {
            let ordered = ts.sorted { $0.span.lowerBound < $1.span.lowerBound }
            for (k, t) in ordered.enumerated() {
                // Bridge to this person's next track if it starts soon after this one ends.
                if k + 1 < ordered.count {
                    let next = ordered[k + 1]
                    let a = t.span.upperBound, b = next.span.lowerBound
                    if b - a > 1 && b - a - 1 <= bridgeFrames {
                        let ra = t.lastRect, rb = next.detections.first!.rect
                        for f in (a + 1)..<b {
                            add(scaled(lerp(ra, rb, CGFloat(f - a) / CGFloat(b - a)), 1.3), person: person, frame: f, rank: 2)
                        }
                    }
                }
                guard holdFrames > 0 else { continue }
                let first = t.detections.first!.rect
                for f in max(0, t.span.lowerBound - holdFrames)..<t.span.lowerBound { add(first, person: person, frame: f, rank: 3) }
                let last = t.lastRect
                if t.span.upperBound + 1 < n {
                    for f in (t.span.upperBound + 1)...min(n - 1, t.span.upperBound + holdFrames) { add(last, person: person, frame: f, rank: 3) }
                }
            }
        }
        var stickers = [[StickerBox]](repeating: [], count: n)
        for (person, boxes) in best {
            let steady = steadyBoxes(
                boxes.map { $0?.rect }, centreFrames: max(1, Int((0.25 * fps).rounded())),
                sizeFrames: max(1, Int((0.5 * fps).rounded())), marginFrames: max(1, Int((0.25 * fps).rounded())))
            let sticker = stickered.contains(person)
            for f in 0..<n {
                guard let r = steady[f] else { continue }
                if sticker {
                    stickers[f].append(StickerBox(rect: r, person: person, estimated: (boxes[f]?.rank ?? 0) > 0))
                } else {
                    mosaic[f].append(r)
                }
            }
        }
        return times.indices.map { FrameFaces(time: times[$0], mosaic: mosaic[$0], kept: other[$0], stickers: stickers[$0]) }
    }

    /// Best identity distance from every person to one registered photo.
    public func distances(to registered: FaceSignature) -> [Int: Float] {
        var out: [Int: Float] = [:]
        for p in people {
            for a in p.identity {
                if let d = try? distance(a, registered), out[p.id] == nil || d < out[p.id]! { out[p.id] = d }
            }
        }
        return out
    }

    /// Best identity distance between each person here and one person of another video.
    public func distances(to person: Int, in other: VideoFaces) -> [Int: Float] {
        guard let q = other.people.first(where: { $0.id == person }) else { return [:] }
        var out: [Int: Float] = [:]
        for p in people {
            for a in p.identity {
                for b in q.identity {
                    if let d = try? distance(a, b), out[p.id] == nil || d < out[p.id]! { out[p.id] = d }
                }
            }
        }
        return out
    }

    /// People here who resemble the given people of another video: person id → best distance.
    /// Same rule as `suggestions`: for each given person only the nearest person here (plus
    /// anyone within `tie`) and only within `threshold`. A pre-selection to be checked.
    public func matches(of chosen: Set<Int>, in other: VideoFaces, threshold: Float = 0.5, tie: Float = 0.05) -> [Int: Float] {
        var out: [Int: Float] = [:]
        for q in chosen {
            let ds = distances(to: q, in: other)
            guard let nearest = ds.values.min(), nearest <= threshold else { continue }
            for (id, d) in ds where d <= min(threshold, nearest + tie) {
                if out[id] == nil || d < out[id]! { out[id] = d }
            }
        }
        return out
    }

    /// People whose faces resemble a registered photo: person id → best distance.
    /// Video crops sit far from photos even for the same person (0.50–0.76 on the synthetic set,
    /// 2026-11-12), so an absolute threshold alone either misses or over-matches. For each photo
    /// only the nearest person (plus anyone within `tie` of it, e.g. one person split in two) is
    /// suggested, and only if within `threshold`. Weak by design: a pre-selection to be checked.
    public func suggestions(registered: [FaceSignature], threshold: Float = 0.75, tie: Float = 0.05) -> [Int: Float] {
        var out: [Int: Float] = [:]
        for r in registered {
            let ds = distances(to: r)
            guard let nearest = ds.values.min(), nearest <= threshold else { continue }
            for (id, d) in ds where d <= min(threshold, nearest + tie) {
                if out[id] == nil || d < out[id]! { out[id] = d }
            }
        }
        return out
    }
}

func lerp(_ a: CGRect, _ b: CGRect, _ k: CGFloat) -> CGRect {
    CGRect(
        x: a.minX + (b.minX - a.minX) * k, y: a.minY + (b.minY - a.minY) * k,
        width: a.width + (b.width - a.width) * k, height: a.height + (b.height - a.height) * k)
}

/// Same centre, sides multiplied by `s`.
func scaled(_ r: CGRect, _ s: CGFloat) -> CGRect {
    r.insetBy(dx: -r.width * (s - 1) / 2, dy: -r.height * (s - 1) / 2)
}

private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let i = a.intersection(b)
    guard !i.isNull else { return 0 }
    let inter = i.width * i.height
    return inter / (a.width * a.height + b.width * b.height - inter)
}

private func median(_ v: [Float]) -> Float? {
    guard !v.isEmpty else { return nil }
    let s = v.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

/// Pass 1: detect every face, follow it across frames as tracks, then group tracks into
/// people. Two tracks visible in the same frame are never merged; otherwise they are merged
/// when the median appearance distance is ≤ mergeThreshold. People within `similarThreshold`
/// of each other are linked as "maybe the same person". Measured on the synthetic set
/// (2026-11-12): same person front vs turned 0.35, different people 0.85–1.12.
///
/// The face detector misses profiles and motion-blurred faces. When a track's face is not
/// found, the head region is followed with Vision object tracking from the previous frame
/// (for up to `maxTracking` seconds, while the tracker is confident), so the track — and the
/// mosaic — continues through a turn of the head instead of breaking into a new person.
public func analyzeFaces(
    asset: AVURLAsset, info: VideoInfo, tiles: Int, tileInterval: Double = 0.1, maxGap: Double = 0.5,
    maxTracking: Double = 5, mergeThreshold: Float = 0.45, similarThreshold: Float = 0.6,
    progress: (Int) -> Void
) throws -> VideoFaces {
    var times: [Double] = []
    var tracks: [FaceTrack] = []
    var active: [Int] = []
    let gapFrames = max(1, Int((maxGap * max(info.fps, 1)).rounded()))
    let sampleEvery = max(1, Int((max(info.fps, 1) / 3).rounded()))  // ~3 samples per second
    let maxSamples = 12
    let maxTrackedFrames = max(1, Int((maxTracking * max(info.fps, 1)).rounded()))
    var followers: [Int: HeadFollower] = [:]  // track index → tracker during a detection gap
    var trackedRun: [Int: Int] = [:]  // consecutive tracked frames; maxTrackedFrames = gave up
    var previous: CIImage?

    try forEachFrameDetecting(asset: asset, info: info, tiles: tiles, tileInterval: tileInterval, extraRegions: []) { i, t, img, faces in
        times.append(t)
        active.removeAll { i - tracks[$0].lastFrame > gapFrames }

        var pairs: [(score: CGFloat, face: Int, track: Int)] = []
        for (fi, f) in faces.enumerated() {
            for ti in active {
                let r = tracks[ti].lastRect
                var score = iou(f, r)
                if score < 0.2 {  // fast motion: fall back to centre distance
                    let d = hypot(f.midX - r.midX, f.midY - r.midY)
                    let s = max(r.width, r.height)
                    if d < s * 0.75 { score = 0.2 - d / (s * 10) }
                }
                if score > 0.1 { pairs.append((score, fi, ti)) }
            }
        }
        var faceTrack = [Int?](repeating: nil, count: faces.count)
        var used = Set<Int>()
        for p in pairs.sorted(by: { $0.score > $1.score }) where faceTrack[p.face] == nil && !used.contains(p.track) {
            faceTrack[p.face] = p.track
            used.insert(p.track)
        }
        for (fi, f) in faces.enumerated() {
            let ti: Int
            if let existing = faceTrack[fi] {
                ti = existing
            } else {
                tracks.append(FaceTrack(id: tracks.count))
                ti = tracks.count - 1
                active.append(ti)
            }
            tracks[ti].detections.append(Detection(frame: i, rect: f))
            let tr = tracks[ti]
            if tr.appearance.count < maxSamples, tr.lastSample.map { i - $0 >= sampleEvery } ?? true, min(f.width, f.height) >= 24,
                let a = try? faceSignature(in: img, face: f, kind: .appearance),
                let b = try? faceSignature(in: img, face: f, kind: .identity)
            {
                tracks[ti].appearance.append(a)
                tracks[ti].identity.append(b)
                tracks[ti].lastSample = i
            }
            followers[ti] = nil
            trackedRun[ti] = 0
        }

        // Follow the head of every track that was on screen in the previous frame but whose
        // face was not detected now.
        let detected = Set(faceTrack.compactMap { $0 })
        if let previous {
            for ti in active where !detected.contains(ti) && tracks[ti].lastFrame == i - 1 {
                guard (trackedRun[ti] ?? 0) < maxTrackedFrames else { continue }
                if followers[ti] == nil { followers[ti] = HeadFollower(box: tracks[ti].lastRect, in: previous) }
                if let r = followers[ti]?.follow(in: img) {
                    tracks[ti].detections.append(Detection(frame: i, rect: r, tracked: true))
                    trackedRun[ti, default: 0] += 1
                } else {
                    followers[ti] = nil
                    trackedRun[ti] = maxTrackedFrames  // lost: wait for the face detector
                }
            }
        }
        followers = followers.filter { active.contains($0.key) }
        previous = img
        progress(i + 1)
    }

    // Group tracks into people, longest tracks first.
    struct Group {
        var tracks: [Int] = []
        var frames = Set<Int>()
        var appearance: [FaceSignature] = []
        var identity: [FaceSignature] = []
    }
    var groups: [Group] = []
    for t in tracks.sorted(by: { $0.detections.count > $1.detections.count }) {
        let frames = Set(t.span)
        var bestGroup: (index: Int, d: Float)?
        if !t.appearance.isEmpty {
            for (gi, g) in groups.enumerated() where !g.appearance.isEmpty && g.frames.isDisjoint(with: frames) {
                var ds: [Float] = []
                for a in t.appearance { for b in g.appearance { if let d = try? distance(a, b) { ds.append(d) } } }
                if let m = median(ds), m <= mergeThreshold, bestGroup == nil || m < bestGroup!.d { bestGroup = (gi, m) }
            }
        }
        if let b = bestGroup {
            groups[b.index].tracks.append(t.id)
            groups[b.index].frames.formUnion(frames)
            groups[b.index].appearance += t.appearance.prefix(max(0, 24 - groups[b.index].appearance.count))
            groups[b.index].identity += t.identity
        } else {
            groups.append(Group(tracks: [t.id], frames: frames, appearance: t.appearance, identity: t.identity))
        }
    }

    let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    let ordered = groups.sorted { $0.frames.count > $1.frames.count }
    // "Maybe the same person": never on screen together and appearance fairly close.
    var similar = [[(Int, Float)]](repeating: [], count: ordered.count)
    for a in ordered.indices {
        for b in ordered.indices where b > a && ordered[a].frames.isDisjoint(with: ordered[b].frames) {
            var ds: [Float] = []
            for x in ordered[a].appearance { for y in ordered[b].appearance { if let d = try? distance(x, y) { ds.append(d) } } }
            guard let m = median(ds), m <= similarThreshold else { continue }
            similar[a].append((b + 1, m))
            similar[b].append((a + 1, m))
        }
    }
    let people = ordered.enumerated().map { (n, g) -> Person in
        let largest = g.tracks.compactMap { byID[$0]?.detections.filter { !$0.tracked }.max { $0.rect.width < $1.rect.width } }
            .sorted { $0.rect.width > $1.rect.width }
        return Person(
            id: n + 1, trackIDs: g.tracks, frameCount: g.frames.count, firstFrame: g.frames.min() ?? 0,
            samples: Array(largest.prefix(4)), identity: g.identity,
            similar: similar[n].sorted { $0.1 < $1.1 }.map(\.0))
    }
    return VideoFaces(
        times: times, tracks: tracks.sorted { $0.id < $1.id }, people: people, fps: info.fps, maxGapFrames: gapFrames)
}

/// Thumbnail of a detection (upright video frame).
public func faceThumbnail(asset: AVURLAsset, time: Double, rect: CGRect, size: CGFloat = 120) async throws -> CGImage {
    let (cg, _) = try await frameImage(asset: asset, at: time)
    return try thumbnail(CIImage(cgImage: cg), face: rect, size: size)
}


/// Follows one head region across frames with Vision object tracking.
private final class HeadFollower {
    private let handler = VNSequenceRequestHandler()
    private var request: VNTrackObjectRequest
    static let minConfidence: Float = 0.3
    /// Track a region 1.6× the face box: hair, ears and neck keep texture when the face turns
    /// away (with the face box alone the tracker lost a fast-moving turned head; ≥1.3 kept it,
    /// testdata/motion.mov, 2026-11-12).
    static let scale: CGFloat = 1.6

    /// `box` is where the head is in `image` (the last frame it was seen).
    init(box face: CGRect, in image: CIImage) {
        let box = scaled(face, Self.scale)
        let e = image.extent
        let norm = CGRect(
            x: (box.minX - e.minX) / e.width, y: (box.minY - e.minY) / e.height,
            width: box.width / e.width, height: box.height / e.height
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: norm))
        request.trackingLevel = .accurate
        // Prime the tracker on the frame where the box is known to be right.
        if (try? handler.perform([request], on: image)) != nil,
            let o = request.results?.first as? VNDetectedObjectObservation
        {
            request.inputObservation = o
        }
    }

    /// The head's box in the next frame, or nil when the tracker has lost it.
    func follow(in image: CIImage) -> CGRect? {
        guard (try? handler.perform([request], on: image)) != nil,
            let o = request.results?.first as? VNDetectedObjectObservation, o.confidence >= Self.minConfidence
        else { return nil }
        request.inputObservation = o
        let e = image.extent
        let r = CGRect(
            x: e.minX + o.boundingBox.minX * e.width, y: e.minY + o.boundingBox.minY * e.height,
            width: o.boundingBox.width * e.width, height: o.boundingBox.height * e.height)
        let face = scaled(r, 1 / Self.scale)
        let visible = face.intersection(e)
        guard !visible.isNull, visible.width * visible.height >= face.width * face.height * 0.3 else { return nil }
        return visible
    }
}
