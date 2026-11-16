import AVFoundation
import CoreImage
import Vision

// Reading the text of a video: which frames to read, what was read in each, and the lines
// followed from frame to frame (`analyzeText`). The types are in Text.swift.

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
    // QR codes are followed by their own builder: a code is never matched to a line of text
    // (the words "QRコード" printed next to it, say).
    var codeBuilder = TrackBuilder(size: info.size)
    codeBuilder.codes = true
    // Codes found only by the closer look (every `deepCodeInterval`) miss the recognitions in
    // between: counted as missed, each would start a new track every time.
    codeBuilder.maxMissed = 2 * Int((deepCodeInterval / interval).rounded(.up)) + 2
    var times: [Double] = []
    let ctx = CIContext(options: [.cacheIntermediates: false])
    var lastRecognized = Int.min / 2
    var lastTime = -Double.infinity
    var lastThumb: [UInt8]?
    var lastLines: (lines: [(CGRect, String, VNRecognizedText?)], corners: [[CGPoint]?]) = ([], [])
    var lastCodes: (lines: [(CGRect, String, VNRecognizedText?)], corners: [[CGPoint]]) = ([], [])
    var unchangedUntil: Int?  // last frame identical to the last recognized one
    var lastDeep = -Double.infinity  // time of the last recognition that also looked for small QR codes
    var prevThumb: [UInt8]?  // of the previous frame
    var cuts: [Int] = []
    var pendingCut: Int?  // a change at once, a cut if the next frame looks like it

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
            builder.add(frame: u, lines: lastLines.lines, corners: lastLines.corners, pin: true)
            codeBuilder.add(frame: u, lines: lastCodes.lines, corners: lastCodes.corners.map { Optional($0) }, pin: true)
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
            lastCodes = codeLines(reading, bounds: bounds)
            // Read again only because time passed: a new line was there since the last
            // reading, too small a change to see (the picture looked the same).
            builder.add(frame: f, lines: lastLines.lines, corners: lastLines.corners, newSince: since)
            codeBuilder.add(frame: f, lines: lastCodes.lines, corners: lastCodes.corners.map { Optional($0) }, newSince: since)
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
        // A cut is a change at once that then holds: the frame after it looks like it. A fast
        // pan or shaking camera changes every frame and is not a cut (a code moves on there).
        if let c = pendingCut {
            if let p = prevThumb, !isCut(p, thumb) { cuts.append(c) }
            pendingCut = nil
        }
        if let p = prevThumb, isCut(p, thumb) { pendingCut = i }
        prevThumb = thumb
        let unchanged = lastThumb.map { !differs($0, thumb) } ?? false
        if unchanged, t - lastTime < recheck {
            unchangedUntil = i
        } else if t - lastTime >= interval - 1e-6 {
            // Pin the lines where they were until the picture started to change.
            if let u = unchangedUntil, u > lastRecognized { steps.append(.pin(u)) }
            // Small or slanted QR codes need a closer look (`recognizeText`), too slow for every
            // recognition: twice a second, and a code once found is followed in between.
            let deep = t - lastDeep >= deepCodeInterval - 1e-6
            if deep { lastDeep = t }
            if let pool {
                // Keep a few readings per worker in flight; more would only pile up results.
                while steps.count - applied >= 8 * workers { _ = try step(blocking: true) }
                try pool.submit(job: jobs, frame: i, deep: deep)
            } else {
                ownReading = try recognizeText(image, frame: i, time: t, deep: deep)
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
    if let c = pendingCut { cuts.append(c) }  // at the last frame: nothing after it to differ
    pool?.finish()
    while applied < steps.count {
        _ = try step(blocking: true)
        progress(done(decoded: times.count))
    }
    progress(times.count)

    var tracks = droppingMixedUpReadings(builder.tracks, times: times)
    for k in tracks.indices {
        tracks[k].measureTilt(times: times)  // before the parts, measured along a slanted line
        tracks[k].text = mostCommonReading(tracks[k])
        tracks[k].parts = kindParts(tracks[k], size: info.size)
    }
    addContinuations(&tracks, times: times, extend: interval + 0.25, bounds: bounds, size: info.size)
    for c in codeBuilder.tracks {
        var t = TextTrack(id: tracks.count, samples: c.samples)
        t.isCode = true
        t.text = codeText
        t.parts = [.qr: [whole]]
        tracks.append(t)
    }
    for k in tracks.indices { tracks[k].makeSteady(times: times) }
    // One entry per distinct text, in order of first appearance; one per place for QR codes
    // (a code and the codes that continue it), never with a line that reads "QRコード".
    let codeTracks = tracks.filter(\.isCode)
    var codePlace: [Int: Int] = [:]  // code track id → id of the first track of its place
    for (a, b) in ScreenText.continuations(of: codeTracks, times: times, all: false) ?? [:] {
        func root(_ id: Int) -> Int {
            var r = id
            while let p = codePlace[r], p != r { r = p }
            return r
        }
        let ra = root(a), rb = root(b.id)
        if ra != rb { codePlace[max(ra, rb)] = min(ra, rb) }
    }
    for t in codeTracks {
        var r = t.id
        while let p = codePlace[r], p != r { r = p }
        codePlace[t.id] = r
    }
    var groups: [String: [Int]] = [:]
    var order: [String] = []
    for (k, t) in tracks.enumerated().sorted(by: { $0.element.first < $1.element.first }) {
        let key = t.isCode ? "\u{0}code\(codePlace[t.id] ?? t.id)" : normalizedForMatch(t.text)
        if groups[key] == nil { order.append(key) }
        groups[key, default: []].append(k)
    }
    var codeNumber = 0
    let entries = order.enumerated().map { n, key -> TextEntry in
        let ks = groups[key]!
        let isCode = tracks[ks[0]].isCode
        if isCode { codeNumber += 1 }
        return TextEntry(
            id: n + 1, text: isCode ? "\(codeText) \(codeNumber)" : tracks[ks[0]].text, trackIDs: ks.map { tracks[$0].id },
            firstFrame: ks.map { tracks[$0].first }.min()!,
            frameCount: ks.reduce(0) { $0 + tracks[$1].last - tracks[$1].first + 1 },
            kinds: Set(ks.flatMap { tracks[$0].parts.keys }))
    }
    // Lines fade in and out over a few frames that cannot be read yet: continue each line a
    // little longer than the time between two recognitions.
    return ScreenText(
        times: times, fps: info.fps, size: info.size, tracks: tracks, entries: entries, extend: interval + 0.25, cuts: cuts)
}

/// Seconds between recognitions that also look for small QR codes (see `recognizeText`).
let deepCodeInterval = 0.5

/// Recognizes the text of one frame and finds its QR codes. With `deep`, QR codes are also
/// looked for in five overlapping parts of the frame (each 60 % of it) enlarged up to 2× and
/// sharpened: Vision missed most codes of 100–160 px, slanted or slightly out of focus, in
/// the whole frame and found them there (synthetic screen filmed at an angle with glare,
/// 2026-11-16). That costs ~110 ms (1080p, M3 Max), as much as reading the text.
func recognizeText(_ image: CIImage, frame: Int, time: Double, deep: Bool = false) throws -> TextReading {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate  // .fast does not read Japanese
    req.recognitionLanguages = ["ja-JP", "en-US"]
    req.usesLanguageCorrection = false  // keeps numbers and addresses as written
    let codes = codeRequest()
    try VNImageRequestHandler(ciImage: image, orientation: .up, options: [:]).perform([req, codes])
    let ext = image.extent
    var quads = (codes.results ?? []).map { codeQuad($0, size: ext.size, scale: 1) }
    if deep {
        let w = ext.width * 0.6, h = ext.height * 0.6
        for (fx, fy) in [(0.0, 0.0), (0.4, 0.0), (0.0, 0.4), (0.4, 0.4), (0.2, 0.2)] {
            let part = CGRect(x: ext.minX + ext.width * fx, y: ext.minY + ext.height * fy, width: w, height: h).integral
            // 2×, up to a long side of 2304 px (1080p: just 2×; a 4K part is as large as a
            // 1080p part enlarged, so a 4K code must be about twice as many pixels to be found).
            let scale = max(1, min(2, 2304 / max(part.width, part.height)))
            let size = CGSize(width: (part.width * scale).rounded(), height: (part.height * scale).rounded())
            let up = image.cropped(to: part)
                .transformed(by: CGAffineTransform(translationX: -part.minX, y: -part.minY))
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
                .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.5 * scale, kCIInputIntensityKey: 1.2])
                .cropped(to: CGRect(origin: .zero, size: size))  // sharpening spreads the extent
            let r = codeRequest()
            try VNImageRequestHandler(ciImage: up, orientation: .up, options: [:]).perform([r])
            let dx = part.minX - ext.minX, dy = part.minY - ext.minY
            quads += (r.results ?? []).map {
                codeQuad($0, size: size, scale: part.width / size.width)
                    .map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            }
        }
    }
    return TextReading(
        frame: frame, time: time, width: Int(ext.width), height: Int(ext.height),
        observations: req.results ?? [], codes: mergeCodeQuads(quads))
}

