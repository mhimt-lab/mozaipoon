import SwiftUI
import WipeMosaicCore

/// Right column: what was written, what to mosaic (people's faces, or text on screen in
/// screen recordings), and how the mosaic looks. Each explanation sits right above the
/// control it explains.
struct InspectorView: View {
    @Bindable var model: AppModel
    @Bindable var video: VideoItem

    var body: some View {
        Group {
            switch model.inspectorTab {
            case .people: peopleList
            case .text: TextInspectorView(model: model, video: video)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("隠すもの", selection: $model.inspectorTab) {
                Text("人の顔").tag(InspectorTab.people)
                Text("画面の文字").tag(InspectorTab.text)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("人の顔：映っている人を選んで隠します／画面の文字：画面録画に映る電話番号や名前などを隠します")
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var peopleList: some View {
        List(selection: $video.focusedPerson) {
            if video.job != .idle || video.summary != nil {
                ExportSection(model: model, video: video)
            }
            if model.needsReanalysis(video) {
                Section {
                    Notice(
                        title: "顔を探す精度を変えました",
                        message: "いまの一覧は前の精度で探した結果です。探し直すと、チェックはやり直しになります。",
                        systemImage: "arrow.triangle.2.circlepath", tint: .accentColor
                    ) {
                        Button("探し直す") { model.reanalyze() }
                    }
                }
            }
            peopleSection
            if video.analysis.map({ !$0.people.isEmpty }) == true {
                MosaicSection(model: model)
            }
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first, let p = video.person(id) {
                if video.selected.contains(id) {
                    Button("モザイクを外す", systemImage: "eye") { model.setSelected(id, false) }
                } else {
                    Button("モザイクをかける", systemImage: "eye.slash") { model.setSelected(id, true) }
                }
                Divider()
                Button("この人が最初に映る場面へ", systemImage: "backward.end") { model.jump(to: p) }
                Button("この人が映る次の場面へ", systemImage: "forward.end") { model.nextScene(p.id) }
            }
        }
        // Clicking a person shows them in the video (goes to their first scene if needed).
        .onChange(of: video.focusedPerson) { _, id in
            if let id { model.reveal(id) }
        }
        // Space toggles the selected person's mosaic (keyboard-only workflow).
        .onKeyPress(.space) {
            guard let id = video.focusedPerson else { return .ignored }
            model.toggle(id)
            return .handled
        }
        .overlay { emptyOverlay }
    }

    // MARK: People

    @ViewBuilder
    private var peopleSection: some View {
        if let analysis = video.analysis, !analysis.people.isEmpty {
            Section {
                // Always visible: what checking means and where else it can be done.
                Text("顔を押すと、その人にモザイクをかけます。もう一度押すと外れます。動画の中の顔を押しても同じです。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()

                // Same shape as the export sheet's "すべて" row.
                Toggle(sources: personBindings, isOn: \.self) {
                    Text("全員（\(video.selected.count)／\(analysis.people.count)人）")
                }
                .toggleStyle(.checkbox)
                .help("全員にモザイクをかける／全員外す")
                .listRowSeparator(.hidden)
                .selectionDisabled()

                if !video.uncheckedHints.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Label {
                            Text("選んでいない似た人が\(video.uncheckedHints.count)人います。理由は各行に出ています。")
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.orange)
                        }
                        Spacer(minLength: 4)
                        Button("まとめて選ぶ") { model.checkHinted() }
                            .controlSize(.small)
                            .help("似ている人を全員選びます（⌘Zで元に戻せます）")
                    }
                    .font(.callout)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                }

                ForEach(video.orderedPeople) { p in
                    PersonRow(model: model, video: video, person: p)
                        .tag(p.id)
                }

                if analysis.people.contains(where: { !$0.similar.isEmpty }) || analysis.people.count > 1 {
                    // A plain row (a section footer truncates to one line here).
                    Label {
                        Text("同じ人が別の人として並ぶことがあります。一覧の顔をすべて確かめてください。")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                }
            } header: {
                SectionTitle("モザイクをかける人")
            }
        }
    }

    private var personBindings: [Binding<Bool>] {
        video.orderedPeople.map { p in
            Binding(get: { video.selected.contains(p.id) }, set: { model.setSelected(p.id, $0) })
        }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if video.state == .waiting {
            ContentUnavailableView {
                Label("順番を待っています", systemImage: "clock")
            } description: {
                Text("前の動画の顔を探し終わると、この動画を探します。")
            }
        } else if video.state == .converting || video.state == .loading {
            ContentUnavailableView {
                Label("読み込んでいます", systemImage: "film")
            } description: {
                Text(video.state == .converting ? "この形式はそのままでは再生できないため、再生できる形式（MOV）の一時ファイルを作っています。元のファイルは変更しません。" : "")
            }
        } else if case .failed(let message) = video.state, video.analysis == nil {
            ContentUnavailableView {
                Label(video.isReady ? "顔を探せませんでした" : "この動画は開けません", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if video.isReady {
                    Button("もう一度探す") { model.reanalyze() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if video.analyzing != nil, video.job == .idle, video.summary == nil {
            ContentUnavailableView {
                Label("顔を探しています", systemImage: "faceid")
            } description: {
                Text("見つかった人が、ここに顔の写真つきで並びます。")
            }
        } else if let analysis = video.analysis, analysis.people.isEmpty, video.job == .idle {
            ContentUnavailableView {
                Label("顔が見つかりませんでした", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("小さい顔や、横顔しか映らない人は見つからないことがあります。設定の「顔を探す精度」を「高精度」にして探し直すと、見つかる場合があります。画面録画なら、「画面の文字」で電話番号や名前などを隠せます。")
            } actions: {
                Button("画面の文字を隠す") { model.inspectorTab = .text }
                    .buttonStyle(.borderedProminent)
                SettingsLink { Text("設定を開く…") }
            }
        } else if video.analysis == nil, video.analyzing == nil, video.isReady, video.job == .idle {
            ContentUnavailableView {
                Label("顔を探していません", systemImage: "person.crop.circle.badge.xmark")
            } description: {
                Text("探すのを中止しました。")
            } actions: {
                Button("顔を探す") { model.reanalyze() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Person row

private struct PersonRow: View {
    @Bindable var model: AppModel
    let video: VideoItem
    let person: Person

    var body: some View {
        let on = video.selected.contains(person.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // The checkbox and the faces are one control (like the faces in the video):
                // pressing either toggles the mosaic.
                Toggle(isOn: Binding(get: { on }, set: { model.setSelected(person.id, $0) })) {
                    FaceStack(images: video.thumbnails[person.id] ?? [], mosaic: on)
                        .contentShape(Rectangle())
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("人物 \(person.id)")
                .accessibilityValue(on ? "モザイクあり" : "モザイクなし")
                .help(on ? "押すとモザイクを外します" : "押すとモザイクをかけます")

                // The rest of the row selects the person and shows them in the video.
                VStack(alignment: .leading, spacing: 2) {
                    Text("人物 \(person.id)")
                        .font(.headline)
                    Text(on ? "モザイクあり・\(duration)" : "\(duration)映っています")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .help("押すと、この人が映る場面を表示します")
                Spacer(minLength: 0)
                Button {
                    model.nextScene(person.id)
                } label: {
                    Label("次の場面へ", systemImage: "forward.end.circle")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("この人が映る次の場面へ移動します")
            }
            badges
                .padding(.leading, 26)
        }
        .padding(.vertical, 4)
    }

    private var duration: String {
        let t = video.seconds(of: person)
        return t < 60 ? "\(max(1, Int(t.rounded())))秒" : formatSeconds(t)
    }

    @ViewBuilder
    private var badges: some View {
        let checked = video.selected.contains(person.id)
        let similar = person.similar
        let registered = !checked && video.registeredHints[person.id] != nil
        let other = checked ? nil : video.crossHints[person.id]
        if !similar.isEmpty || registered || other != nil {
            VStack(alignment: .leading, spacing: 3) {
                if !similar.isEmpty {
                    let names = similar.map { "人物 \($0)" }.joined(separator: "、")
                    Badge(
                        text: checked ? "\(names)と同じ人かもしれません" : "\(names)と同じ人かもしれません。選ぶと\(names)も選ばれます",
                        systemImage: "person.2.fill")
                }
                if registered {
                    Badge(text: "登録した顔に似ています", systemImage: "person.crop.circle.badge.checkmark")
                }
                if let other {
                    Badge(text: "「\(other)」で選んだ人に似ています", systemImage: "film.stack")
                }
            }
        }
    }
}

/// A short, tinted note inside the list (an explanation or a hint), optionally with one action.
struct Notice<Action: View>: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            action()
                .buttonStyle(.bordered)
                .padding(.leading, 26)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 10))
    }
}

/// "Please look at this person" note on a row. Always orange, the one caution color.
private struct Badge: View {
    let text: String
    let systemImage: String
    var tint: Color = .orange

    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.callout)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 8))
    }
}

/// Up to three face crops of one person, overlapping.
private struct FaceStack: View {
    let images: [CGImage]
    let mosaic: Bool

    var body: some View {
        HStack(spacing: -18) {
            if images.isEmpty {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.tertiary)
                    .frame(width: 48, height: 48)
            }
            ForEach(Array(images.prefix(3).enumerated()), id: \.offset) { i, img in
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(.circle)
                    .overlay(Circle().strokeBorder(mosaic ? Color.accentColor : Color.clear, lineWidth: 2.5))
                    .overlay(Circle().strokeBorder(.background, lineWidth: mosaic ? 0 : 2))
                    .zIndex(Double(3 - i))
            }
        }
        .frame(width: 80, alignment: .leading)
        .accessibilityHidden(true)
    }
}

// MARK: - Export

struct ExportSection: View {
    @Bindable var model: AppModel
    let video: VideoItem

    var body: some View {
        Section {
            switch video.job {
            case .writing(let p):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: p) {
                        Text("書き出しています")
                    } currentValueLabel: {
                        Text("\(Int(p * 100))%").monospacedDigit()
                    }
                    Button((model.exportProgress?.total ?? 1) > 1 ? "すべて中止" : "中止", role: .cancel) { model.cancelExports() }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            case .queued:
                Label("前の動画を書き出し終わると、この動画を書き出します", systemImage: "clock")
                    .foregroundStyle(.secondary)
            case .cancelled:
                Label("書き出しを中止しました。途中までのファイルは削除しました。", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
            case .failed:
                Notice(
                    title: "書き出せませんでした",
                    message: failureReason,
                    systemImage: "exclamationmark.triangle.fill", tint: .red
                ) {
                    Button("もう一度書き出す…", systemImage: "arrow.clockwise") { model.requestExport() }
                        .disabled(!model.canExport)
                }
            case .done, .idle:
                if let s = video.summary { result(s) }
            }
        } header: {
            SectionTitle("書き出し")
        }
    }

    private var failureReason: String {
        if case .failed(let reason) = video.job { reason } else { "" }
    }

    @ViewBuilder
    private func result(_ s: JobSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("書き出しました").font(.headline)
                    Text(s.output.lastPathComponent)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("\(s.output.path)\n\(s.format.description)・\(s.mosaicFrames)/\(s.frames)フレームにモザイク・\(formatSeconds(s.elapsed))")
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if video.resultIsStale(model.mosaicParams) {
                Label {
                    Text("書き出した後に変更があります。反映するには、もう一度書き出してください。")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("再生して確かめる", systemImage: "play.fill") {
                    model.viewMode = .result
                    model.seek(to: 0)
                    model.togglePlay()
                }
                Button("Finderで表示", systemImage: "folder") { model.revealOutput() }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
        .selectionDisabled()

        if s.dips.isEmpty {
            Label("途中でモザイクが減る場面は見つかりませんでした", systemImage: "checkmark.seal")
                .font(.callout)
                .foregroundStyle(.secondary)
                .selectionDisabled()
        } else {
            DisclosureGroup {
                ForEach(s.dips) { d in
                    Button {
                        model.review(d)
                    } label: {
                        HStack {
                            Text("\(formatTime(d.start)) – \(formatTime(d.end))").monospacedDigit()
                            Spacer()
                            Text("モザイク \(d.around) → \(d.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("書き出した動画のこの場面を表示")
                }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("確かめてほしい場面（\(s.dips.count)か所）")
                        Text("前後より、モザイクの数が減っています。顔が見えていないか確認してください。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .selectionDisabled()
        }
        Text("公開する前に、書き出した動画を最後まで見て確かめてください。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .selectionDisabled()
    }
}

// MARK: - Mosaic

private struct MosaicSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $model.mosaicExpanded) {
                VStack(alignment: .leading, spacing: 16) {
                    SliderRow(title: "顔の前後も続ける時間", value: $model.hold, range: 0...3, step: 0.25,
                              low: "0秒", high: "3秒", text: String(format: "%.2g秒", model.hold),
                              note: "顔が映る前と見えなくなった後も、この時間だけモザイクを続けます。横を向いた瞬間に外れるのを防ぎます。")
                    SliderRow(title: "モザイクの広さ", value: $model.pad, range: 0.2...1.0, step: 0.05,
                              low: "狭い", high: "広い", text: "\(Int((model.pad * 100).rounded()))%",
                              note: "広げると、髪や耳まで隠れます。")
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("モザイクの粗さ")
                            Spacer()
                            Toggle("おまかせ", isOn: $model.autoBlock)
                                .toggleStyle(.checkbox)
                        }
                        Slider(value: blockBinding, in: 8...96, step: 2) {
                            Text("モザイクの粗さ")
                        } minimumValueLabel: {
                            Text("細かい").font(.callout).foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Text("粗い").font(.callout).foregroundStyle(.secondary)
                        }
                        .labelsHidden()
                        .disabled(model.autoBlock)
                        Text(model.autoBlock ? "おまかせでは、動画の大きさに合わせて決めます。" : "粗くするほど、顔の形が分からなくなります。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("変えると「モザイクあり」の表示にすぐ反映されます。すべての動画に共通です。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                .padding(.leading, 4)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("モザイクの調整").font(.headline)
                    if !model.mosaicExpanded {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .selectionDisabled()
        }
    }

    /// While automatic, the slider shows the size actually used.
    private var blockBinding: Binding<Double> {
        Binding(get: { model.autoBlock ? Double(model.autoBlockSize) : model.block },
                set: { model.block = $0 })
    }

    private var summary: String {
        "続ける \(String(format: "%.2g秒", model.hold))・広さ \(Int((model.pad * 100).rounded()))%・粗さ \(model.autoBlock ? "おまかせ" : "手動")"
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let low: String
    let high: String
    let text: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(text).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step) {
                Text(title)
            } minimumValueLabel: {
                Text(low).font(.callout).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(high).font(.callout).foregroundStyle(.secondary)
            }
            .labelsHidden()
            .accessibilityValue(text)
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Section titles at a readable size (the default list header is small, gray caption text).
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.primary)
            .textCase(nil)
    }
}
