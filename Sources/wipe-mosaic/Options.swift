import CoreGraphics
import Foundation
import WipeMosaicCore

struct CommonOptions {
    var input: URL
    /// Wipe mode: regions in video pixels, top-left origin.
    var wipes: [CGRect] = []
    /// People mode: person numbers (from `people`) to mosaic.
    var people: Set<Int> = []
    /// Screen-text mode: hide personal information in on-screen text.
    var screenText = false
    var textKinds: Set<TextKind> = Set(TextKind.allCases)
    var textWords: [String] = []
    var textLines: Set<Int> = []
    var minInside = 0.8
    var keepAllInWipe = false
    var render = RenderSettings()
}

struct RunOptions {
    var common: CommonOptions
    var output: URL
    var overwrite = false
    var report: URL?
    var progress = false
}

struct PreviewOptions {
    var common: CommonOptions
    var at: Double
    var output: URL
}

enum Command {
    case run(RunOptions)
    case preview(PreviewOptions)
    case info(URL)
    case frame(input: URL, at: Double, output: URL)
    case facesDist([URL])
    case people(input: URL, outDir: URL?, render: RenderSettings, photos: [URL], match: URL?)
    case text(input: URL, options: TextMaskOptions, list: Bool)
    case help
}

let usage = """
    wipe-mosaic: pixelate faces on-device (no network).

    MODES
      --wipe x,y,w,h          Mosaic every face except the presenter inside the wipe.
      --people 1,3            Mosaic only these people (numbers from `wipe-mosaic people`).
      --screen-text           Mosaic personal information in on-screen text (screen recordings).
                              Can be combined with --people.

    USAGE
      wipe-mosaic people <input> [-o <dir>] [--photo <img>]... (list people; thumbnails into dir;
                                                    distance to registered photos)
      wipe-mosaic people <input> --match <other video>   (distance from each person to the
                                                    people of another video)
      wipe-mosaic text <input> [--text-kinds ...] [--words ...] [--list]
                                                   (text found on screen; --list prints the text)
      wipe-mosaic run <input> <output> (--wipe ... | --people ... | --screen-text) [options]
      wipe-mosaic preview <input> --wipe ... --at <seconds> -o <png> [options]
      wipe-mosaic info <input>                          (JSON: width, height, duration, fps)
      wipe-mosaic frame <input> --at <seconds> -o <png>  (raw frame, no detection)
      wipe-mosaic faces-dist <photo>...                  (pairwise face distances)

    OPTIONS
      --min-inside <0-1>   Wipe: fraction of a face box that must be inside the wipe (0.8)
      --keep-all-in-wipe   Wipe: keep all faces inside the wipe (default: only the largest)
      --pad <ratio>        Expand mosaic around each face (default 0.45)
      --block <px>         Mosaic block size (default: longest side / 60)
      --tiles <n>          Also detect on an n x n grid for small faces (default: people 4, wipe 3; 1 = off)
      --hold <seconds>     Keep the mosaic before/after a face is seen (default: people 1.0, wipe 0.3)
      --tile-interval <s>  People: tile passes only every <s> seconds (default 0.1; 0 = every frame)
      --text-kinds <list>  Screen text: kinds to hide, from number,email,url,address (default all; none = off)
      --words <list>       Screen text: also hide these words, comma-separated (e.g. a name)
      --lines <list>       Screen text: hide these lines whole (numbers from `wipe-mosaic text --list`)
      --overwrite          Overwrite an existing output file (run only)
      --report <csv>       Write per-frame face counts for review (run only)
      --progress           Print "PROGRESS <scan|render> <0-1>" lines (run only)

    Output keeps the source codec, bit depth and color tags (bitrate +30%); audio is copied.
    Output to stdout contains only counts; no image content is printed (text --list prints
    the recognized text on request).
    """

private func parseRect(_ s: String) throws -> CGRect {
    let parts = s.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3],
        w > 0, h > 0
    else { throw ToolError("invalid --wipe '\(s)'; expected x,y,w,h with w,h > 0") }
    return CGRect(x: x, y: y, width: w, height: h)
}

private func parseDouble(_ s: String?, _ name: String, range: ClosedRange<Double>) throws -> Double {
    guard let s, let v = Double(s), range.contains(v) else {
        throw ToolError("\(name) needs a number in \(range.lowerBound)...\(range.upperBound)")
    }
    return v
}

