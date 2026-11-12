import AVFoundation
import AppKit
import Observation
import UniformTypeIdentifiers
import WipeMosaicCore

enum Accuracy: Int, CaseIterable, Identifiable {
    case high = 4, standard = 3, fast = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .high: "高精度"
        case .standard: "標準"
        case .fast: "速度優先"
        }
    }
    var note: String {
        switch self {
        case .high: "画面を4×4に分けて、遠くの小さな顔まで探します。"
        case .standard: "3×3に分けて探します。ごく小さな顔を見落とすことがあります。"
        case .fast: "2×2に分けて探します。小さな顔を見落としやすくなります。"
        }
    }
}

/// What the viewer shows.
enum ViewMode: Hashable {
    case original, mosaic, result
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
@Observable
final class AppModel {
    // MARK: Settings (persisted)
    var accuracy: Accuracy = Accuracy(rawValue: UserDefaults.standard.integer(forKey: Keys.accuracy)) ?? .high {
        didSet { UserDefaults.standard.set(accuracy.rawValue, forKey: Keys.accuracy) }
    }
    /// Seconds the mosaic stays before a face appears and after it disappears.
    var hold: Double = AppModel.stored(Keys.hold, 1.0) {
        didSet {
            UserDefaults.standard.set(hold, forKey: Keys.hold)
            refreshLive()
        }
    }
    var pad: Double = AppModel.stored(Keys.pad, 0.45) {
        didSet {
            UserDefaults.standard.set(pad, forKey: Keys.pad)
            refreshLive()
        }
    }
    var autoBlock: Bool = UserDefaults.standard.object(forKey: Keys.autoBlock) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoBlock, forKey: Keys.autoBlock)
            refreshLive()
        }
    }
    var block: Double = AppModel.stored(Keys.block, 32) {
        didSet {
            UserDefaults.standard.set(block, forKey: Keys.block)
            refreshLive()
        }
    }

    // MARK: Registered photos
    var registered: [RegisteredFace] = FaceStore.loadAll()
    var registerMessages: [String] = []
    var registering = false
    var importingPhotos = false
    var hoveredFace: UUID?

    // MARK: Videos
    var videos: [VideoItem] = []
    var currentID: UUID? {
        didSet { if oldValue != currentID { showCurrent(previous: oldValue) } }
    }
    var current: VideoItem? { videos.first { $0.id == currentID } }
    var importingVideo = false
    var dropTargeted = false
    var alert: AppAlert?
    /// A video waiting for the user to confirm removing it with unexported work.
    var pendingRemoval: UUID?
    var recentURLs: [URL] = NSDocumentController.shared.recentDocumentURLs

    // MARK: Player
    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    var currentTime: Double = 0
    var isPlaying = false
    var viewMode: ViewMode = .mosaic {
        didSet { if oldValue != viewMode { applyViewMode() } }
    }
    var showFaceBoxes = true
    var mosaicExpanded: Bool = UserDefaults.standard.bool(forKey: "mosaicExpanded") {
        didSet { UserDefaults.standard.set(mosaicExpanded, forKey: "mosaicExpanded") }
    }
    var showInspector = true

    // MARK: Queues
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    private var analyzingID: UUID?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    /// (done, total) of the running export queue.
    var exportProgress: (done: Int, total: Int)?

    private enum Keys {
        static let accuracy = "accuracy", hold = "hold", pad = "pad", autoBlock = "autoBlock", block = "block"
    }

    private static func stored(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }

    init() {
        Remux.removeAll()
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] t in
            MainActor.assumeIsolated { self?.currentTime = t.seconds.isFinite ? t.seconds : 0 }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in
                guard let self, self.isPlaying != playing else { return }
                self.isPlaying = playing
                // Paused: make sure the frame on screen has the current mosaic.
                if !playing { self.redrawIfPaused() }
            }
        }
    }

    // MARK: - Derived

    func render(for v: VideoItem) -> RenderSettings {
        var r = RenderSettings()
        r.tiles = v.analyzedTiles
        r.hold = 0  // applied per person by VideoFaces.frames(selected:endHold:)
        r.pad = pad
        r.block = autoBlock ? nil : block
        return r
    }

    var mosaicParams: MosaicParams { MosaicParams(hold: hold, pad: pad, block: autoBlock ? nil : block) }
    var hasVideo: Bool { current?.isReady == true }
    var autoBlockSize: Int { Int(current?.info.map { WipeMosaicCore.autoBlock($0.size) } ?? 32) }
    func needsReanalysis(_ v: VideoItem) -> Bool { v.analysis != nil && v.analyzedTiles != accuracy.rawValue }
    /// Videos with people chosen that are not being written.
    var exportable: [VideoItem] { videos.filter(\.canExport) }
    var isExporting: Bool { exportProgress != nil }
    var canExport: Bool { !exportable.isEmpty && !isExporting }

    // MARK: Export sheet (choose videos when more than one can be written)
    var showingExportSheet = false
    var exportChoice: Set<UUID> = []
    /// nil = next to each original video.
    var exportFolder: URL?

    /// Faces in the frame on screen, while paused and not showing the exported file.
    var visibleFaces: [(rect: CGRect, person: Int)] {
        guard let analysis = current?.analysis, showFaceBoxes, !isPlaying, viewMode != .result else { return [] }
        return analysis.faces(atFrame: analysis.frameIndex(at: currentTime))
    }

    // MARK: - Registered photos

    func addPhotos(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        registering = true
        registerMessages = []
        Task.detached(priority: .userInitiated) { [weak self] in
            weak let model = self
            var added: [RegisteredFace] = []
            var messages: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let f = try faceFromPhoto(url)
                    let face = RegisteredFace(id: UUID(), thumbnail: f.thumbnail, signature: f.signature)
                    try FaceStore.save(face)
                    added.append(face)
                    if f.faceCount > 1 {
                        messages.append("「\(url.lastPathComponent)」には顔が\(f.faceCount)つあったため、いちばん大きな顔を登録しました。")
                    }
                } catch {
                    messages.append("「\(url.lastPathComponent)」：\(AppModel.describe(error))")
                }
            }
            await model?.finishRegistering(added, messages)
        }
    }

    private func finishRegistering(_ added: [RegisteredFace], _ messages: [String]) {
        registered += added
        registerMessages = messages
        registering = false
        updateRegisteredHints()
    }

    func removeRegistered(_ face: RegisteredFace) {
        do {
            try FaceStore.delete(face.id)
            registered.removeAll { $0.id == face.id }
            updateRegisteredHints()
        } catch {
            alert = AppAlert(title: "写真を削除できませんでした", message: AppModel.describe(error))
        }
    }

    private func updateRegisteredHints() {
        let sigs = registered.map(\.signature)
        for v in videos { if let a = v.analysis { v.registeredHints = a.suggestions(registered: sigs) } }
    }

    // MARK: - Adding and removing videos

    /// Add videos to the list (a video already in the list is just shown).
    func add(_ urls: [URL]) {
        var firstNew: UUID?
        // A photo is not a video: AVFoundation cannot open it, so it would take the
        // "unreadable container" path and ffmpeg would wrap it into a one-frame .mov.
        let photos = urls.filter { $0.isFileURL && Self.isPhoto($0) }
        if !photos.isEmpty {
            let names = photos.prefix(3).map { "「\($0.lastPathComponent)」" }.joined(separator: "、")
            alert = AppAlert(
                title: "写真は動画として追加できません",
                message: "\(names)\(photos.count > 3 ? "など\(photos.count)枚" : "")は写真です。モザイクをかける人の顔写真として使うときは、「設定」（⌘,）の顔写真の欄に追加してください。")
        }
        for url in urls where url.isFileURL && !Self.isPhoto(url) {
            if let existing = videos.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                if firstNew == nil { firstNew = existing.id }
                continue
            }
            let v = VideoItem(url: url)
            videos.append(v)
            if firstNew == nil { firstNew = v.id }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            load(v)
        }
        recentURLs = NSDocumentController.shared.recentDocumentURLs
        if let firstNew { currentID = firstNew }
    }

    private func load(_ v: VideoItem) {
        Task {
            do {
                let i: VideoInfo
                do {
                    i = try await loadVideo(v.asset)
                } catch where Self.isUnreadable(error) {
                    // e.g. MXF: rewrap into .mov without re-encoding, then read that.
                    v.state = .converting
                    let mov = try await Remux.toMOV(v.url)
                    guard videos.contains(where: { $0.id == v.id }) else {
                        Remux.remove(mov)
                        return
                    }
                    v.remuxed = mov
                    v.asset = AVURLAsset(url: mov)
                    i = try await loadVideo(v.asset)
                }
                let item = AVPlayerItem(asset: v.asset)
                let comp = try await v.live.composition(for: v.asset)
                item.videoComposition = comp
                v.info = i
                v.sourceItem = item
                v.composition = comp
                v.state = .waiting
                if v.id == currentID { showCurrent(previous: nil) }
                processQueue()
                v.poster = await Self.poster(v.asset, duration: i.duration)
            } catch {
                v.state = .failed(Self.describe(error))
            }
        }
    }

    private static func poster(_ asset: AVURLAsset, duration: Double) async -> CGImage? {
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 320, height: 320)
        let t = CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)
        return try? await g.image(at: t).image
    }

    func requestRemove(_ id: UUID?) {
        guard let id, let v = videos.first(where: { $0.id == id }), !v.job.isActive else { return }
        if v.hasUnexportedWork(mosaicParams) { pendingRemoval = id } else { remove(id) }
    }

    func remove(_ id: UUID) {
        pendingRemoval = nil
        guard let idx = videos.firstIndex(where: { $0.id == id }), !videos[idx].job.isActive else { return }
        if analyzingID == id { analysisTask?.cancel() }
        let v = videos.remove(at: idx)
        v.close()
        if currentID == id {
            currentID = videos.isEmpty ? nil : videos[min(idx, videos.count - 1)].id
        }
        updateCrossHints()
    }

    func clearRecent() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentURLs = []
    }

    // MARK: - Face analysis queue (one video at a time: Vision does not get faster in parallel)

    private func processQueue() {
        guard analysisTask == nil else { return }
        let next = current.flatMap { $0.state == .waiting ? $0 : nil } ?? videos.first { $0.state == .waiting }
        guard let next, let info = next.info else { return }
        analyze(next, info: info)
    }

    private func analyze(_ v: VideoItem, info i: VideoInfo) {
        let tiles = accuracy.rawValue
        let id = v.id
        let a = v.asset
        v.state = .running(0)
        analyzingID = id
        analysisTask = Task.detached(priority: .userInitiated) { [weak self] in
            weak let model = self
            let total = max(1, Int((i.fps * i.duration).rounded()))
            var last = Date.distantPast
            do {
                let faces = try analyzeFaces(asset: a, info: i, tiles: tiles) { n in
                    let now = Date()
                    guard now.timeIntervalSince(last) > 0.1 else { return }
                    last = now
                    let p = min(0.99, Double(n) / Double(total))
                    Task { @MainActor in model?.progress(id, p) }
                }
                var thumbs: [Int: [CGImage]] = [:]
                for p in faces.people {
                    for s in p.samples.prefix(3) {
                        try Task.checkCancellation()
                        if let img = try? await faceThumbnail(asset: a, time: faces.times[s.frame], rect: s.rect) {
                            thumbs[p.id, default: []].append(img)
                        }
                    }
                }
                await model?.finishAnalysis(id, faces, thumbs, tiles)
            } catch {
                let cancelled = error is CancellationError || Task.isCancelled
                await model?.failAnalysis(id, cancelled ? nil : AppModel.describe(error))
            }
        }
    }

    private func progress(_ id: UUID, _ p: Double) {
        guard let v = videos.first(where: { $0.id == id }), v.analyzing != nil else { return }
        v.state = .running(p)
    }

    private func finishAnalysis(_ id: UUID, _ faces: VideoFaces, _ thumbs: [Int: [CGImage]], _ tiles: Int) {
        endAnalysis(id)
        if let v = videos.first(where: { $0.id == id }) {
            v.analyzedTiles = tiles
            v.analysis = faces
            v.thumbnails = thumbs
            v.scenes = VideoItem.scenes(of: faces)
            v.state = .done
            v.registeredHints = faces.suggestions(registered: registered.map(\.signature))
            v.crossHints = crossHints(for: v)
            // Pre-select whoever resembles a registered photo or someone chosen in another video.
            v.selected = v.withSimilar(Set(v.registeredHints.keys).union(v.crossHints.keys))
            selectionChanged(v)
        }
        processQueue()
    }

    private func failAnalysis(_ id: UUID, _ message: String?) {
        endAnalysis(id)
        if let v = videos.first(where: { $0.id == id }) {
            v.state = message.map { .failed($0) } ?? .cancelled
        }
        processQueue()
    }

    private func endAnalysis(_ id: UUID) {
        guard analyzingID == id else { return }
        analysisTask = nil
        analyzingID = nil
    }

    func cancelAnalysis() {
        guard let id = current?.id, analyzingID == id else { return }
        analysisTask?.cancel()
    }

    /// Search the current video again (with the current accuracy). Its choices are reset.
    func reanalyze() {
        guard let v = current, v.isReady, v.analyzing == nil, !v.job.isActive else { return }
        v.analysis = nil
        v.thumbnails = [:]
        v.scenes = [:]
        v.registeredHints = [:]
        v.crossHints = [:]
        v.focusedPerson = nil
        v.selected = []
        undoManager?.removeAllActions()  // person numbers change; old checks no longer apply
        v.state = .waiting
        selectionChanged(v)
        processQueue()
    }

    // MARK: - Selection (undoable)

    /// The window's undo manager (set by the view), so ⌘Z undoes check changes.
    @ObservationIgnored weak var undoManager: UndoManager?

    func toggle(_ person: Int) {
        guard let v = current else { return }
        setSelected(person, !v.selected.contains(person))
    }

    /// Checking a person also checks the people who may be the same person (a split is the
    /// likelier error, and an extra mosaic is safer than a missing one). Unchecking removes
    /// only that person.
    func setSelected(_ person: Int, _ on: Bool) {
        guard let v = current else { return }
        var s = v.selected
        if on { s.formUnion(v.withSimilar([person])) } else { s.remove(person) }
        apply(s, to: v, action: on ? "モザイクをかける" : "モザイクを外す")
    }

    func selectAll() {
        guard let v = current else { return }
        apply(Set(v.analysis?.people.map(\.id) ?? []), to: v, action: "全員にモザイクをかける")
    }

    func clearAll() {
        guard let v = current else { return }
        apply([], to: v, action: "全員のモザイクを外す")
    }

    /// Check the people hinted by registered photos or other videos.
    func checkHinted() {
        guard let v = current else { return }
        apply(v.selected.union(v.withSimilar(v.uncheckedHints)), to: v, action: "似ている人をチェック")
    }

    private func apply(_ selection: Set<Int>, to v: VideoItem, action: String) {
        let old = v.selected
        guard old != selection else { return }
        v.selected = selection
        selectionChanged(v)
        registerUndo(v.id, old, action)
    }

    private func registerUndo(_ id: UUID, _ old: Set<Int>, _ action: String) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(id, old, action) }
        }
        um.setActionName(action)
    }

    /// Undo/redo: put a video's checks back (and show that video so the change is visible).
    private func restore(_ id: UUID, _ selection: Set<Int>, _ action: String) {
        guard let v = videos.first(where: { $0.id == id }), v.analysis != nil else { return }
        if currentID != id { currentID = id }
        let old = v.selected
        v.selected = selection
        selectionChanged(v)
        registerUndo(id, old, action)
    }

    private func selectionChanged(_ v: VideoItem) {
        if v.id == currentID { refreshLive() }
        updateCrossHints(except: v.id)
    }

    /// People in `v` resembling people chosen in the other analyzed videos.
    private func crossHints(for v: VideoItem) -> [Int: String] {
        guard let faces = v.analysis else { return [:] }
        var out: [Int: String] = [:]
        for o in videos where o.id != v.id && !o.selected.isEmpty {
            guard let other = o.analysis else { continue }
            for id in faces.matches(of: o.selected, in: other).keys where out[id] == nil { out[id] = o.name }
        }
        return out
    }

    /// Hints only: a choice in one video never changes the selection of another one silently.
    private func updateCrossHints(except id: UUID? = nil) {
        for v in videos where v.id != id && v.analysis != nil { v.crossHints = crossHints(for: v) }
    }

    // MARK: - Player

    /// Push the current selection and settings to the player's mosaic and redraw if paused.
    private func refreshLive() {
        guard let v = current else { return }
        v.live.update(frames: v.frames(hold: hold), render: render(for: v), enabled: viewMode == .mosaic)
        redrawIfPaused()
    }

    private func redrawIfPaused() {
        // A seek to the same time does not re-render; assigning a new composition object does.
        guard !isPlaying, let v = current, let item = player.currentItem, item === v.sourceItem,
            let copy = v.composition?.mutableCopy() as? AVVideoComposition
        else { return }
        item.videoComposition = copy
    }

    /// Show the current video in the player, at the position it was left.
    private func showCurrent(previous: UUID?) {
        if let previous, let old = videos.first(where: { $0.id == previous }) { old.lastTime = currentTime }
        player.pause()
        guard let v = current, v.isReady else {
            player.replaceCurrentItem(with: nil)
            currentTime = 0
            return
        }
        if viewMode == .result && v.resultItem == nil { viewMode = .mosaic }
        let target = viewMode == .result ? v.resultItem : v.sourceItem
        if player.currentItem !== target { player.replaceCurrentItem(with: target) }
        let t = v.lastTime
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = t
        refreshLive()
        processQueue()  // the shown video goes first in the queue
    }

    private func applyViewMode() {
        guard let v = current else { return }
        let t = player.currentTime()
        let wasPlaying = isPlaying
        let target = viewMode == .result ? v.resultItem : v.sourceItem
        if let target, player.currentItem !== target {
            player.replaceCurrentItem(with: target)
            player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
        }
        refreshLive()
    }

    func togglePlay() {
        guard player.currentItem != nil else { return }
        if isPlaying {
            player.pause()
        } else {
            if let d = player.currentItem?.duration.seconds, d.isFinite, currentTime >= d - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
        }
    }

    func seek(to t: Double) {
        player.pause()
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = t
    }

    /// Selecting a person in the list shows them: if they are not on screen at the current
    /// time, go to the moment they first appear.
    func reveal(_ id: Int) {
        guard let v = current, let analysis = v.analysis, let p = v.person(id) else { return }
        let onScreen = analysis.faces(atFrame: analysis.frameIndex(at: currentTime)).contains { $0.person == id }
        if !onScreen || viewMode == .result { jump(to: p) }
    }

    /// Go to the start of this person's next scene after the current time; after the last
    /// one, back to the first.
    func nextScene(_ id: Int) {
        guard let v = current, let first = v.scenes[id]?.first else { return }
        if viewMode == .result { viewMode = .mosaic }
        let next = v.scenes[id]?.first { $0.lowerBound > currentTime + 0.01 } ?? first
        v.focusedPerson = id
        seek(to: next.lowerBound)
    }

    /// Step one frame (AVPlayerItem.step keeps the composition's mosaic in sync).
    func step(_ frames: Int) {
        player.pause()
        player.currentItem?.step(byCount: frames)
    }

    func jump(to person: Person) {
        guard let v = current, let analysis = v.analysis else { return }
        if viewMode == .result { viewMode = .mosaic }
        v.focusedPerson = person.id
        seek(to: analysis.times[person.firstFrame])
    }

    // MARK: - Export

    private static func outputExtension(_ src: URL) -> String {
        let ext = src.pathExtension.lowercased()
        return ["mov", "mp4", "m4v"].contains(ext) ? ext : "mov"
    }

    /// The one export entry point (toolbar button, ⌘E): always the same sheet, so the
    /// steps do not change with the number of videos, and what will be written is shown.
    func requestExport() {
        let ready = exportable
        guard !ready.isEmpty, !isExporting else { return }
        // Pre-check what still needs writing; an already written, unchanged video stays
        // unchecked (writing it again would only add a numbered copy).
        var choice = Set(ready.filter { $0.hasUnexportedWork(mosaicParams) }.map(\.id))
        if choice.isEmpty, let c = current, c.canExport { choice = [c.id] }
        if choice.isEmpty { choice = [ready[0].id] }
        exportChoice = choice
        player.pause()
        showingExportSheet = true
    }

    /// From a warning in the sheet: close it and show that video to check its people.
    func review(_ id: UUID) {
        showingExportSheet = false
        currentID = id
        viewMode = .mosaic
        showInspector = true
    }

    func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.title = "保存先を選ぶ"
        panel.prompt = "選択"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = exportFolder ?? videos.first { exportChoice.contains($0.id) }?.url.deletingLastPathComponent()
        if panel.runModal() == .OK, let dir = panel.url { exportFolder = dir }
    }

    /// Start writing the videos checked in the sheet.
    func confirmExport() {
        let targets = videos.filter { exportChoice.contains($0.id) && $0.canExport }
        showingExportSheet = false
        guard !targets.isEmpty, !isExporting else { return }
        player.pause()
        var taken = Set<String>()
        let items = targets.map { v -> (VideoItem, URL, Bool) in
            let dir = exportFolder ?? v.url.deletingLastPathComponent()
            return (v, Self.uniqueURL(in: dir, base: v.name + "_mosaic", ext: Self.outputExtension(v.url), taken: &taken), false)
        }
        enqueue(items)
    }

    /// A file name in `dir` that does not exist yet (a batch never overwrites).
    private static func uniqueURL(in dir: URL, base: String, ext: String, taken: inout Set<String>) -> URL {
        var n = 1
        while true {
            let name = (n == 1 ? base : "\(base) \(n)") + "." + ext
            let url = dir.appendingPathComponent(name)
            if !taken.contains(url.path) && !FileManager.default.fileExists(atPath: url.path) {
                taken.insert(url.path)
                return url
            }
            n += 1
        }
    }

    /// Write videos one after another. Each item: (video, output, replace an existing file).
    private func enqueue(_ items: [(VideoItem, URL, Bool)]) {
        guard exportTask == nil, !items.isEmpty else { return }
        if viewMode == .result { viewMode = .mosaic }
        for (v, _, _) in items { v.job = .queued }
        exportProgress = (0, items.count)
        showInspector = true
        exportTask = Task {
            for (k, item) in items.enumerated() {
                if Task.isCancelled {
                    for (v, _, _) in items[k...] where v.job == .queued { v.job = .idle }
                    break
                }
                await write(item.0, to: item.1, replace: item.2, alertOnFailure: items.count == 1)
                exportProgress = (k + 1, items.count)
            }
            exportTask = nil
            exportProgress = nil
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    private func write(_ v: VideoItem, to out: URL, replace: Bool, alertOnFailure: Bool) async {
        guard let info = v.info else {
            v.job = .idle
            return
        }
        guard out.standardizedFileURL != v.url.standardizedFileURL else {
            v.job = .failed("元の動画と同じファイルには保存できません")
            if alertOnFailure { alert = AppAlert(title: "書き出せません", message: "元の動画と同じファイルには保存できません。別の名前を指定してください。") }
            return
        }
        let type: AVFileType
        do { type = try fileType(for: out) } catch {
            v.job = .failed("保存形式は .mov か .mp4 にしてください")
            if alertOnFailure { alert = AppAlert(title: "書き出せません", message: "保存形式は .mov か .mp4 にしてください。") }
            return
        }
        let frames = v.frames(hold: hold)
        let render = render(for: v)
        let selection = v.selected
        let params = mosaicParams
        let started = Date()
        v.summary = nil
        v.resultItem = nil
        v.job = .writing(0)
        var wroteOutput = false
        do {
            if replace && FileManager.default.fileExists(atPath: out.path) { try FileManager.default.removeItem(at: out) }
            wroteOutput = true
            let format = try await writeMosaic(
                asset: v.asset, info: info, frames: frames, render: render, to: out, fileType: type
            ) { p in
                Task { @MainActor in if v.job.isRunning { v.job = .writing(p) } }
            }
            v.summary = JobSummary(
                output: out, format: format, frames: frames.count,
                mosaicFrames: frames.filter { !$0.mosaic.isEmpty }.count, dips: findDips(frames),
                elapsed: Date().timeIntervalSince(started), selection: selection, params: params)
            v.resultItem = AVPlayerItem(url: out)
            v.job = .done
        } catch {
            if wroteOutput { try? FileManager.default.removeItem(at: out) }  // partial file only
            if error is CancellationError || Task.isCancelled {
                v.job = .cancelled
            } else {
                let message = Self.describe(error)
                v.job = .failed(message)
                if alertOnFailure { alert = AppAlert(title: "書き出しに失敗しました", message: message) }
            }
        }
    }

    func cancelExports() { exportTask?.cancel() }

    func review(_ dip: Dip) {
        viewMode = .result
        seek(to: dip.start)
    }

    func revealOutput() {
        guard let url = current?.summary?.output else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealSource(_ id: UUID) {
        guard let v = videos.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([v.url])
    }

    /// Still images (JPEG, HEIC, PNG, GIF…), judged by the file's type rather than the drop.
    nonisolated static func isPhoto(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .audiovisualContent)
    }

    nonisolated static func isUnreadable(_ error: Error) -> Bool {
        let ns = error as NSError
        let codes = [
            AVError.fileFormatNotRecognized.rawValue, AVError.decoderNotFound.rawValue,
            AVError.failedToParse.rawValue,
        ]
        return ns.domain == AVFoundationErrorDomain && codes.contains(ns.code)
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let e = error as? ToolError { return e.description }
        if isUnreadable(error) {
            return "この形式の動画は macOS で読み込めません。MP4（H.264 か HEVC）や MOV に変換してから追加してください。"
        }
        return error.localizedDescription
    }
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite else { return "--:--" }
    let total = max(0, t)
    let m = Int(total) / 60
    let s = total - Double(m * 60)
    return String(format: "%d:%05.2f", m, s)
}

func formatDuration(_ t: Double) -> String {
    guard t.isFinite else { return "--:--" }
    let s = Int(t.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

func formatSeconds(_ t: Double) -> String {
    t < 60 ? String(format: "%.1f秒", t) : "\(Int(t) / 60)分\(Int(t) % 60)秒"
}