private func codeRequest() -> VNDetectBarcodesRequest {
    let r = VNDetectBarcodesRequest()
    r.symbologies = [.qr, .microQR]
    return r
}

/// A code's four corners (its top left, top right, bottom right, bottom left), in pixels of
/// the image it was found in, times `scale`.
private func codeQuad(_ o: VNBarcodeObservation, size: CGSize, scale: CGFloat) -> [CGPoint] {
    [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft].map { CGPoint(x: $0.x * size.width * scale, y: $0.y * size.height * scale) }
}

/// One quad per code (a code found in the whole frame and in parts of it, or in two parts):
/// the larger is kept of two where the centre of one lies in the other. (Overlapping boxes
/// would also join a small code in the corner of the box around a slanted large one.)
private func mergeCodeQuads(_ quads: [[CGPoint]]) -> [[CGPoint]] {
    func centre(_ q: [CGPoint]) -> CGPoint {
        CGPoint(x: q.reduce(0) { $0 + $1.x } / CGFloat(q.count), y: q.reduce(0) { $0 + $1.y } / CGFloat(q.count))
    }
    var out: [[CGPoint]] = []
    for q in quads {
        if let i = out.firstIndex(where: { quadContains($0, centre(q)) || quadContains(q, centre($0)) }) {
            if abs(signedArea(q)) > abs(signedArea(out[i])) { out[i] = q }
        } else {
            out.append(q)
        }
    }
    return out
}

