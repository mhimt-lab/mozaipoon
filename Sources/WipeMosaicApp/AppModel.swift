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

/// What the inspector lists.
enum InspectorTab: Hashable {
    case text, people
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
    /// Mosaic or blur, for faces without a sticker and for on-screen text (all videos).
    var coverStyle: CoverStyle = CoverStyle(rawValue: UserDefaults.standard.string(forKey: Keys.coverStyle) ?? "") ?? .mosaic {
        didSet {
            UserDefaults.standard.set(coverStyle.rawValue, forKey: Keys.coverStyle)
            refreshLive()
        }
    }
    /// Sticker size relative to the face.
    var stickerScale: Double = AppModel.stored(Keys.stickerScale, 1.2) {
        didSet {
            UserDefaults.standard.set(stickerScale, forKey: Keys.stickerScale)
            refreshLive()
        }
    }

    // MARK: Stickers (images put over a person's face)
    /// Loaded in the background at launch (each image is decoded and searched for a face).
    var stickerLibrary: [StickerItem] = []
    /// The image waiting for the delete confirmation in Settings (in the model: @State
    /// needs the SwiftUI macro plugin, see WipeMosaicApp).
    var stickerToRemove: StickerItem?
    /// The same, asked from a person's "隠し方" menu in the main window.
    var stickerToRemoveFromMenu: StickerItem?
    /// Deleted while the library was still loading: the load read them before.
    private var removedStickers: Set<UUID> = []
    private var loadingStickers = true
    /// The person waiting for an image from the file dialog.
    var stickerTarget: Int?
    var importingSticker = false

    /// Kinds of personal information hidden automatically in on-screen text (all videos).
    var textKinds: Set<TextKind> = AppModel.storedKinds() {
        didSet {
            UserDefaults.standard.set(textKinds.map(\.rawValue).sorted(), forKey: Keys.textKinds)
            updateTextMasks()
        }
    }
    /// Words (names, account names…) hidden wherever they appear on screen (all videos).
    var textWords: [String] = UserDefaults.standard.stringArray(forKey: Keys.textWords) ?? [] {
        didSet {
            UserDefaults.standard.set(textWords, forKey: Keys.textWords)
            updateTextMasks()
        }
    }

    // MARK: Registered photos
    var registered: [RegisteredFace] = FaceStore.loadAll()
    var registerMessages: [String] = []
    var registering = false
    var importingPhotos = false
    var hoveredFace: UUID?
    /// A registered face waiting for the delete confirmation (the photo file is deleted).
    var faceToRemove: RegisteredFace?
    /// The sticker under the pointer in Settings (its delete button shows on hover).
    var hoveredSticker: UUID?

    // MARK: Videos
    var videos: [VideoItem] = []
    var currentID: UUID? {
        didSet {
            guard oldValue != currentID else { return }
            textUnhiddenOnly = false  // a filter left on would make the next video's list look short
            followPurpose()
            showCurrent(previous: oldValue)
        }
    }
    var current: VideoItem? { videos.first { $0.id == currentID } }
    var importingVideo = false
    /// Videos just added, waiting for the user to choose what to hide in them.
    var pendingPurpose: [UUID] = []
    /// The last choice, offered first next time.
    var lastPurpose: Purpose = Purpose(rawValue: UserDefaults.standard.string(forKey: "purpose") ?? "") ?? .text {
        didSet { UserDefaults.standard.set(lastPurpose.rawValue, forKey: "purpose") }
    }
    var dropTargeted = false
    var alert: AppAlert?
    /// A video waiting for the user to confirm removing it with unexported work.
    var pendingRemoval: UUID?
    var recentURLs: [URL] = NSDocumentController.shared.recentDocumentURLs

