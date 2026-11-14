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
                .background(.black)
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
    /// touch (the words of one line) are outlined as one shape, not as doubled edges.
    private var textBoxes: some View {
        GeometryReader { geo in
            let shown = shownVideo(geo.size)
            let s = shown.width / videoSize.width
            let outline = model.visibleTextBoxes.reduce(Path()) { path, r in
                let box = CGRect(
                    x: shown.minX + r.minX * s, y: shown.minY + (videoSize.height - r.maxY) * s,
                    width: r.width * s, height: r.height * s)
                // Widened by a point so boxes a hair apart join too.
                return path.union(Path(roundedRect: box.insetBy(dx: -1, dy: -1), cornerRadius: 3))
            }
            outline.stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
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
                    Text("\(Int(p * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("中止", role: .cancel) { model.cancelAnalysis() }
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

    private var hasDips: Bool { video.summary?.dips.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // At the narrowest window the timeline keeps room to drag: the frame number goes
            // first, then the time.
            ViewThatFits(in: .horizontal) {
                controls(time: true, frame: true)
                controls(time: true, frame: false)
                controls(time: false, frame: false)
            }
            .buttonStyle(.borderless)
            .font(.title3)
            // Room for the dip markers above the track (they sit over the bar's top padding).
            .padding(.top, hasDips ? Timeline.dipRow - 10 : 0)
            // Always one line, so the video does not grow and shrink as a person is chosen.
            caption
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var caption: some View {
        if let id = video.focusedPerson, video.scenes[id] != nil {
            Text(video.selected.contains(id)
                 ? "青い太線は「人物 \(id)」が映っている場面です（隠す人）。"
                 : "太線は「人物 \(id)」が映っている場面です（まだ隠していない人）。")
        } else if hasDips {
            Text("\(Text(Image(systemName: "arrowtriangle.down.fill")).foregroundStyle(.orange))は書き出した動画で確かめてほしい場面です（押すとその場面へ）。")
        } else {
            Text(" ").accessibilityHidden(true)
        }
    }

    /// One switch for the face boxes and the text outlines (both when both are found). In the
    /// bar rather than over the video, where it would cover what is being checked.
    private var boxToggle: some View {
        let textOnly = video.analysis == nil
        let enabled = (video.analysis != nil || video.textMask != nil) && model.viewMode != .result
        return Button {
            model.showFaceBoxes.toggle()
        } label: {
            Label(model.showFaceBoxes ? "枠を隠す" : "枠を表示",
                  systemImage: textOnly ? "rectangle.dashed" : "person.crop.square")
                .labelStyle(.iconOnly)
                // Accent while the boxes show; an explicit style would hide the disabled look.
                .foregroundStyle(!enabled ? AnyShapeStyle(.tertiary)
                                 : model.showFaceBoxes ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .disabled(!enabled)
        .help(model.showFaceBoxes
              ? "一時停止中に出る顔の枠と、文字を隠す範囲の枠（橙の点線）を隠す（⌘B）。書き出す動画には入りません"
              : "一時停止中に顔の枠と、文字を隠す範囲の枠（橙の点線）を表示する（⌘B）")
        .accessibilityValue(model.showFaceBoxes ? "表示中" : "非表示")
    }

    private func controls(time: Bool, frame: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                model.step(-1)
            } label: {
                Label("1コマ戻る", systemImage: "backward.frame.fill").labelStyle(.iconOnly)
            }
            .help("1コマ戻る（←。⇧← で 1 秒戻る）")
            Button {
                model.togglePlay()
            } label: {
                Label(model.isPlaying ? "一時停止" : "再生", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 18)
            }
            .help(model.isPlaying ? "一時停止（スペース）" : "再生（スペース。L でもう一度押すと速くなる）")
            Button {
                model.step(1)
            } label: {
                Label("1コマ進む", systemImage: "forward.frame.fill").labelStyle(.iconOnly)
            }
            .help("1コマ進む（→。⇧→ で 1 秒進む）")
            Timeline(model: model, video: video, duration: duration)
                .frame(minWidth: 140)
            if time {
                Text("\(formatTime(model.playheadTime)) / \(formatDuration(duration))")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if frame, let n = model.frameNumber {
                // The frame on screen (its boxes), to tell one frame from the next; the count
                // is in the help. As wide as the largest number from the start, so the timeline
                // does not shift while the number grows. Dimmed while the picture is still
                // catching up with the playhead (the number is that of the frame shown).
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
                    .accessibilityLabel("コマ \(n.index)、全 \(n.count) コマ")
                    .help("いま表示しているコマの番号（全 \(n.count) コマ）")
            }
            if model.playbackRate != 1 {
                // Always in sight: at a faster speed, a few frames left unhidden are easy to miss.
                Text(rateLabel(model.playbackRate))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
                    .fixedSize()
                    .help("再生の速さ（再生 ▸ 速さ で変えられます）")
            }
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
                Capsule().fill(.quaternary).frame(height: 4)
                if let id = video.focusedPerson, let scenes = video.scenes[id] {
                    let on = video.selected.contains(id)
                    ForEach(Array(scenes.enumerated()), id: \.offset) { _, r in
                        Capsule()
                            .fill(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.7)))
                            .frame(width: max(4, x(r.upperBound) - x(r.lowerBound)), height: 8)
                            .offset(x: x(r.lowerBound))
                    }
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1.5)
                    .frame(width: 14, height: 14)
                    .offset(x: x(model.playheadTime) - 7)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                model.seek(to: Double(min(max(g.location.x / max(w, 1), 0), 1)) * duration)
            })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): model.timelineHover = Double(min(max(p.x / max(w, 1), 0), 1)) * duration
                case .ended: model.timelineHover = nil
                }
            }
            .onDisappear { model.timelineHover = nil }
            // Places to check in the exported file (fewer faces hidden than just before and
            // after), above the track: a triangle, not a color only.
            .overlay(alignment: .topLeading) {
                if let dips = video.summary?.dips {
                    ForEach(dips) { d in
                        Button {
                            model.review(d)
                        } label: {
                            // A glyph big enough to see and a target big enough to hit
                            // (24×24 pt), above the track so it does not take the knob's drags.
                            Image(systemName: "arrowtriangle.down.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.orange)
                                .padding(.bottom, 1)
                                .frame(width: 24, height: Self.dipRow, alignment: .bottom)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("確かめてほしい場面（\(formatTime(d.start))）：前後より隠す顔が減っています。押すと書き出した動画のこの場面へ移動します")
                        .accessibilityLabel("確かめてほしい場面 \(formatTime(d.start))")
                        .position(x: x(d.start), y: -Self.dipRow / 2)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if let h = model.timelineHover {
                    Text(formatTime(h))
                        .font(.caption)
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.regularMaterial, in: .capsule)
                        .fixedSize()
                        // Below the track when the dip markers are above it, not over them.
                        .position(x: min(max(x(h), 28), max(w - 28, 28)), y: hasDips ? geo.size.height + 10 : -10)
                        .allowsHitTesting(false)
                }
            }
        }
        // The track in the middle, in line with the buttons and the time; the dip markers are
        // drawn above this frame (over the bar's top padding).
        .frame(height: 20)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { model.playheadTime }, set: { model.seek(to: $0) }), in: 0...duration) {
                Text("再生位置")
            }
        }
    }

    private var hasDips: Bool { video.summary?.dips.isEmpty == false }
    /// Height of the row of dip markers above the track (and of their click targets).
    static let dipRow: CGFloat = 24
}

/// "0.5倍", "2倍".
func rateLabel(_ r: Float) -> String {
    r == r.rounded() ? "\(Int(r))倍" : "\(r)倍"
}