extension Command {
    static func parse(_ args: [String]) throws -> Command {
        guard let sub = args.first, sub != "-h", sub != "--help", sub != "help" else { return .help }
        guard ["run", "preview", "info", "frame", "faces-dist", "people", "text"].contains(sub) else {
            throw ToolError("unknown command '\(sub)'\n\n\(usage)")
        }

        var positional: [String] = []
        var c = CommonOptions(input: URL(fileURLWithPath: "/"))
        var at: Double?
        var out: String?
        var report: String?
        var overwrite = false, progress = false
        var photos: [URL] = []
        var match: URL?
        var tilesGiven = false, holdGiven = false
        var list = false

        var it = args.dropFirst().makeIterator()
        func value(_ a: String) throws -> String {
            guard let v = it.next() else { throw ToolError("\(a) needs a value") }
            return v
        }
        while let a = it.next() {
            switch a {
            case "--wipe": c.wipes.append(try parseRect(try value(a)))
            case "--people":
                let ids = try value(a).split(separator: ",").map { s -> Int in
                    guard let n = Int(s), n > 0 else { throw ToolError("--people expects numbers like 1,3") }
                    return n
                }
                c.people.formUnion(ids)
            case "--min-inside": c.minInside = try parseDouble(it.next(), a, range: 0.01...1)
            case "--pad": c.render.pad = try parseDouble(it.next(), a, range: 0...5)
            case "--block": c.render.block = try parseDouble(it.next(), a, range: 2...1000)
            case "--tiles":
                c.render.tiles = Int(try parseDouble(it.next(), a, range: 1...6))
                tilesGiven = true
            case "--hold":
                c.render.hold = try parseDouble(it.next(), a, range: 0...10)
                holdGiven = true
            case "--tile-interval": c.render.tileInterval = try parseDouble(it.next(), a, range: 0...1)
            case "--at": at = try parseDouble(it.next(), a, range: 0...1_000_000)
            case "-o", "--output": out = try value(a)
            case "--report": report = try value(a)
            case "--photo": photos.append(URL(fileURLWithPath: try value(a)))
            case "--match": match = URL(fileURLWithPath: try value(a))
            case "--screen-text": c.screenText = true
            case "--text-kinds":
                let v = try value(a)
                c.textKinds = try v == "none" ? [] : Set(v.split(separator: ",").map { s -> TextKind in
                    guard let k = TextKind(rawValue: String(s)) else {
                        throw ToolError("--text-kinds expects number,email,url,address or none")
                    }
                    return k
                })
            case "--words":
                c.textWords = try value(a).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "--lines":
                let ids = try value(a).split(separator: ",").map { s -> Int in
                    guard let n = Int(s), n > 0 else { throw ToolError("--lines expects numbers like 2,5") }
                    return n
                }
                c.textLines.formUnion(ids)
            case "--list": list = true
            case "--keep-all-in-wipe": c.keepAllInWipe = true
            case "--overwrite": overwrite = true
            case "--progress": progress = true
            default:
                if a.hasPrefix("-") { throw ToolError("unknown option '\(a)'") }
                positional.append(a)
            }
        }

        // People mode searches tiles only every --tile-interval, so it can afford a finer grid.
        if !tilesGiven && (sub == "people" || !c.people.isEmpty) { c.render.tiles = 4 }
        // People mode: keep the mosaic 1 s before/after each appearance (wipe mode: 0.3 s).
        if !holdGiven && !c.people.isEmpty { c.render.hold = 1.0 }

        switch sub {
        case "info":
            guard positional.count == 1 else { throw ToolError("info needs <input>") }
            return .info(URL(fileURLWithPath: positional[0]))
        case "frame":
            guard positional.count == 1, let at, let out else { throw ToolError("frame needs <input> --at <s> -o <png>") }
            return .frame(input: URL(fileURLWithPath: positional[0]), at: at, output: URL(fileURLWithPath: out))
        case "faces-dist":
            guard positional.count >= 2 else { throw ToolError("faces-dist needs at least two photos") }
            return .facesDist(positional.map { URL(fileURLWithPath: $0) })
        case "people":
            guard positional.count == 1 else { throw ToolError("people needs <input>") }
            return .people(
                input: URL(fileURLWithPath: positional[0]), outDir: out.map { URL(fileURLWithPath: $0) },
                render: c.render, photos: photos, match: match)
        case "text":
            guard positional.count == 1 else { throw ToolError("text needs <input>") }
            return .text(
                input: URL(fileURLWithPath: positional[0]),
                options: TextMaskOptions(kinds: c.textKinds, words: c.textWords, lines: c.textLines), list: list)
        default: break
        }

        guard c.wipes.isEmpty != (c.people.isEmpty && !c.screenText) else {
            throw ToolError("use either --wipe, or --people and/or --screen-text")
        }
        if sub == "run" {
            guard positional.count == 2 else { throw ToolError("run needs <input> <output>") }
            c.input = URL(fileURLWithPath: positional[0])
            return .run(
                RunOptions(
                    common: c, output: URL(fileURLWithPath: positional[1]), overwrite: overwrite,
                    report: report.map { URL(fileURLWithPath: $0) }, progress: progress))
        }
        guard !c.wipes.isEmpty else { throw ToolError("preview supports --wipe only") }
        guard positional.count == 1, let at, let out else { throw ToolError("preview needs <input> --at <s> -o <png>") }
        c.input = URL(fileURLWithPath: positional[0])
        return .preview(PreviewOptions(common: c, at: at, output: URL(fileURLWithPath: out)))
    }
}
