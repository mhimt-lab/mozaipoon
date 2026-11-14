import AVKit
import SwiftUI
import WipeMosaicCore

/// AVKit's player with the system floating (Liquid Glass) controls, frame stepping and scrubbing.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        // The app draws its own always-visible bar under the video (TransportBar):
        // AVKit's controls hide unless the pointer is over the video.
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.showsFrameSteppingButtons = true
        v.showsFullScreenToggleButton = false  // full screen would hide the face boxes
        v.allowsPictureInPicturePlayback = false
        v.allowsVideoFrameAnalysis = false  // no Live Text / subject lifting on private footage
        v.showsSharingServiceButton = false
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

/// The video with clickable face boxes on top (while paused).
struct ViewerView: View {
    @Bindable var model: AppModel
    @Bindable var video: VideoItem
    let videoSize: CGSize

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(player: model.player)
                .background(.black)
                .overlay { textBoxes }
                .overlay { faceBoxes }
                .overlay { analysisCard }
                .overlay(alignment: .top) { hint }
                .overlay(alignment: .topTrailing) { boxToggle }
            TransportBar(model: model, video: video)
        }
    }

    // MARK: Face boxes

    private var faceBoxes: some View {
        GeometryReader { geo in
            let s = min(geo.size.width / videoSize.width, geo.size.height / videoSize.height)
            let ox = (geo.size.width - videoSize.width * s) / 2
            let oy = (geo.size.height - videoSize.height * s) / 2
            GlassEffectContainer {
                ForEach(Array(model.visibleFaces.enumerated()), id: \.offset) { _, face in
                    let r = face.rect  // Core Image coordinates (bottom-left origin)
                    let box = CGRect(
                        x: ox + r.minX * s, y: oy + (videoSize.height - r.maxY) * s,
                        width: r.width * s, height: r.height * s)
                    FaceBox(
                        person: face.person,
                        mosaic: video.selected.contains(face.person),
                        focused: video.focusedPerson == face.person
                    ) {
                        video.focusedPerson = face.person
                        model.toggle(face.person)
                    }
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: video.selected)
    }

    // MARK: Text boxes

    /// Dashed outlines where text is hidden (not written to the file).
    private var textBoxes: some View {
        GeometryReader { geo in
            let s = min(geo.size.width / videoSize.width, geo.size.height / videoSize.height)
            let ox = (geo.size.width - videoSize.width * s) / 2
            let oy = (geo.size.height - videoSize.height * s) / 2
            ForEach(Array(model.visibleTextBoxes.enumerated()), id: \.offset) { _, r in
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: r.width * s, height: r.height * s)
                    .position(x: ox + r.midX * s, y: oy + (videoSize.height - r.midY) * s)
            }
        }
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
            .transition(.scale(scale: 0.96).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("顔を探しています。\(Int(p * 100))パーセント")
        }
    }

    // MARK: Face box toggle

    @ViewBuilder
    private var boxToggle: some View {
        if video.analysis != nil || video.textMask != nil, model.viewMode != .result {
            // One switch for the face boxes and the text outlines (both when both are found).
            Button {
                model.showFaceBoxes.toggle()
            } label: {
                Label(model.showFaceBoxes ? "枠を隠す" : "枠を表示",
                      systemImage: model.showFaceBoxes ? "person.crop.square" : "person.crop.square.badge.xmark")
                    .font(.callout)
            }
            .buttonStyle(.glass)
            .padding(12)
            .help("一時停止中に出る顔の枠と、文字を隠す範囲の枠（橙の点線）を、表示する／隠す（⌘B）。書き出す動画には入りません")
        }
    }

    // MARK: Hint

    @ViewBuilder
    private var hint: some View {
        if let text = hintText {
            Label(text.0, systemImage: text.1)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 12)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private var hintText: (String, String)? {
        guard video.analyzing == nil, video.analysis != nil || video.text != nil else { return nil }
        switch model.viewMode {
        case .result: return ("書き出し結果（書き出したファイル）を表示しています", "film")
        case .original: return ("モザイクなし（元の動画）を表示しています", "eye")
        case .mosaic: return nil
        }
    }
}

private struct FaceBox: View {
    let person: Int
    let mosaic: Bool
    let focused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    mosaic ? Color.accentColor : Color.white.opacity(0.85),
                    style: StrokeStyle(lineWidth: focused ? 3.5 : 2, dash: mosaic ? [] : [6, 4]))
                .shadow(color: .black.opacity(0.5), radius: 2)
                .contentShape(Rectangle())
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
                .alignmentGuide(.top) { $0[.bottom] + 4 }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                Text("\(formatTime(model.playheadTime)) / \(formatDuration(duration))")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if model.playbackRate != 1 {
                    // Always in sight: at a faster speed, a few frames left unhidden are easy to miss.
                    Text(rateLabel(model.playbackRate))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                        .help("再生の速さ（再生 ▸ 速さ で変えられます）")
                }
            }
            .buttonStyle(.borderless)
            .font(.title3)
            if let id = video.focusedPerson, video.scenes[id] != nil {
                Text(video.selected.contains(id)
                     ? "青い太線は「人物 \(id)」が映っている場面です（隠す人）。"
                     : "太線は「人物 \(id)」が映っている場面です（まだ隠していない人）。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let dips = video.summary?.dips, !dips.isEmpty {
                Text("▼は書き出した動画で確かめてほしい場面です（押すとその場面へ）。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
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
                Capsule().fill(.quaternary).frame(height: 4).offset(y: trackY)
                if let id = video.focusedPerson, let scenes = video.scenes[id] {
                    let on = video.selected.contains(id)
                    ForEach(Array(scenes.enumerated()), id: \.offset) { _, r in
                        Capsule()
                            .fill(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.7)))
                            .frame(width: max(4, x(r.upperBound) - x(r.lowerBound)), height: 8)
                            .offset(x: x(r.lowerBound), y: trackY)
                    }
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1.5)
                    .frame(width: 14, height: 14)
                    .offset(x: x(model.playheadTime) - 7, y: trackY)
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
                            Image(systemName: "arrowtriangle.down.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .frame(width: 16, height: 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("確かめてほしい場面（\(formatTime(d.start))）：前後より隠す顔が減っています。押すと書き出した動画のこの場面へ移動します")
                        .accessibilityLabel("確かめてほしい場面 \(formatTime(d.start))")
                        .position(x: x(d.start), y: 5)
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
                        .position(x: min(max(x(h), 28), max(w - 28, 28)), y: -10)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 26)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { model.playheadTime }, set: { model.seek(to: $0) }), in: 0...duration) {
                Text("再生位置")
            }
        }
    }

    /// The track sits below the row of dip markers.
    private var trackY: CGFloat { 4 }
}

/// "0.5倍", "2倍".
func rateLabel(_ r: Float) -> String {
    r == r.rounded() ? "\(Int(r))倍" : "\(r)倍"
}
