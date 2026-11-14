import AVFoundation
import WipeMosaicCore

private func wipeSettings(_ c: CommonOptions) -> MosaicSettings {
    var s = MosaicSettings(wipes: c.wipes)
    s.minInside = c.minInside
    s.keepAllInWipe = c.keepAllInWipe
    s.render = c.render
    return s
}

func runMosaic(_ o: RunOptions) async throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: o.common.input.path) else { throw ToolError("input not found: \(o.common.input.path)") }
    guard o.common.input.standardizedFileURL != o.output.standardizedFileURL else {
        throw ToolError("output must differ from input")
    }
    let type = try fileType(for: o.output)
    if fm.fileExists(atPath: o.output.path), !o.overwrite {
        throw ToolError("output exists (use --overwrite): \(o.output.path)")
    }

    var stickers: [Int: Sticker] = [:]
    for (person, url) in o.common.stickerFiles.sorted(by: { $0.key < $1.key }) {
        guard fm.fileExists(atPath: url.path) else { throw ToolError("sticker image not found: \(url.path)") }
        let s = try Sticker(contentsOf: url)
        stickers[person] = s
        let scale = o.common.render.stickerScale
        print(String(format: "sticker for person %d: %@, covers %.0f%% of the face%@", person,
                     s.anchoredOnFace ? "laid face on face" : "no face in the image, opaque part laid on the face",
                     s.coverage(scale: scale) * 100, s.coversCore(scale: scale) ? "" : " (not all of the eyes, nose and mouth)"))
        if s.showsFace(scale: scale) {
            print(s.showsFace(scale: 4)
                  ? "  note: the face shows through this image (transparent or half-transparent parts), so it is also hidden under it; use an opaque image to hide it with the image alone"
                  : "  note: part of the face shows around this image, so it is also hidden under it; raise --sticker-scale to hide it with the image alone")
        }
        print("  hair, ears and the outline of the head can still show around a sticker")
    }

    let asset = AVURLAsset(url: o.common.input)
    let info = try await loadVideo(asset)
    print("video: \(Int(info.size.width))x\(Int(info.size.height))")

    let total = max(1, Int((info.fps * info.duration).rounded()))
    var last = Date()
    let report: (Int) -> Void = { n in
        guard Date().timeIntervalSince(last) > (o.progress ? 0.5 : 2) else { return }
        last = Date()
        if o.progress {
            print(String(format: "PROGRESS scan %.4f", min(0.99, Double(n) / Double(total))))
        } else {
            print("  scanned \(n) frames")
        }
    }

    var frames: [FrameFaces]
    var extra = ""
    if o.common.people.isEmpty && o.common.screenText {
        frames = []
    } else if o.common.people.isEmpty {
        let s = wipeSettings(o.common)
        try validateWipes(s.wipes, size: info.size)
        print("pass 1/2: detecting faces")
        frames = try scanFaces(asset: asset, info: info, settings: s, progress: report)
    } else {
        print("pass 1/2: detecting and grouping faces")
        let v = try analyzeFaces(
            asset: asset, info: info, tiles: o.common.render.tiles, tileInterval: o.common.render.tileInterval,
            progress: report)
        let missing = o.common.people.subtracting(v.people.map(\.id))
        guard missing.isEmpty else { throw ToolError("no such person: \(missing.sorted()) (found \(v.people.count))") }
        frames = v.frames(selected: o.common.people, endHold: o.common.render.hold, stickered: Set(stickers.keys))
        extra = "  people mosaicked:             \(o.common.people.sorted()) of \(v.people.count)\n"
    }
    if o.common.screenText {
        print("pass 1/2: reading on-screen text")
        let text = try analyzeText(asset: asset, info: info, workers: textWorkerCount(), progress: report)
        try checkLines(o.common.textLines, in: text)
        let options = TextMaskOptions(kinds: o.common.textKinds, words: o.common.textWords, lines: o.common.textLines, all: o.common.textAll)
        let mask = text.mask(options)
        frames = withText(frames, text: text, mask: mask)
        extra += "  text lines hidden:            \(mask.hidden.count) of \(text.entries.count)\n"
    }
    if o.progress { print("PROGRESS scan 1.0000") }

    print("pass 2/2: writing")
    if fm.fileExists(atPath: o.output.path) { try fm.removeItem(at: o.output) }  // --overwrite checked above
    let showProgress = o.progress
    var writeRender = o.common.render
    writeRender.stickers = stickers
    if !o.common.people.isEmpty { writeRender.hold = 0 }  // already applied per person by frames()
    let format: OutputFormat
    do {
        format = try await writeMosaic(
            asset: asset, info: info, frames: frames, render: writeRender, to: o.output, fileType: type
        ) { p in
            if showProgress { print(String(format: "PROGRESS render %.4f", p)) }
        }
    } catch {
        try? fm.removeItem(at: o.output)
        throw error
    }

    if let report = o.report {
        // mosaic_boxes: x:y:w:h in video pixels, top-left origin, before --pad.
        // sticker_boxes: person:x:y:w:h:estimated, same coordinates (the face box the image covers).
        var csv = "time_sec,mosaic_faces,other_faces,mosaic_boxes,text_boxes,sticker_boxes\n"
        let h = info.size.height
        for f in frames {
            let boxes = f.mosaic.map { String(format: "%.0f:%.0f:%.0f:%.0f", $0.minX, h - $0.maxY, $0.width, $0.height) }
            csv += String(format: "%.3f,%d,%d,", f.time, f.mosaic.count, f.kept.count) + boxes.joined(separator: " ")
                + ",\(f.exact.count),"
                + f.stickers.map {
                    // Last field 1: face estimated in this frame, a mosaic is drawn under the sticker.
                    String(format: "%d:%.0f:%.0f:%.0f:%.0f:%d", $0.person, $0.rect.minX, h - $0.rect.maxY, $0.rect.width,
                           $0.rect.height, $0.estimated ? 1 : 0)
                }
                .joined(separator: " ") + "\n"
        }
        try csv.write(to: report, atomically: true, encoding: .utf8)
        print("report: \(report.path)")
    }

    let dips = findDips(frames)
    print("""
        done: \(o.output.path)
          output format:                \(format)
          frames scanned:               \(frames.count)
          frames with mosaicked faces:  \(frames.filter { !$0.mosaic.isEmpty }.count) (max \(frames.map(\.mosaic.count).max() ?? 0) per frame)
          frames with sticker faces:    \(frames.filter { !$0.stickers.isEmpty }.count)
          frames with other faces:      \(frames.filter { !$0.kept.isEmpty }.count)
          frames with hidden text:      \(frames.filter { !$0.exact.isEmpty }.count)
        \(extra)  possible misses (count dips): \(dips.count)\(dips.prefix(10).map { String(format: " %.2fs", $0.start) }.joined())
        Review the output before publishing: detection can miss faces.
        """)
}