    // MARK: Player
    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    /// Time of the frame on screen (the face boxes and text outlines follow it).
    var currentTime: Double = 0
    /// Where a seek is going. The playhead and the time shown follow it at once, while the
    /// picture follows as fast as the decoder can (see `seek(to:)`).
    private(set) var pendingSeek: Double?
    @ObservationIgnored private var seeking = false
    /// Playhead position: where the user is going, else the frame on screen.
    var playheadTime: Double { pendingSeek ?? currentTime }
    var isPlaying = false
    /// Playback speed (1 = normal), kept by every `play()` through `defaultRate`.
    var playbackRate: Float = 1 {
        didSet {
            player.defaultRate = playbackRate
            if isPlaying { player.rate = playbackRate }
        }
    }
    static let playbackRates: [Float] = [0.5, 1, 1.5, 2]
    /// Time under the pointer on the timeline (shown in a label while hovering).
    var timelineHover: Double?
    /// The main window, for the player keys (`handleKey`).
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var zoomMonitor: Any?
    /// How much the video is enlarged in the viewer (1 = whole video), kept across the three
    /// views (to compare the same place) and reset for another video. See Zoom.swift.
    var zoom: CGFloat = 1
    /// Point of the video at the middle of the viewer, in fractions of the video (`ZoomGeometry`).
    var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    /// The viewer (its own coordinates, top-left origin), to place pinches and scrolls.
    @ObservationIgnored weak var viewerView: NSView?
    @ObservationIgnored var pinching = false
    /// A trackpad scroll (and its momentum) that started over the video moves it to the end,
    /// one that started elsewhere never does.
    @ObservationIgnored var scrollOverViewer = false
    var viewMode: ViewMode = .mosaic {
        didSet { if oldValue != viewMode { applyViewMode() } }
    }
    var showFaceBoxes = true
    var mosaicExpanded: Bool = UserDefaults.standard.bool(forKey: "mosaicExpanded") {
        didSet { UserDefaults.standard.set(mosaicExpanded, forKey: "mosaicExpanded") }
    }
    var showInspector = true
    /// The list of videos (the split view's sidebar), also opened and closed from the 表示 menu.
    var showSidebar = true
    /// The choice under the pointer in the "what to hide" sheet.
    var hoveredPurpose: Purpose?
    var inspectorTab: InspectorTab = .text
    /// A new empty word field is shown in the text tab ("＋"), and whether its rarely seen
    /// lines are shown.
    var addingTextWord = false
    /// Text typed in the word fields, by the word being edited ("" for the new one).
    var wordDrafts: [String: String] = [:]
    var showTextFlashes = false
    /// The text lines list shows only lines with nothing hidden (to look for what was missed).
    var textUnhiddenOnly = false

    // MARK: Queues
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    private var analyzingID: UUID?
    @ObservationIgnored private var textTask: Task<Void, Never>?
    private var textScanningID: UUID?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    /// (done, total) of the running export queue.
    var exportProgress: (done: Int, total: Int)?

    private enum Keys {
        static let accuracy = "accuracy", hold = "hold", pad = "pad", autoBlock = "autoBlock", block = "block"
        static let coverStyle = "coverStyle", stickerScale = "stickerScale"
        static let textKinds = "textKinds", textWords = "textWords"
    }

    private static func storedKinds() -> Set<TextKind> {
        guard let raw = UserDefaults.standard.stringArray(forKey: Keys.textKinds) else { return Set(TextKind.allCases) }
        return Set(raw.compactMap(TextKind.init(rawValue:)))
    }

    private static func stored(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }

