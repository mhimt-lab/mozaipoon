import AVFoundation
import AppKit
import Observation
import WipeMosaicCore

enum AnalysisState: Equatable {
    /// `idle`: loaded, but searching faces was not asked for (only text was chosen).
    case loading, converting, idle, waiting, running(Double), done, cancelled, failed(String)
}

/// What the user wants to hide in a video, chosen when it is added.
enum Purpose: String, CaseIterable {
    case faces, text, both
    var findsFaces: Bool { self != .text }
    var readsText: Bool { self != .faces }
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
    /// What was hidden in on-screen text (nil: nothing).
    let text: TextMaskOptions?
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

    // On-screen text (screen recordings). nil state: not searched yet.
    var textState: AnalysisState?
    var text: ScreenText?
    /// Lines hidden whole (entry ids).
    var textLines: Set<Int> = []
    /// nil until the user chose what to hide; nothing is searched before that.
    var purpose: Purpose?
    /// Hide every line that was read (a device screen filmed with a camera).
    var textAll = false
    /// Boxes for the current text options (kinds and words are app-wide, lines per video).
    var textMask: TextMask?
    var textOptions: TextMaskOptions?
    /// The options `textMask` was made with (it is made in the background after a change).
    var textMaskOptions: TextMaskOptions?
    /// The mosaic for the current text options is still being made.
    var textMaskPending: Bool { text != nil && textMaskOptions != textOptions }
    /// Counts mask requests; only the result of the latest one is used.
    @ObservationIgnored var textMaskRequest = 0

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

    var textScanning: Double? { if case .running(let p) = textState { p } else { nil } }
    /// Text lines with something hidden.
    var hiddenTextCount: Int { textMask?.hidden.count ?? 0 }
    /// The text options in effect for export (nil when no text is hidden).
    var effectiveTextOptions: TextMaskOptions? { hiddenTextCount > 0 ? textOptions : nil }
    /// Something to mosaic: chosen people or hidden text.
    var hasChoices: Bool { (analysis != nil && !selected.isEmpty) || hiddenTextCount > 0 }

    func resultIsStale(_ params: MosaicParams) -> Bool {
        summary.map { $0.selection != selected || $0.params != params || $0.text != effectiveTextOptions } ?? false
    }
    func hasUnexportedWork(_ params: MosaicParams) -> Bool {
        hasChoices && (summary == nil || resultIsStale(params))
    }
    /// A search the user asked for is still waiting or running: writing now would leave out
    /// what it finds (with "both", the faces or the text).
    var stillSearching: Bool {
        let faces = purpose?.findsFaces == true && (state == .waiting || analyzing != nil)
        return faces || textState == .waiting || textScanning != nil
    }
    var canExport: Bool { hasChoices && !job.isActive && !stillSearching && !textMaskPending }
    /// What is still being searched, for the export sheet.
    var searchingLabel: String? {
        guard stillSearching else { return nil }
        let faces = purpose?.findsFaces == true && (state == .waiting || analyzing != nil)
        let text = textState == .waiting || textScanning != nil
        return faces && text ? "顔と画面の文字を探しています" : faces ? "顔を探しています" : "画面の文字を読み取っています"
    }
    /// A search the user asked for that was cancelled or failed: nothing it would have found
    /// gets a mosaic.
    var skippedSearch: String? {
        var out: [String] = []
        if purpose?.findsFaces == true, analysis == nil {
            switch state {
            case .cancelled, .failed: out.append("顔")
            default: break
            }
        }
        if purpose?.readsText == true, text == nil {
            switch textState {
            case .cancelled?, .failed?: out.append("画面の文字")
            default: break
            }
        }
        return out.isEmpty ? nil : "\(out.joined(separator: "と"))は探していないので、モザイクがかかりません"
    }

    /// "3人中 1人・文字 12行にモザイク" for the sidebar and the export sheet.
    var choiceSummary: String {
        var parts: [String] = []
        if let a = analysis, !a.people.isEmpty, !selected.isEmpty { parts.append("\(a.people.count)人中 \(selected.count)人") }
        if hiddenTextCount > 0 { parts.append("文字 \(hiddenTextCount)行") }
        return parts.joined(separator: "・") + "にモザイク"
    }

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
        let faces = analysis?.frames(selected: selected, endHold: hold) ?? []
        guard let text, let mask = textMask, !mask.isEmpty else { return faces }
        return withText(faces, text: text, mask: mask)
    }
}