func runPreview(_ o: PreviewOptions) async throws {
    guard FileManager.default.fileExists(atPath: o.common.input.path) else {
        throw ToolError("input not found: \(o.common.input.path)")
    }
    let asset = AVURLAsset(url: o.common.input)
    let info = try await loadVideo(asset)
    let r = try await renderPreview(asset: asset, info: info, at: o.at, settings: wipeSettings(o.common))
    try writePNG(r.image, to: o.output)
    print("preview: \(o.output.path) at \(String(format: "%.3f", r.time))s: \(r.mosaicCount) mosaicked, \(r.keptCount) kept")
}

func listPeople(input: URL, outDir: URL?, render: RenderSettings, photos: [URL], match: URL?) async throws {
    let registered = try photos.map { try faceFromPhoto($0).signature }
    guard FileManager.default.fileExists(atPath: input.path) else { throw ToolError("input not found: \(input.path)") }
    let asset = AVURLAsset(url: input)
    let info = try await loadVideo(asset)
    let v = try analyzeFaces(asset: asset, info: info, tiles: render.tiles, tileInterval: render.tileInterval) { _ in }
    var other: VideoFaces?
    if let match {
        guard FileManager.default.fileExists(atPath: match.path) else { throw ToolError("not found: \(match.path)") }
        let a = AVURLAsset(url: match)
        other = try analyzeFaces(asset: a, info: try await loadVideo(a), tiles: render.tiles, tileInterval: render.tileInterval) { _ in }
    }
    if let outDir { try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) }
    print("people: \(v.people.count) (tracks \(v.tracks.count), frames \(v.times.count))")
    for p in v.people {
        let first = v.times[p.firstFrame]
        print(String(format: "  person %d: %.1fs on screen, first at %.2fs, %d track(s)", p.id, Double(p.frameCount) / max(info.fps, 1), first, p.trackIDs.count)
            + (p.similar.isEmpty ? "" : ", maybe same as \(p.similar.map { "person \($0)" }.joined(separator: ", "))"))
        let followed = v.tracks.filter { p.trackIDs.contains($0.id) }.flatMap(\.detections).filter(\.tracked)
        if !followed.isEmpty {
            print("    followed without a face: \(followed.count) frames, " + followed.map { String(format: "%.2f", v.times[$0.frame]) }.joined(separator: " ").prefix(400))
        }
        for (k, r) in registered.enumerated() {
            let d = v.distances(to: r)[p.id] ?? -1
            let hit = v.suggestions(registered: [r])[p.id] != nil
            print(String(format: "    distance to %@: %.3f%@", photos[k].lastPathComponent, d, hit ? "  (suggested)" : ""))
        }
        if let other {
            for q in other.people {
                let d = v.distances(to: q.id, in: other)[p.id] ?? -1
                let hit = v.matches(of: [q.id], in: other)[p.id] != nil
                print(String(format: "    distance to other person %d: %.3f%@", q.id, d, hit ? "  (suggested)" : ""))
            }
        }
        guard let outDir else { continue }
        for (k, s) in p.samples.enumerated() {
            let img = try await faceThumbnail(asset: asset, time: v.times[s.frame], rect: s.rect)
            try writePNG(img, to: outDir.appendingPathComponent("person-\(p.id)-\(k + 1).png"))
        }
    }
}