    init() {
        Remux.removeAll()
        // Local monitors run on the main thread.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            nonisolated(unsafe) let event = e
            let handled = MainActor.assumeIsolated { self?.handleKey(event) == true }
            return handled ? nil : e
        }
        zoomMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .smartMagnify, .scrollWheel]) { [weak self] e in
            nonisolated(unsafe) let event = e
            let handled = MainActor.assumeIsolated { self?.handleZoomEvent(event) == true }
            return handled ? nil : e
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            weak let model = self
            let items = StickerStore.loadAll()
            await MainActor.run {
                guard let model else { return }
                // Images added while loading stay, after the saved ones; images deleted
                // while loading stay deleted.
                let saved = items.filter { !model.removedStickers.contains($0.id) }
                model.stickerLibrary = saved + model.stickerLibrary.filter { s in !saved.contains { $0.id == s.id } }
                model.removedStickers = []
                model.loadingStickers = false
                model.refreshLive()
            }
        }
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
        r.style = coverStyle
        r.stickerScale = stickerScale
        for (person, id) in activeStickers(v) {
            if let item = stickerLibrary.first(where: { $0.id == id }) { r.stickers[person] = item.sticker }
        }
        return r
    }

    /// Chosen people with a sticker that is still in the library: person → sticker id.
    func activeStickers(_ v: VideoItem) -> [Int: UUID] {
        let ids = Set(stickerLibrary.map(\.id))
        return v.stickers.filter { v.selected.contains($0.key) && ids.contains($0.value) }
    }

    func sticker(_ id: UUID?) -> StickerItem? { id.flatMap { id in stickerLibrary.first { $0.id == id } } }

    /// Chosen people whose sticker lets part of the face show at the current size, and
    /// whether a larger size (up to the slider's 200%) would cover it.
    func seeThroughStickers(_ v: VideoItem) -> [(person: Int, fixedByLarger: Bool)] {
        activeStickers(v).compactMap { person, id -> (person: Int, fixedByLarger: Bool)? in
            guard let s = sticker(id)?.sticker, s.showsFace(scale: stickerScale) else { return nil }
            return (person, !s.showsFace(scale: 2.0))
        }.sorted { $0.person < $1.person }
    }

    var mosaicParams: MosaicParams {
        MosaicParams(hold: hold, pad: pad, block: autoBlock ? nil : block, style: coverStyle, stickerScale: stickerScale)
    }
    var hasVideo: Bool { current?.isReady == true }
    /// The face boxes and text outlines can be shown (something was searched, and not in the
    /// written file, which is checked as it is).
    var canToggleBoxes: Bool {
        guard let v = current, viewMode != .result else { return false }
        return v.analysis != nil || v.textMask != nil
    }
    var autoBlockSize: Int { Int(current?.info.map { WipeMosaicCore.autoBlock($0.size) } ?? 32) }
    func needsReanalysis(_ v: VideoItem) -> Bool { v.analysis != nil && v.analyzedTiles != accuracy.rawValue }
    /// Videos with people chosen that are not being written.
    var exportable: [VideoItem] { videos.filter(\.canExport) }
    var isExporting: Bool { exportProgress != nil }
    /// Also with a word typed but not applied yet: the export applies it first.
    var canExport: Bool {
        !isExporting && (!exportable.isEmpty || hasWordDraft && videos.contains { $0.text != nil })
    }

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

    /// Where on-screen text is hidden at the paused frame, outlined so a mosaic on a plain
    /// background (which looks like nothing) can be told from text that is not there.
    var visibleTextBoxes: [CGRect] {
        guard let v = current, let text = v.text, let mask = v.textMask, showFaceBoxes, !isPlaying, viewMode != .result
        else { return [] }
        return mask.frames[text.frameIndex(at: currentTime)]
    }

    /// Presentation times of the current video's frames, as read to find faces or text (the
    /// boxes on screen are looked up in these). nil before either has been read.
    var frameTimes: [Double]? {
        guard let v = current else { return nil }
        if let t = v.analysis?.times, !t.isEmpty { return t }
        if let t = v.text?.times, !t.isEmpty { return t }
        return nil
    }

    /// Number (from 1) of the frame on screen and the frame count, from the same times as
    /// the boxes: the number changes exactly when the boxes do. nil before the frames are read
    /// (a number from the frame rate would be wrong for variable frame rate recordings).
    var frameNumber: (index: Int, count: Int)? {
        guard let times = frameTimes else { return nil }
        return (frameIndex(times, at: currentTime) + 1, times.count)
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

    // MARK: - Stickers

    /// Put a sticker over a person's face (nil: back to the mosaic or blur), together with
    /// the people who may be the same person, like checking. The person is checked too:
    /// choosing a sticker means hiding them. Undoable.
    func setSticker(_ id: UUID?, for person: Int) {
        guard let v = current else { return }
        var map = v.stickers
        for p in v.withSimilar([person]) { map[p] = id }
        let oldMap = v.stickers, oldSelection = v.selected
        let selection = id == nil ? v.selected : v.selected.union(v.withSimilar([person]))
        guard map != oldMap || selection != oldSelection else { return }
        applyStickers(map, selection, to: v, action: id == nil ? "スタンプを外す" : "スタンプを使う")
    }

    private func applyStickers(_ map: [Int: UUID], _ selection: Set<Int>, to v: VideoItem, action: String) {
        let oldMap = v.stickers, oldSelection = v.selected
        v.stickers = map
        v.selected = selection
        selectionChanged(v)
        guard let um = undoManager else { return }
        let id = v.id
        um.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                guard let v = model.videos.first(where: { $0.id == id }), v.analysis != nil else { return }
                if model.currentID != id { model.currentID = id }
                model.applyStickers(oldMap, oldSelection, to: v, action: action)
            }
        }
        um.setActionName(action)
    }

    /// Ask for an image for this person's face.
    func chooseStickerImage(for person: Int) {
        stickerTarget = person
        importingSticker = true
    }

    /// Add an image to the stickers (kept on this Mac) and, if a person was waiting for it,
    /// put it over their face.
    func addSticker(from url: URL) {
        let person = stickerTarget
        stickerTarget = nil
        let videoID = currentID
        Task.detached(priority: .userInitiated) { [weak self] in
            weak let model = self
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = Result { () throws -> StickerItem in
                let item = StickerItem(id: UUID(), sticker: try Sticker(contentsOf: url))
                try StickerStore.save(item)
                return item
            }
            await model?.finishAddingSticker(result, name: url.lastPathComponent, person: person, videoID: videoID)
        }
    }

    private func finishAddingSticker(_ result: Result<StickerItem, Error>, name: String, person: Int?, videoID: UUID?) {
        switch result {
        case .success(let item):
            stickerLibrary.append(item)
            if let person, videoID == currentID { setSticker(item.id, for: person) }
        case .failure(let error):
            alert = AppAlert(title: "「\(name)」をスタンプにできませんでした", message: AppModel.describe(error))
        }
    }

    /// Delete a sticker from this Mac; people using it go back to the mosaic or blur.
    func removeSticker(_ item: StickerItem) {
        do {
            try StickerStore.delete(item.id)
            stickerLibrary.removeAll { $0.id == item.id }
            if loadingStickers { removedStickers.insert(item.id) }
            for v in videos where v.stickers.values.contains(item.id) {
                v.stickers = v.stickers.filter { $0.value != item.id }
                if v.id == currentID { refreshLive() }
            }
            // Undo would bring back a sticker that no longer exists.
            undoManager?.removeAllActions()
        } catch {
            alert = AppAlert(title: "スタンプを削除できませんでした", message: AppModel.describe(error))
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
                message: "\(names)\(photos.count > 3 ? "など\(photos.count)枚" : "")は写真です。どの動画でも隠す人の顔写真として使うときは、「設定」（⌘,）の顔写真の欄に追加してください。")
        }
        for url in urls where url.isFileURL && !Self.isPhoto(url) {
            if let existing = videos.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                if firstNew == nil { firstNew = existing.id }
                continue
            }
            let v = VideoItem(url: url)
            videos.append(v)
            pendingPurpose.append(v.id)
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
                // Removed meanwhile ("キャンセル" in the sheet, or taken off the list).
                guard videos.contains(where: { $0.id == v.id }) else { return }
                let item = AVPlayerItem(asset: v.asset)
                let comp = try await v.live.composition(for: v.asset)
                item.videoComposition = comp
                v.info = i
                v.sourceItem = item
                v.composition = comp
                v.state = .idle
                if v.id == currentID { showCurrent(previous: nil) }
                startChosen(v)
                v.poster = await Self.poster(v.asset, duration: i.duration)
            } catch {
                v.state = .failed(Self.describe(error))
            }
        }
    }

    /// Apply the choice to the videos just added and start what was chosen.
    func choosePurpose(_ p: Purpose) {
        lastPurpose = p
        let ids = pendingPurpose
        pendingPurpose = []
        for v in videos where ids.contains(v.id) {
            v.purpose = p
            startChosen(v)
        }
        followPurpose()
    }

    /// Do not add the videos after all.
    func cancelPurpose() {
        let ids = pendingPurpose
        pendingPurpose = []
        for id in ids { remove(id) }
    }

    /// Start the searches the user chose, once the video is loaded and the choice is made.
    private func startChosen(_ v: VideoItem) {
        guard v.isReady, let p = v.purpose else { return }
        if p.findsFaces, v.state == .idle {
            v.state = .waiting
            processQueue()
        }
        if p.readsText, v.textState == nil { scanText(v) }
    }

    /// Show the tab of what the current video is for (one purpose only). Otherwise the text
    /// tab, which starts reading when shown, would read a video added for faces.
    private func followPurpose() {
        switch current?.purpose {
        case .faces: inspectorTab = .people
        case .text: inspectorTab = .text
        case .both, nil: break
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
        if textScanningID == id { textTask?.cancel() }
        let v = videos.remove(at: idx)
        pendingPurpose.removeAll { $0 == id }
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
        if v.purpose == .text { v.purpose = .both }  // faces asked for later
        v.analysis = nil
        v.thumbnails = [:]
        v.scenes = [:]
        v.registeredHints = [:]
        v.crossHints = [:]
        v.focusedPerson = nil
        v.selected = []
        v.stickers = [:]
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
        apply(s, to: v, action: on ? "顔を隠す" : "顔を隠すのをやめる")
    }

    func selectAll() {
        guard let v = current else { return }
        apply(Set(v.analysis?.people.map(\.id) ?? []), to: v, action: "全員を隠す")
    }

    func clearAll() {
        guard let v = current else { return }
        apply([], to: v, action: "全員を隠すのをやめる")
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

    // MARK: - On-screen text (one video at a time, like faces)

    /// Read the text on screen in `v` (queued if another video is being read).
    func scanText(_ v: VideoItem) {
        // Nothing is searched before the user chose what to hide in the video.
        guard v.isReady, v.purpose != nil, v.textScanning == nil, v.textState != .waiting else { return }
        if v.purpose == .faces { v.purpose = .both }  // text asked for later
        if v.text != nil { undoManager?.removeAllActions() }  // line numbers change; old checks no longer apply
        v.text = nil
        v.textMask = nil
        v.textOptions = nil
        v.textMaskOptions = nil
        v.textMaskRequest += 1
        v.textLines = []
        v.textState = .waiting
        processTextQueue()
    }

    func cancelTextScan() {
        guard let id = current?.id else { return }
        if textScanningID == id {
            textTask?.cancel()
        } else if let v = current, v.textState == .waiting {
            v.textState = .cancelled
        }
    }

    private func processTextQueue() {
        guard textTask == nil else { return }
        let next = current.flatMap { $0.textState == .waiting ? $0 : nil } ?? videos.first { $0.textState == .waiting }
        guard let v = next, let i = v.info else { return }
        let id = v.id
        let a = v.asset
        v.textState = .running(0)
        textScanningID = id
        textTask = Task.detached(priority: .userInitiated) { [weak self] in
            weak let model = self
            let total = max(1, Int((i.fps * i.duration).rounded()))
            var last = Date.distantPast
            do {
                let text = try analyzeText(asset: a, info: i, workers: textWorkerCount()) { n in
                    let now = Date()
                    guard now.timeIntervalSince(last) > 0.1 else { return }
                    last = now
                    let p = min(0.99, Double(n) / Double(total))
                    Task { @MainActor in model?.textProgress(id, p) }
                }
                await model?.finishTextScan(id, .success(text))
            } catch {
                let cancelled = error is CancellationError || Task.isCancelled
                await model?.finishTextScan(id, .failure(cancelled ? CancellationError() : error))
            }
        }
    }

    private func textProgress(_ id: UUID, _ p: Double) {
        guard let v = videos.first(where: { $0.id == id }), v.textScanning != nil else { return }
        v.textState = .running(p)
    }

    private func finishTextScan(_ id: UUID, _ result: Result<ScreenText, Error>) {
        if textScanningID == id {
            textTask = nil
            textScanningID = nil
        }
        if let v = videos.first(where: { $0.id == id }) {
            switch result {
            case .success(let text):
                v.text = text
                v.textState = .done
                updateTextMask(v)
            case .failure(let error) where error is CancellationError:
                v.textState = .cancelled
            case .failure(let error):
                v.textState = .failed(Self.describe(error))
            }
        }
        processTextQueue()
    }

    private func updateTextMasks() {
        for v in videos where v.text != nil { updateTextMask(v) }
    }

    private func updateTextMask(_ v: VideoItem) {
        guard let text = v.text else { return }
        let o = TextMaskOptions(kinds: textKinds, words: textWords, lines: v.textLines, all: v.textAll)
        guard v.textOptions != o else { return }  // made already, or being made
        v.textOptions = o
        // Long recordings take a while: make it in the background. Export waits for it
        // (`textMaskPending`, `ensureTextMask`); an outdated one is cancelled and dropped.
        let id = v.id
        v.textMaskTask?.cancel()
        v.textMaskRequest += 1
        let request = v.textMaskRequest
        v.textMaskTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let mask = text.maskUnlessCancelled(o) else { return }
            await self?.setTextMask(id, request, mask, for: o)
        }
    }

    /// Make the mask for the current options now if the background one is not done (a video
    /// waiting in the export queue while the options changed).
    private func ensureTextMask(_ v: VideoItem) async {
        while v.textMaskPending, let text = v.text, let o = v.textOptions {
            v.textMaskTask?.cancel()
            v.textMaskRequest += 1
            let request = v.textMaskRequest
            let mask = await Task.detached(priority: .userInitiated) { text.mask(o) }.value
            if v.textMaskRequest == request { setTextMask(v.id, request, mask, for: o) }
        }
    }

    private func setTextMask(_ id: UUID, _ request: Int, _ mask: TextMask, for o: TextMaskOptions) {
        guard let v = videos.first(where: { $0.id == id }), v.textMaskRequest == request else { return }
        v.textMask = mask
        v.textMaskOptions = o
        if id == currentID { refreshLive() }
    }

    /// Hide every line that was read in the current video, or go back to the choices.
    func setTextAll(_ on: Bool) {
        guard let v = current, v.textAll != on else { return }
        v.textAll = on
        updateTextMask(v)
    }

    /// Hide or show a whole line of the current video (undoable).
    func setTextLine(_ entry: Int, _ on: Bool) {
        guard let v = current else { return }
        var s = v.textLines
        if on { s.insert(entry) } else { s.remove(entry) }
        applyTextLines(s, to: v, action: on ? "行全体を隠す" : "行全体を隠すのをやめる")
    }

    private func applyTextLines(_ lines: Set<Int>, to v: VideoItem, action: String) {
        let old = v.textLines
        guard old != lines else { return }
        v.textLines = lines
        updateTextMask(v)
        guard let um = undoManager else { return }
        let id = v.id
        um.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                guard let v = model.videos.first(where: { $0.id == id }), v.text != nil else { return }
                if model.currentID != id { model.currentID = id }
                model.applyTextLines(old, to: v, action: action)
            }
        }
        um.setActionName(action)
    }

    func addTextWord(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !textWords.contains(w) else { return }
        textWords.append(w)
    }

    func removeTextWord(_ word: String) {
        textWords.removeAll { $0 == word }
    }

    /// Apply words typed but not confirmed with Return (the export button does not take the
    /// focus from the field, so leaving it does not apply them).
    /// Not confirmed by the user, so an emptied word is kept (only Return or ⊗ removes one):
    /// a field being retyped must not stop hiding the word. Returns whether a word changed.
    @discardableResult
    func commitWordDrafts() -> Bool {
        let drafts = wordDrafts
        wordDrafts = [:]
        let before = textWords
        for (old, new) in drafts where !Self.isBlank(new) && new != old {
            if old.isEmpty { addTextWord(new) } else { replaceTextWord(old, with: new) }
        }
        return textWords != before
    }

    /// A draft that would change the words when applied.
    var hasWordDraft: Bool { wordDrafts.contains { !Self.isBlank($0.value) && $0.value != $0.key } }

    static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Change a word in place; emptied, it is removed, and a word already listed is not doubled.
    func replaceTextWord(_ old: String, with new: String) {
        let w = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard w != old, let i = textWords.firstIndex(of: old) else { return }
        if w.isEmpty || textWords.contains(w) {
            textWords.remove(at: i)
        } else {
            textWords[i] = w
        }
    }

    // MARK: - Player

    /// Push the current selection and settings to the player's mosaic and redraw if paused.
    private func refreshLive() {
        guard let v = current else { return }
        v.live.update(frames: frames(for: v), render: render(for: v), enabled: viewMode == .mosaic)
        redrawIfPaused()
    }

    /// What is hidden in each frame of `v` with the current choices and settings.
    private func frames(for v: VideoItem) -> [FrameFaces] {
        v.frames(hold: hold, stickered: Set(activeStickers(v).keys))
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
        let left = cancelPendingSeek() ?? currentTime
        if let previous, let old = videos.first(where: { $0.id == previous }) { old.lastTime = left }
        player.pause()
        playbackRate = 1  // a faster speed is easy to forget; each video starts at normal speed
        timelineHover = nil  // the timeline is rebuilt for the new video without a hover end
        resetZoom()  // another video starts whole: an enlarged view hides what is outside it
        guard let v = current, v.isReady else {
            player.replaceCurrentItem(with: nil)
            currentTime = 0
            return
        }
        if viewMode == .result && v.resultItem == nil { viewMode = .mosaic }
        let target = viewMode == .result ? v.resultItem : v.sourceItem
        if player.currentItem !== target { player.replaceCurrentItem(with: target) }
        let t = v.lastTime
        player.seek(to: cmTime(t), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = t
        refreshLive()
        processQueue()  // the shown video goes first in the queue
    }

    private func applyViewMode() {
        guard let v = current else { return }
        let t = cancelPendingSeek().map(cmTime) ?? player.currentTime()
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
        if let t = cancelPendingSeek() {
            // Play from where the playhead was dragged, not from the frame still on screen.
            player.seek(to: cmTime(t), toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = t
        }
        if isPlaying {
            player.pause()
        } else {
            if let d = player.currentItem?.duration.seconds, d.isFinite, currentTime >= d - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
        }
    }

    /// Go to `t` exactly. Seeks are chased (Apple QA1820): one at a time, each to the latest
    /// time asked, so dragging the playhead never queues up seeks behind a slow decoder.
    /// Exact seeks also on long-GOP video: the frame shown must be the one at the playhead, with
    /// its own mosaic and face boxes.
    func seek(to t: Double) {
        player.pause()
        pendingSeek = t
        guard !seeking else { return }
        seeking = true
        Task {
            while let target = pendingSeek {
                _ = await player.seek(to: cmTime(target), toleranceBefore: .zero, toleranceAfter: .zero)
                if pendingSeek == target { pendingSeek = nil }
            }
            let now = player.currentTime().seconds
            if now.isFinite { currentTime = now }
            seeking = false
        }
    }

    /// Drops a seek not yet done; returns where it was going.
    private func cancelPendingSeek() -> Double? {
        defer { pendingSeek = nil }
        return pendingSeek
    }

    /// `t` in the video track's time scale, so that a frame's time maps back to exactly that
    /// frame (with 1/600 s, a 59.94 fps frame time can round to just before the frame, and an
    /// exact seek then shows the frame before).
    private func cmTime(_ t: Double) -> CMTime {
        CMTime(seconds: t, preferredTimescale: max(600, current?.info?.timeScale ?? 600))
    }

    /// L: play, or play faster when already playing (up to 2×).
    func faster() {
        guard player.currentItem != nil else { return }
        if isPlaying, let next = Self.playbackRates.first(where: { $0 > playbackRate }) {
            playbackRate = next
        } else if !isPlaying {
            togglePlay()
        }
    }

    /// The dips of the exported file before or after the playhead, for the Play menu.
    func dip(after: Bool) -> Dip? {
        guard let dips = current?.summary?.dips, !dips.isEmpty else { return nil }
        let t = playheadTime
        if after { return dips.first { $0.start > t + 0.01 } }
        return dips.last { $0.start < t - 0.01 }
    }

    /// Player keys in the main window, as in QuickTime Player: Space play/pause, ←/→ one frame,
    /// ⇧←/⇧→ one second, K pause, L play (faster). Not while typing (Space also converts kana),
    /// in a sheet or another window, or on a control that uses the key itself.
    private func handleKey(_ e: NSEvent) -> Bool {
        guard let w = e.window, w === mainWindow, w.attachedSheet == nil, hasVideo, player.currentItem != nil,
            e.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return false }
        let responder = w.firstResponder
        if responder is NSTextView { return false }  // a text field is being edited
        if let input = responder as? NSTextInputClient, input.hasMarkedText() { return false }
        let shift = e.modifierFlags.contains(.shift)
        switch e.keyCode {
        case 49:  // Space
            if responder is NSButton { return false }  // pressing the focused button (Full Keyboard Access)
            togglePlay()
        case 123, 124:  // ← →
            if responder is NSSlider || responder is NSStepper || responder is NSSegmentedControl { return false }
            let forward = e.keyCode == 124
            if shift {
                let d = player.currentItem?.duration.seconds ?? 0
                seek(to: min(max(playheadTime + (forward ? 1 : -1), 0), d.isFinite ? d : playheadTime))
            } else {
                step(forward ? 1 : -1)
            }
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "k": player.pause()
            case "l": faster()
            default: return false
            }
        }
        return true
    }

    /// Selecting a person in the list shows them: if they are not on screen at the current
    /// time, go to the moment they first appear.
    func reveal(_ id: Int) {
        guard let v = current, let analysis = v.analysis, let p = v.person(id) else { return }
        let frame = analysis.frameIndex(at: currentTime)
        let onScreen = analysis.faces(atFrame: frame).contains { $0.person == id }
        if !onScreen || viewMode == .result { jump(to: p) } else { showZoomed(person: id, atFrame: frame) }
    }

    /// Go to the start of this person's next scene after the current time; after the last
    /// one, back to the first.
    func nextScene(_ id: Int) {
        guard let v = current, let first = v.scenes[id]?.first else { return }
        if viewMode == .result { viewMode = .mosaic }
        let next = v.scenes[id]?.first { $0.lowerBound > currentTime + 0.01 } ?? first
        v.focusedPerson = id
        if let analysis = v.analysis { showZoomed(person: id, atFrame: analysis.frameIndex(at: next.lowerBound)) }
        seek(to: next.lowerBound)
    }

    /// Step one frame (AVPlayerItem.step keeps the composition's mosaic in sync).
    func step(_ frames: Int) {
        player.pause()
        // Still seeking: step from where the playhead is going, not from the frame on screen.
        if let t = cancelPendingSeek() {
            if let times = frameTimes {
                // The frame times themselves: right also for variable frame rate recordings.
                seek(to: times[min(max(frameIndex(times, at: t) + frames, 0), times.count - 1)])
            } else if let fps = current?.info?.fps, fps > 0 {
                seek(to: t + Double(frames) / fps)
            }
            return
        }
        player.currentItem?.step(byCount: frames)
    }

    func jump(to person: Person) {
        guard let v = current, let analysis = v.analysis else { return }
        if viewMode == .result { viewMode = .mosaic }
        v.focusedPerson = person.id
        showZoomed(person: person.id, atFrame: person.firstFrame)
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
        commitWordDrafts()
        // A word just applied remakes the text mosaic: those videos are offered too, and
        // their rows turn on when it is done.
        let soon: (VideoItem) -> Bool = { $0.canExport || ($0.textMaskPending && !$0.job.isActive && !$0.stillSearching) }
        let ready = videos.filter(soon)
        // Not while the "what to hide" sheet is open: it would be hidden behind this one.
        guard !ready.isEmpty, !isExporting, pendingPurpose.isEmpty else { return }
        // Pre-check what still needs writing; an already written, unchanged video stays
        // unchecked (writing it again would only add a numbered copy).
        var choice = Set(ready.filter { $0.textMaskPending || $0.hasUnexportedWork(mosaicParams) }.map(\.id))
        if choice.isEmpty, let c = current, soon(c) { choice = [c.id] }
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
        // A word applied now remakes the text mosaic: stay in the sheet, whose rows show that
        // and turn on again when it is done.
        if commitWordDrafts() { return }
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
        await ensureTextMask(v)
        // The options may have changed while it waited (a word removed): nothing to hide any
        // more is not written as a "mosaic" copy.
        guard v.hasChoices else {
            v.job = .failed("隠すものがなくなりました")
            if alertOnFailure {
                alert = AppAlert(title: "書き出しませんでした", message: "待っている間に選択が変わり、「\(v.name)」には隠すものがなくなりました。")
            }
            return
        }
        let frames = frames(for: v)
        let render = render(for: v)
        let selection = v.selected
        let stickers = activeStickers(v)
        let params = mosaicParams
        // What the frames were made with (not what is set now), so a later change shows as
        // not written yet.
        let textOptions = v.hiddenTextCount > 0 ? v.textMaskOptions : nil
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
                mosaicFrames: frames.filter(\.hidesAnything).count, dips: findDips(frames),
                elapsed: Date().timeIntervalSince(started), selection: selection, params: params, text: textOptions,
                stickers: stickers)
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
        resetZoom()  // checking the exported file: the whole picture, not a part of it
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
