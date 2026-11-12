import AVFoundation
import AppKit
import Observation
import WipeMosaicCore

enum AnalysisState: Equatable {
    case loading, converting, waiting, running(Double), done, cancelled, failed(String)
}

enum JobState: Equatable {
    case idle
    case queued
    case writing(Double)
    case done
    case failed(String)
    case cancelled

    var isRunning: Bool { if case .writing = self { true } else { false } }
    /// Writing or waiting in the export queue.
    var isActive: Bool { self == .queued || isRunning }
}

/// Everything besides the checks that changes the written mosaic. A result made with
/// different values is out of date.
struct MosaicParams: Equatable {
    var hold: Double
    var pad: Double
    /// nil = automatic block size.
    var block: Double?
}

struct JobSummary {
    let output: URL
    let format: OutputFormat
    let frames: Int
    let mosaicFrames: Int
    let dips: [Dip]
    let elapsed: TimeInterval
    let selection: Set<Int>
    let params: MosaicParams
}

/// One video in the list, with its own faces, selection, player item and export result.
@MainActor
@Observable
final class VideoItem: Identifiable {
    let id = UUID()
    let url: URL
    /// The file actually read: the original, or a temporary rewrapped .mov (see Remux).
    @ObservationIgnored var asset: AVURLAsset
    @ObservationIgnored var remuxed: URL?
    @ObservationIgnored let live = LiveMosaic()
    @ObservationIgnored var sourceItem: AVPlayerItem?
    @ObservationIgnored var resultItem: AVPlayerItem?
    @ObservationIgnored var composition: AVVideoComposition?
    @ObservationIgnored let scoped: Bool
    /// Playback position, restored when the video is shown again.
    @ObservationIgnored var lastTime: Double = 0

    var info: VideoInfo?
    var poster: CGImage?
    var state: AnalysisState = .loading
    var analysis: VideoFaces?
    var analyzedTiles = Accuracy.high.rawValue
    var thumbnails: [Int: [CGImage]] = [:]
    /// People resembling a registered photo: person → distance.
    var registeredHints: [Int: Float] = [:]
    /// People resembling someone chosen in another video: person → that video's name.
    var crossHints: [Int: String] = [:]
    /// Where each person appears (seconds), for the timeline and "次の場面へ".
    var scenes: [Int: [ClosedRange<Double>]] = [:]
    var selected: Set<Int> = []
    var focusedPerson: Int?
    var job: JobState = .idle
    var summary: JobSummary?

    init(url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
        asset = AVURLAsset(url: url)
    }

    func close() {
        if scoped { url.stopAccessingSecurityScopedResource() }
        Remux.remove(remuxed)
    }

    var name: String { url.deletingPathExtension().lastPathComponent }
    var analyzing: Double? { if case .running(let p) = state { p } else { nil } }
    var isReady: Bool { info != nil }

    func resultIsStale(_ params: MosaicParams) -> Bool {
        summary.map { $0.selection != selected || $0.params != params } ?? false
    }
    func hasUnexportedWork(_ params: MosaicParams) -> Bool {
        analysis != nil && !selected.isEmpty && (summary == nil || resultIsStale(params))
    }
    var canExport: Bool { analysis != nil && !selected.isEmpty && !job.isActive }

    var subtitle: String {
        guard let i = info else { return "" }
        return "\(Int(i.size.width))×\(Int(i.size.height)) · \(formatDuration(i.duration)) · \(String(format: "%.0f", i.fps)) fps"
    }

    func seconds(of p: Person) -> Double { Double(p.frameCount) / max(1, analysis?.fps ?? 30) }

    func person(_ id: Int) -> Person? { analysis?.people.first { $0.id == id } }

    /// People in list order, with each person's "maybe the same" people right after them.
    var orderedPeople: [Person] {
        guard let analysis else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: analysis.people.map { ($0.id, $0) })
        var placed = Set<Int>()
        var out: [Person] = []
        for p in analysis.people where !placed.contains(p.id) {
            out.append(p)
            placed.insert(p.id)
            for s in p.similar where !placed.contains(s) {
                if let q = byID[s] { out.append(q) }
                placed.insert(s)
            }
        }
        return out
    }

    /// The ids plus everyone linked to them as "maybe the same person".
    func withSimilar<S: Sequence>(_ ids: S) -> Set<Int> where S.Element == Int {
        var out = Set(ids)
        guard let analysis else { return out }
        for p in analysis.people where out.contains(p.id) { out.formUnion(p.similar) }
        return out
    }

    /// Hinted people (registered photo or another video) who are not checked yet.
    var uncheckedHints: Set<Int> {
        Set(registeredHints.keys).union(crossHints.keys).subtracting(selected)
    }

    /// Each person's appearances; a gap of half a second or more starts a new scene.
    static func scenes(of a: VideoFaces) -> [Int: [ClosedRange<Double>]] {
        let n = a.times.count
        guard n > 0 else { return [:] }
        let gap = 0.5
        let frameLength = 1 / max(a.fps, 1)
        var out: [Int: [ClosedRange<Double>]] = [:]
        for f in 0..<n {
            let t = a.times[f]
            for id in Set(a.faces(atFrame: f).map(\.person)) {
                if let last = out[id]?.last, t - last.upperBound <= gap {
                    out[id]![out[id]!.count - 1] = last.lowerBound...(t + frameLength)
                } else {
                    out[id, default: []].append(t...(t + frameLength))
                }
            }
        }
        return out
    }

    func frames(hold: Double) -> [FrameFaces] {
        analysis?.frames(selected: selected, endHold: hold) ?? []
    }
}
