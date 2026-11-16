import AVFoundation
import CoreImage
import CoreML

// Plates found by a detector (a Core ML model that finds the shape of a plate, without reading
// it), not by reading their numbers: reading found a plate only where its number could be
// read, and left most small or blurred plates of a street video showing (2026-11-17).
//
// The model takes a square picture of `plateModelSide` and gives, for each of its candidate
// boxes, the corners (x1 y1 x2 y2, in pixels of that picture, from the top left) and a score.
// It is not in the repository (see docs/DEVELOPMENT.md): without it, plates are found by
// reading as before.

/// Side of the detector's input, in pixels.
let plateModelSide = 608
/// Least score of a box taken for a plate. Low: a plate left showing is worse than a mosaic on
/// something that is no plate.
let plateMinScore: Float = 0.25
/// Seconds between the frames the detector looks at; a plate is moved in a straight line
/// between two of them.
let plateDetectInterval = 0.1
/// Detections a plate may be missed at (blurred, hidden by a post for a moment) and still be
/// the same plate at the next one.
let plateMaxMissed = 3
/// Seconds a plate is held on before its first and after its last detection, moving on as it
/// did: it is there before it is large or sharp enough to be found.
let plateHold = 0.2

/// Where the model is: named by `WIPE_MOSAIC_PLATE_MODEL`, in the app's resources, beside the
/// program, or in `Models/` of the repository the program was built in.
func plateModelURL() -> URL? {
    let name = "PlateDetector.mlmodelc"
    var candidates: [URL] = []
    if let p = ProcessInfo.processInfo.environment["WIPE_MOSAIC_PLATE_MODEL"], !p.isEmpty { candidates.append(URL(fileURLWithPath: p)) }
    if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent(name)) }
    if let e = Bundle.main.executableURL?.resolvingSymlinksInPath() {
        var dir = e.deletingLastPathComponent()
        candidates.append(dir.appendingPathComponent(name))
        for _ in 0..<5 {
            dir = dir.deletingLastPathComponent()
            candidates.append(dir.appendingPathComponent("Models").appendingPathComponent(name))
        }
    }
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
}

/// Whether plates are found by the detector (its model is there).
public var plateDetectorAvailable: Bool { plateModelURL() != nil }

/// A plate found in one frame (Core Image coordinates of the upright frame).
struct PlateBox {
    var rect: CGRect
    var score: Float
}

/// The square parts of a frame the detector looks at: squares of the frame's short side (near,
/// large plates), and squares of 0.6 of it, not less than the model's side (far, small ones: a
/// 4K frame shrunk whole to the model's side leaves a far plate 3 pixels wide). Each half a
/// square apart, so a plate cut at the edge of one is whole in the next.
func plateWindows(_ size: CGSize) -> [CGRect] {
    let short = min(size.width, size.height)
    var sides = [short]
    let small = max(CGFloat(plateModelSide), (short * 0.6).rounded())
    if small < short * 0.9 { sides.append(small) }
    var windows: [CGRect] = []
    for side in sides {
        func starts(_ length: CGFloat) -> [CGFloat] {
            guard length > side else { return [0] }
            var v: [CGFloat] = []
            var x: CGFloat = 0
            while x + side < length {
                v.append(x)
                x += (side / 2).rounded()
            }
            v.append(length - side)
            return v
        }
        for y in starts(size.height) { for x in starts(size.width) { windows.append(CGRect(x: x, y: y, width: side, height: side)) } }
    }
    return windows
}

/// The boxes kept of those found in all the windows of a frame: the best first, without those
/// that are the same plate as one kept (found again in another window: half of the smaller
/// one inside it).
func mergedPlates(_ found: [PlateBox]) -> [PlateBox] {
    var kept: [PlateBox] = []
    for b in found.sorted(by: { $0.score > $1.score }) {
        let same = kept.contains { k in
            let i = k.rect.intersection(b.rect)
            guard !i.isNull else { return false }
            return i.width * i.height > 0.5 * min(k.rect.width * k.rect.height, b.rect.width * b.rect.height)
        }
        if !same { kept.append(b) }
    }
    return kept
}

/// A plate's detections joined over time.
struct PlateTrack {
    var frames: [Int] = []
    var rects: [CGRect] = []
}

