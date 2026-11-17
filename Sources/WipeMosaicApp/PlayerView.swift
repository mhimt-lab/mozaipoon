import AVKit
import SwiftUI
import WipeMosaicCore

/// AVKit's player, enlarged and moved inside a viewer that clips it (see `ZoomGeometry`).
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    let videoSize: CGSize
    let zoom: CGFloat
    let center: CGPoint
    let found: (NSView) -> Void
    /// Dragging the enlarged video moves it (points; positive = down and right).
    let drag: (CGVector) -> Void

    func makeNSView(context: Context) -> ZoomingPlayerView {
        let v = ZoomingPlayerView()
        let pv = v.playerView
        pv.player = player
        // The app draws its own always-visible bar under the video (TransportBar):
        // AVKit's controls hide unless the pointer is over the video.
        pv.controlsStyle = .none
        pv.videoGravity = .resizeAspect
        pv.showsFrameSteppingButtons = true
        pv.showsFullScreenToggleButton = false  // full screen would hide the face boxes
        pv.allowsPictureInPicturePlayback = false
        pv.allowsVideoFrameAnalysis = false  // no Live Text / subject lifting on private footage
        pv.showsSharingServiceButton = false
        v.drag = drag
        found(v)
        return v
    }

    func updateNSView(_ v: ZoomingPlayerView, context: Context) {
        if v.playerView.player !== player { v.playerView.player = player }
        v.place(video: videoSize, zoom: zoom, center: center)
    }
}

/// Clips the player view, which is the viewer enlarged `zoom` times: AVPlayerLayer scales the
/// decoded frame on the GPU, so the picture stays sharp and no large image is made.
final class ZoomingPlayerView: NSView {
    let playerView = AVPlayerView()
    private var video = CGSize(width: 16, height: 9)
    private var zoom: CGFloat = 1
    private var center = CGPoint(x: 0.5, y: 0.5)
    var drag: ((CGVector) -> Void)?
    private var lastDrag: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        clipsToBounds = true  // not the default since macOS 14
        playerView.autoresizingMask = []
        addSubview(playerView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func place(video: CGSize, zoom: CGFloat, center: CGPoint) {
        let wasZoomed = self.zoom > 1
        self.video = video
        self.zoom = zoom
        self.center = center
        layoutPlayer()
        if wasZoomed != (zoom > 1) { window?.invalidateCursorRects(for: self) }
    }

    // While enlarged, the video can be dragged like a photo (the mouse has no horizontal
    // wheel); the face boxes above still take their own clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard zoom > 1 else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        if zoom > 1 { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard zoom > 1 else { return super.mouseDown(with: event) }
        lastDrag = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard zoom > 1, let last = lastDrag else { return super.mouseDragged(with: event) }
        // From the positions (this view is flipped: y grows downward, as the delta expects).
        let p = convert(event.locationInWindow, from: nil)
        lastDrag = p
        drag?(CGVector(dx: p.x - last.x, dy: p.y - last.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard lastDrag != nil else { return super.mouseUp(with: event) }
        lastDrag = nil
        NSCursor.pop()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPlayer()
    }

    private func layoutPlayer() {
        let f = ZoomGeometry.playerFrame(viewer: bounds.size, video: video, zoom: zoom, center: center)
        if playerView.frame != f { playerView.frame = f }
    }
}

/// A second, small picture of the same player (for the zoom navigator). An AVPlayer can show
/// in several layers; the video composition renders once for all of them.
private struct MiniPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        v.layer = layer
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        if let layer = v.layer as? AVPlayerLayer, layer.player !== player { layer.player = player }
    }
}