func printFaceDistances(_ urls: [URL]) throws {
    let faces = try urls.map { try faceFromPhoto($0) }
    let names = urls.map { $0.deletingPathExtension().lastPathComponent }
    print("photo," + names.joined(separator: ","))
    for i in faces.indices {
        let row = try faces.indices.map { j in String(format: "%.3f", try distance(faces[i].signature, faces[j].signature)) }
        print(names[i] + "," + row.joined(separator: ","))
    }
}

func printInfo(_ url: URL) async throws {
    guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("input not found: \(url.path)") }
    let info = try await loadVideo(AVURLAsset(url: url))
    let obj: [String: Any] = [
        "width": Int(info.size.width), "height": Int(info.size.height), "duration": info.duration, "fps": info.fps,
    ]
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func writeFrame(input: URL, at: Double, output: URL) async throws {
    guard FileManager.default.fileExists(atPath: input.path) else { throw ToolError("input not found: \(input.path)") }
    let asset = AVURLAsset(url: input)
    _ = try await loadVideo(asset)
    let (cg, _) = try await frameImage(asset: asset, at: at)
    try writePNG(cg, to: output)
}

/// `--lines` numbers must be lines of this video (they change when the video differs).
func checkLines(_ lines: Set<Int>, in text: ScreenText) throws {
    let unknown = lines.subtracting(text.entries.map(\.id))
    guard unknown.isEmpty else {
        throw ToolError("no such line: \(unknown.sorted()) (found \(text.entries.count); see `wipe-mosaic text <input> --list`)")
    }
}

func listText(input: URL, options: TextMaskOptions, list: Bool) async throws {
    guard FileManager.default.fileExists(atPath: input.path) else { throw ToolError("input not found: \(input.path)") }
    let asset = AVURLAsset(url: input)
    let info = try await loadVideo(asset)
    let started = Date()
    let text = try analyzeText(asset: asset, info: info, workers: textWorkerCount()) { _ in }
    let elapsed = Date().timeIntervalSince(started)
    try checkLines(options.lines, in: text)
    let mask = text.mask(options)
    let recognized = Set(text.tracks.flatMap { t in t.sampleFrames }).count
    print(String(format: "text: %d lines (%d tracks), %d frames, recognized %d frames, %.1fs", text.entries.count,
                 text.tracks.count, text.times.count, recognized, elapsed))
    for k in TextKind.allCases {
        print("  \(k.rawValue): \(text.entries.filter { $0.kinds.contains(k) }.count) lines")
    }
    print("  hidden with these options: \(mask.hidden.count) lines, word hits: \(mask.wordHits.count)")
    print("  frames with hidden text: \(mask.frames.filter { !$0.isEmpty }.count)")
    guard list else { return }
    for e in text.entries {
        let kinds = e.kinds.map(\.rawValue).sorted().joined(separator: ",")
        print(String(format: "  %3d %6.2fs %5.1fs %@ [%@] ", e.id, text.times[e.firstFrame], Double(e.frameCount) / max(info.fps, 1),
                     mask.hidden.contains(e.id) ? "H" : "-", kinds) + e.text)
    }
}