/// Joins the detections of each looked-at frame (`frames`, increasing) into plates: a
/// detection goes on the plate that was last seen nearest to where it would be now (moving on
/// as between its last two detections) and of a like size (half to twice as wide, and as high).
/// How near: a plate seen twice, within 1.5 of its widths of where it would be; a plate seen
/// once (its motion not known), within 5 widths along and 1.5 heights up or down for each
/// `plateDetectInterval` since (a car passing near moves its plate 3 widths in 0.1 s: within
/// 2.5 widths, its plate was taken for a new one each time and joined to other cars' plates).
/// One that was missed `plateMaxMissed` times, and a cut (`cuts`: the first frame after each),
/// end a plate.
func joinPlates(frames: [Int], detections: [[CGRect]], times: [Double], cuts: Set<Int>) -> [PlateTrack] {
    var done: [PlateTrack] = []
    var open: [(track: PlateTrack, missed: Int)] = []
    var lastFrame = -1
    for (n, f) in frames.enumerated() {
        if lastFrame >= 0, cuts.contains(where: { $0 > lastFrame && $0 <= f }) {
            done += open.map(\.track)
            open = []
        }
        lastFrame = f
        func expected(_ t: PlateTrack) -> CGRect {
            let last = t.rects[t.rects.count - 1]
            guard t.rects.count >= 2 else { return last }
            let prev = t.rects[t.rects.count - 2]
            let dt = times[t.frames[t.frames.count - 1]] - times[t.frames[t.frames.count - 2]]
            let k = CGFloat((times[f] - times[t.frames[t.frames.count - 1]]) / max(dt, 1e-6))
            return last.offsetBy(dx: (last.midX - prev.midX) * k, dy: (last.midY - prev.midY) * k)
        }
        var pairs: [(d: CGFloat, o: Int, b: Int)] = []
        for (o, t) in open.enumerated() {
            let e = expected(t.track)
            let steps = CGFloat(max(1, (times[f] - times[t.track.frames[t.track.frames.count - 1]]) / plateDetectInterval))
            for (b, r) in detections[n].enumerated() {
                let dx = abs(e.midX - r.midX), dy = abs(e.midY - r.midY)
                let w = max(e.width, r.width), h = max(e.height, r.height)
                let ratio = r.width / max(e.width, 1), ratioH = r.height / max(e.height, 1)
                guard ratio > 0.5, ratio < 2, ratioH > 0.5, ratioH < 2 else { continue }
                let near = t.track.rects.count >= 2 ? hypot(dx, dy) <= 1.5 * w * steps : dx <= 5 * w * steps && dy <= 1.5 * h * steps
                // A plate whose motion is known comes first.
                if near { pairs.append((hypot(dx, dy) / w + (t.track.rects.count >= 2 ? 0 : 2), o, b)) }
            }
        }
        var usedOpen = Set<Int>(), usedBox = Set<Int>()
        for p in pairs.sorted(by: { $0.d < $1.d }) where !usedOpen.contains(p.o) && !usedBox.contains(p.b) {
            usedOpen.insert(p.o)
            usedBox.insert(p.b)
            open[p.o].track.frames.append(f)
            open[p.o].track.rects.append(detections[n][p.b])
            open[p.o].missed = 0
        }
        for o in open.indices where !usedOpen.contains(o) { open[o].missed += 1 }
        done += open.filter { $0.missed > plateMaxMissed }.map(\.track)
        open.removeAll { $0.missed > plateMaxMissed }
        for (b, r) in detections[n].enumerated() where !usedBox.contains(b) {
            open.append((PlateTrack(frames: [f], rects: [r]), 0))
        }
    }
    return done + open.map(\.track)
}

/// The boxes to hide in every frame for the plates `tracks`: each plate where it was found,
/// in a straight line between two detections, and held on `plateHold` before the first and
/// after the last one (moving on as it did, not across a cut). Room is added around a box:
/// 0.2 of its width and 0.25 of its height (the detector's box is the plate itself), and a
/// quarter of the way it moves between two detections (a car does not move quite evenly).
func plateBoxes(_ tracks: [PlateTrack], times: [Double], cuts: [Int], bounds: CGRect) -> [[CGRect]] {
    var boxes = [[CGRect]](repeating: [], count: times.count)
    func add(_ r: CGRect, moved: CGSize, at f: Int) {
        let c = r.insetBy(dx: -0.2 * r.width - 0.25 * moved.width, dy: -0.25 * r.height - 0.25 * moved.height).intersection(bounds)
        if !c.isNull, !c.isEmpty { boxes[f].append(c) }
    }
    for t in tracks {
        for k in t.frames.indices {
            let f = t.frames[k]
            guard k + 1 < t.frames.count else {
                add(t.rects[k], moved: .zero, at: f)
                break
            }
            let g = t.frames[k + 1]
            let a = t.rects[k], b = t.rects[k + 1]
            let moved = CGSize(width: abs(b.midX - a.midX), height: abs(b.midY - a.midY))
            for i in f..<g {
                let u = CGFloat((times[i] - times[f]) / max(times[g] - times[f], 1e-6))
                add(lerp(a, b, u), moved: moved, at: i)
            }
        }
        // Before the first and after the last detection.
        func hold(from k: Int, toward step: Int) {
            let f = t.frames[k], r = t.rects[k]
            var velocity = CGPoint.zero  // per second
            let j = k - step
            if j >= 0, j < t.frames.count {
                let dt = CGFloat(times[f] - times[t.frames[j]])
                if abs(dt) > 1e-6 { velocity = CGPoint(x: (r.midX - t.rects[j].midX) / dt, y: (r.midY - t.rects[j].midY) / dt) }
            }
            var i = f + step
            while i >= 0, i < times.count, abs(times[i] - times[f]) <= plateHold + 1e-6 {
                // Not onto the frames of another shot.
                if step > 0 ? cuts.contains(where: { $0 > f && $0 <= i }) : cuts.contains(where: { $0 > i && $0 <= f }) { break }
                let dt = CGFloat(times[i] - times[f])
                let moved = CGSize(width: abs(velocity.x * dt), height: abs(velocity.y * dt))
                add(r.offsetBy(dx: velocity.x * dt, dy: velocity.y * dt), moved: CGSize(width: moved.width * 2, height: moved.height * 2), at: i)
                i += step
            }
        }
        hold(from: 0, toward: -1)
        hold(from: t.frames.count - 1, toward: 1)
    }
    return boxes
}