/// The video with clickable face boxes on top (while paused).
struct ViewerView: View {
    @Bindable var model: AppModel
    @Bindable var video: VideoItem
    let videoSize: CGSize

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(
                player: model.player, videoSize: videoSize, zoom: model.zoom, center: model.zoomCenter,
                found: { model.viewerView = $0 }, drag: { model.panZoom(by: $0) })
                // Only behind the video: by default a background also fills the safe area, so the
                // black ran under the sidebar's glass and turned the whole sidebar dark gray.
                .background(.black, ignoresSafeAreaEdges: [])
                .overlay { textBoxes }
                .overlay { faceBoxes }
                .overlay { zoomNavigator }
                .overlay(alignment: .bottom) { analysisCard }
            TransportBar(model: model, video: video)
        }
    }

    // MARK: Face boxes

    private var faceBoxes: some View {
        GeometryReader { geo in
            let shown = shownVideo(geo.size)
            let s = shown.width / videoSize.width
            let viewer = CGRect(origin: .zero, size: geo.size)
            let stickered = Set(model.activeStickers(video).keys)
            GlassEffectContainer {
                ForEach(Array(model.visibleFaces.enumerated()), id: \.offset) { _, face in
                    // A hidden face's box is drawn where the mosaic or blur reaches (the face
                    // widened by 隠す広さ), so the box shows what gets covered. A sticker keeps
                    // the face's box: its own shape decides what it covers.
                    let widened = video.selected.contains(face.person) && !stickered.contains(face.person)
                    let r = widened ? padded(face.rect, model.pad) : face.rect  // Core Image coordinates (bottom-left origin)
                    let box = CGRect(
                        x: shown.minX + r.minX * s, y: shown.minY + (videoSize.height - r.maxY) * s,
                        width: r.width * s, height: r.height * s)
                    // While enlarged, a box partly outside the viewer is drawn whole (and clipped)
                    // but takes clicks only inside it: clipping hides the rest, yet still lets it
                    // be hit over the bar below.
                    let visible = box.intersection(viewer)
                    if visible.width >= 4, visible.height >= 4 {
                        FaceBox(
                            person: face.person,
                            mosaic: video.selected.contains(face.person),
                            focused: video.focusedPerson == face.person,
                            hit: visible.offsetBy(dx: -box.minX, dy: -box.minY),
                            // The name goes above the box, or inside its visible top when there
                            // is no room above.
                            labelInside: box.minY < 30
                        ) {
                            video.focusedPerson = face.person
                            model.toggle(face.person)
                        }
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                    }
                }
            }
        }
        .clipped()
        .animation(.snappy(duration: 0.2), value: video.selected)
    }

    // MARK: Zoom navigator

    /// While enlarged: the whole video in small with the part in view outlined, and the zoom.
    /// Over the video, where the eyes are, so it is not forgotten that the rest is not in view.
    @ViewBuilder
    private var zoomNavigator: some View {
        if model.zoom > 1 {
            GeometryReader { geo in
                let part = model.visiblePart(viewer: geo.size, video: videoSize)
                let landscape = videoSize.width >= videoSize.height
                let w = landscape ? 88 : 64 * videoSize.width / max(videoSize.height, 1)
                let h = landscape ? 88 * videoSize.height / max(videoSize.width, 1) : 64
                Button {
                    model.resetZoom()
                } label: {
                    HStack(spacing: 8) {
                        ZStack(alignment: .topLeading) {
                            // The same player drawn small: the same picture as the viewer (with
                            // the mosaic in "隠した表示"), nothing more.
                            MiniPlayerView(player: model.player)
                                .clipShape(.rect(cornerRadius: 3))
                            // Outside the part in view darkened, the part itself outlined.
                            let inView = CGRect(
                                x: part.minX * w, y: part.minY * h,
                                width: max(part.width * w, 4), height: max(part.height * h, 4))
                            Path { p in
                                p.addRect(CGRect(x: 0, y: 0, width: w, height: h))
                                p.addRect(inView)
                            }
                            .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                            Path(inView)
                                .stroke(.white, lineWidth: 1.5)
                                .shadow(color: .black.opacity(0.6), radius: 1)
                        }
                        .frame(width: w, height: h)
                        Text(model.zoomLabel)
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                .help("拡大して表示しています。白い枠の中だけが見えています。押すと全体を表示します（⌘0）。拡大中は動画をドラッグかスクロールで動かせます")
                .accessibilityLabel("拡大 \(model.zoomLabel)")
                .accessibilityHint("全体を表示します")
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .transition(.opacity)
        }
    }

    /// Where the video is drawn in a viewer of this size (enlarged and moved by the zoom).
    private func shownVideo(_ viewer: CGSize) -> CGRect {
        ZoomGeometry.videoRect(viewer: viewer, video: videoSize, zoom: model.zoom, center: model.zoomCenter)
    }

    // MARK: Text boxes

    /// Dashed outlines where text is hidden (not written to the file). Boxes that overlap or
    /// touch (the words of one line) are outlined as one shape, not as doubled edges. A QR code
    /// is outlined along its four corners, as its mosaic is cut.
    private var textBoxes: some View {
        GeometryReader { geo in
            let shown = shownVideo(geo.size)
            let s = shown.width / videoSize.width
            let visible = model.visibleTextBoxes
            let boxes = visible.boxes.reduce(Path()) { path, r in
                let box = CGRect(
                    x: shown.minX + r.minX * s, y: shown.minY + (videoSize.height - r.maxY) * s,
                    width: r.width * s, height: r.height * s)
                // Widened by a point so boxes a hair apart join too.
                return path.union(Path(roundedRect: box.insetBy(dx: -1, dy: -1), cornerRadius: 3))
            }
            let outline = visible.codes.reduce(boxes) { path, q in
                var quad = Path()
                quad.addLines(q.map { CGPoint(x: shown.minX + $0.x * s, y: shown.minY + (videoSize.height - $0.y) * s) })
                quad.closeSubpath()
                return path.union(quad)
            }
            // A dark line under the orange one, so the outline also shows on white (a QR code,
            // a light screen).
            ZStack {
                outline.stroke(Color.black.opacity(0.45), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                outline.stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round, dash: [5, 3]))
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Analysis progress

    @ViewBuilder
    private var analysisCard: some View {
        if video.state == .waiting || video.state == .converting {
            Label(video.state == .waiting ? "前の動画の顔を探し終わるのを待っています" : "再生できる形式の一時ファイルを作っています",
                  systemImage: video.state == .waiting ? "clock" : "arrow.triangle.2.circlepath")
                .font(.callout)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 16)
        } else if let p = video.analyzing {
            VStack(alignment: .leading, spacing: 12) {
                Label("顔を探しています", systemImage: "faceid")
                    .font(.headline)
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                HStack {
                    Text(["\(Int(p * 100))%", remainingLabel(since: video.analysisStarted, fraction: p)].compactMap { $0 }.joined(separator: "・"))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("中止") { model.cancelAnalysis() }
                        .buttonStyle(.glass)
                }
            }
            .padding(20)
            .frame(width: 320)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .padding(.bottom, 16)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("顔を探しています。\(Int(p * 100))パーセント")
        }
    }
}

private struct FaceBox: View {
    let person: Int
    let mosaic: Bool
    let focused: Bool
    /// The clickable part, in the box's own coordinates.
    let hit: CGRect
    let labelInside: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    mosaic ? Color.accentColor : Color.white.opacity(0.85),
                    style: StrokeStyle(lineWidth: focused ? 3.5 : 2, dash: mosaic ? [] : [6, 4]))
                .shadow(color: .black.opacity(0.5), radius: 2)
                .contentShape(Path(hit))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            Label {
                Text("人物 \(person)").foregroundStyle(.primary)
            } icon: {
                Image(systemName: mosaic ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(mosaic ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            }
                .font(.callout.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .glassEffect(.regular, in: .capsule)
                .fixedSize()
                .alignmentGuide(.top) { d in labelInside ? -(hit.minY + 4) : d[.bottom] + 4 }
                .alignmentGuide(.leading) { _ in -hit.minX }
                .allowsHitTesting(false)
                .accessibilityHidden(true)  // the box itself carries the label
        }
        .help(mosaic ? "押すと、この人の顔を隠すのをやめます" : "押すと、この人の顔を隠します")
        .accessibilityLabel("人物 \(person)")
        .accessibilityValue(mosaic ? "隠す" : "隠さない")
        .accessibilityHint("この人の顔を隠すかを切り替えます")
    }
}

/// Play/pause, frame steps, time and a timeline that marks where the selected person
/// appears (accent when they get a mosaic). Always visible, below the video.
private struct TransportBar: View {
    @Bindable var model: AppModel
    @Bindable var video: VideoItem

    private var duration: Double {
        let d = model.player.currentItem?.duration.seconds ?? video.info?.duration ?? 0
        return d.isFinite && d > 0 ? d : max(video.info?.duration ?? 1, 0.01)
    }

    private var hasDips: Bool { !model.shownDips.isEmpty }

    var body: some View {
        // The timeline has the first line to itself and the buttons: the time and the frame
        // number are at the end of the line under it (beside the timeline they left it a
        // third of the bar at the default window size).
        layout
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar, ignoresSafeAreaEdges: [])  // not under the sidebar either (a white band at its foot)
    }

    /// The timeline across the whole bar, the buttons under it (as editing apps lay a viewer
    /// out), then one line that says what the marks mean.
    private var layout: some View {
        VStack(alignment: .leading, spacing: 4) {
            Timeline(model: model, video: video, duration: duration)
                // Room for the dip markers above the track (they sit over the bar's top padding)
                // and for the time marks under it.
                .padding(.top, hasDips ? Timeline.dipRow - 10 : 0)
                .padding(.bottom, Timeline.rulerRow - 2)
            // The buttons in the middle, the time before them and the view's switches after;
            // in a narrow bar (both side columns open in a small window) on two lines, then
            // without the buttons that have a key and a menu item.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    position
                    Spacer(minLength: 0)
                    transport(full: true)
                    Spacer(minLength: 0)
                    switches
                }
                VStack(spacing: 4) {
                    transport(full: true)
                    HStack(spacing: 8) {
                        position
                        Spacer(minLength: 0)
                        switches
                    }
                }
                VStack(spacing: 4) {
                    transport(full: false)
                    HStack(spacing: 8) {
                        timeLabel
                        Spacer(minLength: 0)
                        switches
                    }
                }
            }
            .font(.title3)
            // Always one line, so the video does not grow and shrink as a person is chosen.
            caption
                .lineLimit(1)
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// The time and the frame number, read together.
    private var position: some View {
        HStack(spacing: 10) {
            timeLabel
            frameLabel
        }
    }

    private var timeLabel: some View {
        Text("\(formatTime(model.playheadTime)) / \(formatDuration(duration))")
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    @ViewBuilder
    private var caption: some View {
        if model.viewMode == .result, hasDips {
            // In the written file the markers are what to look at.
            dipCaption
        } else if let id = video.focusedPerson, video.scenes[id] != nil {
            Text(video.selected.contains(id)
                 ? "青い太線は「人物 \(id)」が映っている場面です（隠す人）。"
                 : "太線は「人物 \(id)」が映っている場面です（まだ隠していない人）。")
        } else if hasDips {
            dipCaption
        } else if model.viewMode != .original, !video.coverRanges.isEmpty {
            // The line's blue is said here while nothing else is: without it, a line blue
            // from end to end reads as "played".
            Text("線の青い所は、顔や文字を隠している区間です。")
        } else {
            Text(" ").accessibilityHidden(true)
        }
    }

    /// What the ▼ are and how many were looked at; all of them: said with a mark that moves once.
    @ViewBuilder
    private var dipCaption: some View {
        let dips = model.shownDips
        let checked = dips.filter { video.checkedDips.contains($0.id) }.count
        if checked == dips.count {
            Label {
                Text("確かめてほしい場面を、\(dips.count)か所すべて確かめました。")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: model.allCheckedPulse)
            }
        } else {
            Text("\(Text(Image(systemName: "arrowtriangle.down.fill")).foregroundStyle(.orange))は確かめてほしい場面です（押すとその場面へ。⌘] で次へ）。\(dips.count)か所中\(checked)か所を確かめました。")
        }
    }

    /// One switch for the face boxes and the text outlines (both when both are found). In the
    /// bar rather than over the video, where it would cover what is being checked.
    private var boxToggle: some View {
        // A toggle button: on is shown by its background, not only by colour. One symbol for
        // the face boxes and the text outlines (a person symbol read as a contact).
        // Shown off while it cannot be used (no boxes are drawn then), not as a dimmed "on".
        Toggle(isOn: Binding(get: { model.showFaceBoxes && model.canToggleBoxes }, set: { model.showFaceBoxes = $0 })) {
            Label("枠を表示", systemImage: "rectangle.dashed")
                .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        // The bar's borderless style would hide the "on" background.
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!model.canToggleBoxes)
        .help(model.showFaceBoxes
              ? "一時停止中に出る顔の枠と、文字を隠す範囲の枠（橙の点線）を隠す（⌘B）。書き出す動画には入りません"
              : "一時停止中に顔の枠と、文字を隠す範囲の枠（橙の点線）を表示する（⌘B）")
    }

    /// The frame on screen (its boxes), to tell one frame from the next; the count is in the
    /// help. As wide as the largest number from the start, so the line does not shift while
    /// the number grows. Dimmed while the picture is still catching up with the playhead (the
    /// number is that of the frame shown).
    @ViewBuilder
    private var frameLabel: some View {
        if let n = model.frameNumber {
            Text("コマ \(n.count)")
                .hidden()
                .overlay(alignment: .trailing) {
                    Text("コマ \(n.index)")
                }
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .opacity(model.pendingSeek == nil ? 1 : 0.5)
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("コマ \(n.index)、全\(n.count)コマ")
                .help("いま表示しているコマの番号（全\(n.count)コマ）")
        }
    }

    /// The playback buttons, as on an editing app's viewer: first frame, one frame back,
    /// play backward, stop, play, one frame on, last frame, repeat. The one in effect keeps
    /// its round patch. `full` false leaves out the first and last frame and repeat (Home,
    /// End and the Play menu have them).
    private func transport(full: Bool) -> some View {
        HStack(spacing: 2) {
            if full {
                Button { model.seekToStart() } label: {
                    Label("最初のコマへ", systemImage: "backward.end.alt.fill").labelStyle(.iconOnly)
                }
                .transportButton(model, "start")
                .help("最初のコマへ（home）")
            }
            Button { model.step(-1) } label: {
                Label("1コマ戻る", systemImage: "backward.frame.fill").labelStyle(.iconOnly)
            }
            .buttonRepeatBehavior(.enabled)
            .transportButton(model, "back")
            .help("1コマ戻る（←。⇧←で1秒戻る。押し続けると戻り続けます）")
            Button { model.playReverse() } label: {
                Label("逆再生", systemImage: "arrowtriangle.backward.fill").labelStyle(.iconOnly)
            }
            .transportButton(model, "reverse", size: 32, active: model.isPlaying && model.isReversing)
            .disabled(!model.canPlayReverse)
            .help("逆再生（J）")
            Button { model.stop() } label: {
                Label("停止", systemImage: "stop.fill").labelStyle(.iconOnly)
            }
            .transportButton(model, "stop", size: 32)
            .help("停止（K、スペース）")
            Button { model.play() } label: {
                Label("再生", systemImage: "play.fill").labelStyle(.iconOnly)
            }
            .transportButton(model, "play", size: 32, active: model.isPlaying && !model.isReversing)
            .help("再生（スペース。L でもう一度押すと速くなる）")
            Button { model.step(1) } label: {
                Label("1コマ進む", systemImage: "forward.frame.fill").labelStyle(.iconOnly)
            }
            .buttonRepeatBehavior(.enabled)
            .transportButton(model, "forward")
            .help("1コマ進む（→。⇧→で1秒進む。押し続けると進み続けます）")
            if full {
                Button { model.seekToEnd() } label: {
                    Label("最後のコマへ", systemImage: "forward.end.alt.fill").labelStyle(.iconOnly)
                }
                .transportButton(model, "end")
                .help("最後のコマへ（end）")
                Button { model.loops.toggle() } label: {
                    Label("繰り返し再生", systemImage: "repeat").labelStyle(.iconOnly)
                }
                .transportButton(model, "loop", active: model.loops)
                .help(model.loops ? "繰り返し再生をやめる" : "最後まで再生したら、最初から繰り返す")
                .accessibilityValue(model.loops ? "オン" : "オフ")
            }
        }
    }

    /// After the buttons: the places to check before and after the playhead (when there are
    /// any), the speed, the sound and the outlines.
    private var switches: some View {
        HStack(spacing: 6) {
            // Only while there are places to check: two dimmed buttons said nothing.
            if hasDips {
                HStack(spacing: 2) {
                    Button {
                        if let d = model.dip(after: false) ?? model.shownDips.last { model.reviewShown(d) }
                    } label: {
                        Label("前の確かめてほしい場面", systemImage: "backward.end.fill").labelStyle(.iconOnly)
                    }
                    .transportButton(model, "prevDip")
                    .help("前の確かめてほしい場面へ（⌘[）")
                    Button {
                        if let d = model.dip(after: true) ?? model.shownDips.first { model.reviewShown(d) }
                    } label: {
                        Label("次の確かめてほしい場面", systemImage: "forward.end.fill").labelStyle(.iconOnly)
                    }
                    .transportButton(model, "nextDip")
                    .help("次の確かめてほしい場面へ（⌘]）")
                }
            }
            // The speed, always in sight (at a faster one, a few frames left unhidden are easy
            // to miss) and changed here, not only in the Play menu.
            Menu {
                Picker("速さ", selection: Binding(get: { model.playbackRate }, set: { model.playbackRate = $0 })) {
                    ForEach(AppModel.playbackRates, id: \.self) { r in
                        Text(r == 1 ? "ふつう（1倍）" : rateLabel(r)).tag(r)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(rateLabel(model.playbackRate))
                    .font(.callout.weight(model.playbackRate == 1 ? .regular : .semibold))
                    .monospacedDigit()
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help("再生の速さ（L で速く、K で停止）")
            .accessibilityLabel("再生の速さ：\(rateLabel(model.playbackRate))")
            Button {
                model.isMuted.toggle()
            } label: {
                Label(model.isMuted ? "音を出す" : "音を消す", systemImage: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .labelStyle(.iconOnly)
                    .contentTransition(.symbolEffect(.replace))
                    .font(.body)
            }
            .transportButton(model, "mute", size: 26)
            .help(model.isMuted ? "音を出す（M）" : "音を消す（M）。書き出す動画の音は変わりません")
            boxToggle
        }
    }
}

private struct Timeline: View {
    @Bindable var model: AppModel
    @Bindable var video: VideoItem
    let duration: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = { (t: Double) in CGFloat(min(max(t / duration, 0), 1)) * w }
            ZStack(alignment: .leading) {
                // Thin track, thick scene lines: in the same width and a near gray, the lines of a
                // person not hidden read as part of the track.
                // One line: gray, and in the color that means "hidden" where something is
                // hidden with the current choices. A gray stretch is one with nothing hidden.
                // (A band of its own under the track made two lines to read; a darker played
                // part would be a third shade.) Not in the original view, which hides nothing.
                Capsule().fill(.quaternary).frame(height: 4)
                if model.viewMode != .original {
                    ZStack(alignment: .leading) {
                        ForEach(Array(video.coverRanges.enumerated()), id: \.offset) { _, r in
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: max(2, x(r.upperBound) - x(r.lowerBound)), height: 4)
                                .offset(x: x(r.lowerBound))
                        }
                    }
                    .frame(width: w, height: 4, alignment: .leading)
                    .clipShape(.capsule)
                }
                if let id = video.focusedPerson, let scenes = video.scenes[id] {
                    let on = video.selected.contains(id)
                    ForEach(Array(scenes.enumerated()), id: \.offset) { _, r in
                        Capsule()
                            .fill(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.7)))
                            .frame(width: max(4, x(r.upperBound) - x(r.lowerBound)), height: 8)
                            .offset(x: x(r.lowerBound))
                    }
                }
                // The knob answers the pointer: a little larger over the track, larger still
                // while it is dragged.
                let knob: CGFloat = model.scrubbing ? 18 : model.timelineHover != nil ? 16 : 14
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(model.scrubbing ? 0.45 : 0.35), radius: model.scrubbing ? 3 : 1.5, y: model.scrubbing ? 1 : 0)
                    .frame(width: knob, height: knob)
                    .offset(x: x(model.playheadTime) - knob / 2)
                    .animation(.snappy(duration: 0.15), value: knob)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                model.scrubbing = true
                model.seek(to: Double(min(max(g.location.x / max(w, 1), 0), 1)) * duration)
            }.onEnded { _ in model.scrubbing = false })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): model.timelineHover = Double(min(max(p.x / max(w, 1), 0), 1)) * duration
                case .ended: model.timelineHover = nil
                }
            }
            .onDisappear {
                model.timelineHover = nil
                model.scrubbing = false
            }
            // Places to check (fewer faces hidden than just before and after) with the current
            // choices, or in the exported file while it is shown, above the track: a triangle,
            // not a color only.
            .overlay(alignment: .topLeading) {
                if hasDips {
                    ForEach(model.shownDips) { d in
                        Button {
                            model.reviewShown(d)
                        } label: {
                            // A glyph big enough to see and a target big enough to hit
                            // (24×24 pt), above the track so it does not take the knob's drags.
                            // Looked at: an outline in gray (the shape still says where it is).
                            Image(systemName: video.checkedDips.contains(d.id) ? "arrowtriangle.down" : "arrowtriangle.down.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(video.checkedDips.contains(d.id) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                                .padding(.bottom, 1)
                                .frame(width: 24, height: Self.dipRow, alignment: .bottom)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("確かめてほしい場面（\(formatTime(d.start))）：前後より隠す顔が減っています。押すとこの場面へ移動します\(video.checkedDips.contains(d.id) ? "（確かめました）" : "")")
                        .accessibilityLabel("確かめてほしい場面 \(formatTime(d.start))\(video.checkedDips.contains(d.id) ? "、確かめました" : "")")
                        .position(x: x(d.start), y: -Self.dipRow / 2)
                    }
                }
            }
            // The time marks under the track: a tick and a time at even steps, as many as fit.
            .overlay(alignment: .topLeading) {
                let step = Self.rulerStep(duration: duration, width: w)
                ForEach(Array(stride(from: 0.0, through: duration, by: step)), id: \.self) { t in
                    VStack(spacing: 1) {
                        Rectangle().fill(.tertiary).frame(width: 1, height: 4)
                        Text(Self.rulerLabel(t))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    // The first and last times stay inside the track's ends.
                    .position(x: min(max(x(t), 10), max(w - 10, 10)), y: geo.size.height + 9)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            // Under the pointer: the picture there and its time, above the track (over the
            // foot of the video, as players do), and above the ▼ when there are any.
            .overlay(alignment: .topLeading) {
                if let h = model.timelineHover {
                    let shown = model.hoverPicture
                    let pictureWidth: CGFloat = 168
                    let pictureHeight = shown.map { pictureWidth * CGFloat($0.height) / CGFloat(max($0.width, 1)) } ?? 0
                    let half = shown == nil ? 28 : pictureWidth / 2 + 4
                    VStack(spacing: 4) {
                        if let shown {
                            Image(decorative: shown, scale: 1)
                                .resizable()
                                .frame(width: pictureWidth, height: min(pictureHeight, 220))
                                .clipShape(.rect(cornerRadius: 6))
                        }
                        Text(formatTime(h))
                            .font(.caption)
                            .monospacedDigit()
                    }
                    .padding(shown == nil ? 0 : 4)
                    .padding(.horizontal, shown == nil ? 6 : 0)
                    .padding(.vertical, shown == nil ? 2 : 0)
                    .background(.regularMaterial, in: .rect(cornerRadius: shown == nil ? 9 : 10))
                    .shadow(color: .black.opacity(shown == nil ? 0 : 0.25), radius: 6, y: 2)
                    .fixedSize()
                    .position(
                        x: min(max(x(h), half), max(w - half, half)),
                        y: -(hasDips ? Self.dipRow : 4) - (shown == nil ? 10 : (min(pictureHeight, 220) + 30) / 2))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
        // The track in the middle, in line with the buttons and the time; the dip markers are
        // drawn above this frame (over the bar's top padding).
        .frame(height: 20)
        // The ▼ above the track are not in the slider that stands for it: the places to check
        // are its actions (and in the Play menu).
        .accessibilityRepresentation {
            Slider(value: Binding(get: { model.playheadTime }, set: { model.seek(to: $0) }), in: 0...duration) {
                Text("再生位置")
            }
            .accessibilityValue(formatTime(model.playheadTime))
            .accessibilityHint(hasDips ? "確かめてほしい場面が\(model.shownDips.count)か所あります" : "")
            .accessibilityAction(named: "次の確かめてほしい場面") {
                if let d = model.dip(after: true) ?? model.shownDips.first { model.reviewShown(d) }
            }
            .accessibilityAction(named: "前の確かめてほしい場面") {
                if let d = model.dip(after: false) ?? model.shownDips.last { model.reviewShown(d) }
            }
        }
    }

    private var hasDips: Bool { !model.shownDips.isEmpty }
    /// Height of the row of dip markers above the track (and of their click targets).
    static let dipRow: CGFloat = 24
    /// Height of the time marks under the track.
    static let rulerRow: CGFloat = 16

    /// Seconds between two time marks: the smallest even step that leaves `spacing` points
    /// between them.
    static func rulerStep(duration: Double, width: CGFloat, spacing: CGFloat = 64) -> Double {
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let least = duration * Double(spacing) / Double(max(width, 1))
        return steps.first { $0 >= least } ?? 7200
    }

    /// "0:30", "1:05:00"; halves of a second as "0:00.5".
    static func rulerLabel(_ t: Double) -> String {
        let s = Int(t)
        let base = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
        return t == t.rounded() ? base : base + ".5"
    }
}

/// A transport button: a round patch under the pointer, darker and a little smaller while
/// pressed (the bar's borderless buttons gave no sign of being under the pointer).
private struct TransportButtonStyle: ButtonStyle {
    let hovered: Bool
    let size: CGFloat
    /// In effect (playing this way, repeating): the patch stays.
    var active = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .frame(width: size, height: size)
            .background(
                configuration.isPressed ? AnyShapeStyle(.tertiary)
                    : active ? AnyShapeStyle(.tertiary.opacity(0.8))
                    : AnyShapeStyle(.quaternary.opacity(hovered && isEnabled ? 1 : 0)),
                in: .circle)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .contentShape(.circle)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.12), value: active)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private extension View {
    /// `TransportButtonStyle`, with the pointer followed in the model (`hoveredTransport`).
    func transportButton(_ model: AppModel, _ id: String, size: CGFloat = 28, active: Bool = false) -> some View {
        buttonStyle(TransportButtonStyle(hovered: model.hoveredTransport == id, size: size, active: active))
            .onHover { model.hoveredTransport = $0 ? id : (model.hoveredTransport == id ? nil : model.hoveredTransport) }
    }
}

/// "0.5倍", "2倍".
func rateLabel(_ r: Float) -> String {
    r == r.rounded() ? "\(Int(r))倍" : "\(r)倍"
}