/// The QR codes of one reading, as lines reading `codeText`, with their corners relative to
/// each box.
private func codeLines(_ r: TextReading, bounds: CGRect) -> (lines: [(CGRect, String, VNRecognizedText?)], corners: [[CGPoint]]) {
    var lines: [(CGRect, String, VNRecognizedText?)] = [], corners: [[CGPoint]] = []
    for q in r.codes {
        let box = boundingBox(q).intersection(bounds)
        guard !box.isNull, !box.isEmpty else { continue }
        lines.append((box, codeText, nil))
        corners.append(q.map { CGPoint(x: ($0.x - box.minX) / box.width, y: ($0.y - box.minY) / box.height) })
    }
    return (lines, corners)
}

/// What a QR code reads as in the list of text (its content is not shown).
let codeText = "QRコード"

/// The lines of one reading: box in the frame, the best candidate's string and the candidate,
/// and each line's corners (relative to its box; nil for a line cut at the picture's edge).
private func textLines(_ r: TextReading, bounds: CGRect) -> (lines: [(CGRect, String, VNRecognizedText?)], corners: [[CGPoint]?]) {
    var lines: [(CGRect, String, VNRecognizedText?)] = [], corners: [[CGPoint]?] = []
    for o in r.observations {
        guard let c = o.topCandidates(1).first, !c.string.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        let full = VNImageRectForNormalizedRect(o.boundingBox, r.width, r.height)
        let rect = full.intersection(bounds)
        guard !rect.isEmpty else { continue }
        lines.append((rect, c.string, c))
        let q = [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft].map { CGPoint(x: $0.x * CGFloat(r.width), y: $0.y * CGFloat(r.height)) }
        corners.append(bounds.insetBy(dx: -0.5, dy: -0.5).contains(full) ? q.map { CGPoint(x: ($0.x - rect.minX) / rect.width, y: ($0.y - rect.minY) / rect.height) } : nil)
    }
    return (lines, corners)
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

/// The picture changed at once (a cut, a switch to another layout): 40 % of the thumbnail
/// changed a lot. A shaking camera or a fade changes far less from one frame to the next.
private func isCut(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count, !a.isEmpty else { return true }
    var changed = 0
    for k in a.indices where abs(Int(a[k]) - Int(b[k])) > 48 { changed += 1 }
    return changed * 10 >= a.count * 4
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
struct TrackBuilder {
    let size: CGSize
    var maxMissed = 2
    /// QR codes: all read the same, so a code is joined only to a track whose last code it
    /// overlaps (the centre of one inside the other). Two codes side by side, one of them not
    /// read for a while, were otherwise joined into one track whose mosaic moved to the other
    /// code and left the first bare; apart, each is continued (`ScreenText.continuations`).
    var codes = false
    var tracks: [TextTrack] = []
    private var pass = 0
    private var lastPass: [Int] = []  // per track

    init(size: CGSize) { self.size = size }

    /// `pin`: the lines of the last recognition again, at the last frame before the picture
    /// changed. Not a new recognition, so it does not count toward `maxMissed`.
    /// `newSince`: lines not matched to a track have been there since this frame.
    /// `corners`: each line's (or code's) `TextSample.corners`.
    mutating func add(
        frame: Int, lines: [(CGRect, String, VNRecognizedText?)], corners: [[CGPoint]?]? = nil, pin: Bool = false, newSince: Int? = nil
    ) {
        if !pin { pass += 1 }
        let open = tracks.indices.filter { tracks[$0].last < frame && pass - lastPass[$0] <= maxMissed + 1 }
        let heights = lines.indices.map { l in TextSample(frame: frame, rect: lines[l].0, string: "", text: nil, corners: corners?[l] ?? nil).lineHeight }
        var matches = matchLines(
            lines.map { ($0.0, $0.1) },
            to: open.map { (tracks[$0].samples.last!.rect, tracks[$0].samples.last!.string, tracks[$0].last) },
            frame: frame, size: size,
            heights: (heights, open.map { tracks[$0].samples.last!.lineHeight }))
        if codes {
            matches = matches.filter { l, o in
                let prev = tracks[open[o]].samples.last!
                return overlaps(quadOf(lines[l].0, corners?[l] ?? nil), quadOf(prev.rect, prev.corners))
            }
        }
        var usedLines = Set<Int>()
        for (l, o) in matches {
            let k = open[o]
            usedLines.insert(l)
            let (rect, string, text) = lines[l]
            let isNew = !tracks[k].samples.contains { $0.string == string }
            tracks[k].samples.append(TextSample(frame: frame, rect: rect, string: string, text: isNew ? text : nil, corners: corners?[l] ?? nil))
            lastPass[k] = pass
        }
        for (l, (rect, string, text)) in lines.enumerated() where !usedLines.contains(l) {
            var samples = [TextSample(frame: frame, rect: rect, string: string, text: text, corners: corners?[l] ?? nil)]
            if let since = newSince, since < frame {
                samples.insert(TextSample(frame: since, rect: rect, string: string, text: nil, corners: corners?[l] ?? nil), at: 0)
            }
            tracks.append(TextTrack(id: tracks.count, samples: samples))
            lastPass.append(pass)
        }
    }
}

/// The quad of a box with corners relative to it (`TextSample.corners`), or the box itself.
private func quadOf(_ r: CGRect, _ corners: [CGPoint]?) -> [CGPoint] {
    if let c = corners, c.count == 4 { return place(c, in: r) }
    return [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.minY)]
}

/// The centre of one quad lies in the other.
private func overlaps(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
    func centre(_ q: [CGPoint]) -> CGPoint {
        CGPoint(x: q.map(\.x).reduce(0, +) / CGFloat(q.count), y: q.map(\.y).reduce(0, +) / CGFloat(q.count))
    }
    return quadContains(a, centre(b)) || quadContains(b, centre(a))
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
    frame: Int, size: CGSize, heights: (lines: [CGFloat], tracks: [CGFloat])? = nil
) -> [(line: Int, track: Int)] {
    let lineKeys = lines.map { normalizedForMatch($0.string) }
    let trackKeys = tracks.map { normalizedForMatch($0.string) }
    var pairs: [(cost: Double, sim: Double, line: Int, track: Int)] = []
    for (l, line) in lines.enumerated() {
        for (k, prev) in tracks.enumerated() {
            // The lines' own heights where known (`TextSample.lineHeight`), else their boxes.
            let ratio = heights.map { $0.lines[l] / max($0.tracks[k], 1) } ?? line.rect.height / max(prev.rect.height, 1)
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