/// Runs the model on the windows of a frame.
final class PlateDetector {
    private let model: MLModel
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let buffers: [CVPixelBuffer]

    init?(windows: Int) throws {
        guard let url = plateModelURL() else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: config)
        var made: [CVPixelBuffer] = []
        for _ in 0..<max(1, windows) {
            var pb: CVPixelBuffer?
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
            guard CVPixelBufferCreate(nil, plateModelSide, plateModelSide, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else {
                throw ToolError("ナンバープレートの検出に使う画像を用意できませんでした")
            }
            made.append(pb)
        }
        buffers = made
    }

    /// The plates in `image` (the upright frame), found in each of `windows`.
    func detect(_ image: CIImage, windows: [CGRect]) throws -> [PlateBox] {
        let side = CGFloat(plateModelSide)
        let bounds = image.extent
        var inputs: [MLFeatureProvider] = []
        for (n, w) in windows.enumerated() {
            let scale = side / w.width
            let part = image.cropped(to: w.offsetBy(dx: bounds.minX, dy: bounds.minY))
                .transformed(by: CGAffineTransform(translationX: -w.minX - bounds.minX, y: -w.minY - bounds.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            context.render(part, to: buffers[n], bounds: CGRect(x: 0, y: 0, width: side, height: side), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            inputs.append(try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffers[n])]))
        }
        let results = try model.predictions(fromBatch: MLArrayBatchProvider(array: inputs))
        var found: [PlateBox] = []
        for (n, w) in windows.enumerated() {
            let out = results.features(at: n)
            guard let boxes = out.featureValue(for: "boxes")?.multiArrayValue, let scores = out.featureValue(for: "scores")?.multiArrayValue else {
                throw ToolError("ナンバープレートの検出の結果を読めませんでした")
            }
            let s = MLShapedArray<Float>(converting: scores).scalars
            let b = MLShapedArray<Float>(converting: boxes).scalars
            guard b.count == 4 * s.count else { throw ToolError("ナンバープレートの検出の結果の形が違います（\(b.count) と \(s.count)）") }
            let unit = w.width / side
            for i in s.indices where s[i] >= plateMinScore {
                let x1 = CGFloat(b[4 * i]), y1 = CGFloat(b[4 * i + 1]), x2 = CGFloat(b[4 * i + 2]), y2 = CGFloat(b[4 * i + 3])
                guard x2 > x1, y2 > y1 else { continue }
                // Cut at a side of the window inside the frame: whole in the next window.
                let edge: CGFloat = 2
                if (x1 < edge && w.minX > 0.5) || (x2 > side - edge && w.maxX < bounds.width - 0.5)
                    || (y1 < edge && w.maxY < bounds.height - 0.5) || (y2 > side - edge && w.minY > 0.5) { continue }
                // The model counts rows from the top; the frame from the bottom.
                found.append(PlateBox(
                    rect: CGRect(x: w.minX + x1 * unit, y: w.maxY - y2 * unit, width: (x2 - x1) * unit, height: (y2 - y1) * unit), score: s[i]))
            }
        }
        return mergedPlates(found)
    }
}

/// The boxes to hide for the plates of a video, for every frame of `times`, and the number of
/// plates; nil without the model. The detector looks at a frame every `plateDetectInterval`.
/// `progress` gets the share done (0...1).
func detectPlates(
    asset: AVURLAsset, info: VideoInfo, times: [Double], cuts: [Int], progress: (Double) -> Void
) throws -> (boxes: [[CGRect]], count: Int)? {
    let windows = plateWindows(info.size)
    guard !times.isEmpty, let detector = try PlateDetector(windows: windows.count) else { return nil }
    var frames: [Int] = []
    var detections: [[CGRect]] = []
    var lastTime = -Double.infinity
    try forEachFrame(asset: asset, info: info) { _, t, image in
        let i = times.partitionIndex { $0 >= t - 1e-4 }
        guard i < times.count, abs(times[i] - t) < 1e-3 else { return }
        progress(Double(i) / Double(times.count))
        guard t - lastTime >= plateDetectInterval - 1e-6 || i == times.count - 1 else { return }
        lastTime = t
        frames.append(i)
        detections.append(try detector.detect(image, windows: windows).map(\.rect))
    }
    let tracks = joinPlates(frames: frames, detections: detections, times: times, cuts: Set(cuts))
    return (plateBoxes(tracks, times: times, cuts: cuts, bounds: CGRect(origin: .zero, size: info.size)), tracks.count)
}
