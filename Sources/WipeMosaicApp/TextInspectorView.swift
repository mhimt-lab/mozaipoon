import SwiftUI
import WipeMosaicCore

extension TextKind {
    var label: String {
        switch self {
        case .number: "電話番号・カード番号などの数字"
        case .email: "メールアドレス"
        case .url: "URL"
        case .address: "住所・郵便番号"
        }
    }
    var note: String {
        switch self {
        case .number: "6桁以上の数字（ハイフンや空白を含む。A-123456 のような英字付きも）"
        case .email: "〜@〜.〜 の形の文字"
        case .url: "https:// や www. で始まる文字、.com・.jp などで終わる文字"
        case .address: "〒や「〜県〜市」「〜区〜1-2-3」の形の文字。見つかった所から行の終わりまでと、すぐ下に続く行も隠します"
        }
    }
    var shortLabel: String {
        switch self {
        case .number: "数字"
        case .email: "メール"
        case .url: "URL"
        case .address: "住所"
        }
    }
}

/// Inspector tab for screen recordings: personal information in on-screen text.
struct TextInspectorView: View {
    @Bindable var model: AppModel
    @Bindable var video: VideoItem

    var body: some View {
        List {
            if video.job != .idle || video.summary != nil {
                ExportSection(model: model, video: video)
            }
            if let text = video.text, video.textState == .done {
                kindsSection(text)
                wordsSection
                linesSection(text)
            }
        }
        .overlay { stateOverlay }
        .onAppear(perform: startIfNeeded)
        .onChange(of: video.id) { _, _ in startIfNeeded() }
    }

    /// Opening the tab is the request: read the text right away.
    private func startIfNeeded() {
        if video.textState == nil, video.isReady { model.scanText(video) }
    }

    // MARK: Kinds

    private func kindsSection(_ text: ScreenText) -> some View {
        Section {
            Toggle(isOn: Binding(get: { video.textAll }, set: { model.setTextAll($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("読み取れた文字をすべて隠す")
                    Text("スマホやパソコンの画面をカメラで撮った動画向け。動画に入れた字幕や、服・看板の文字も隠れます。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .listRowSeparator(.hidden)
            Text(video.textAll
                 ? "読み取れた文字は、すべてモザイクで隠します。"
                 : "見つかった個人情報に、自動でモザイクをかけます。その部分だけを隠し、行のほかの文字は残します。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .listRowSeparator(.hidden)
            ForEach(TextKind.allCases) { kind in
                let count = text.entries.filter { $0.kinds.contains(kind) }.count
                Toggle(isOn: Binding(
                    get: { model.textKinds.contains(kind) },
                    set: { on in if on { model.textKinds.insert(kind) } else { model.textKinds.remove(kind) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.label)
                        Text(count > 0 ? "\(kind.note)・この動画で\(count)行" : kind.note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(video.textAll)
                .listRowSeparator(.hidden)
            }
        } header: {
            SectionTitle("自動で隠すもの")
        }
    }

    // MARK: Words

    private var wordsSection: some View {
        Section {
            Text("名前やアカウント名など、隠したい言葉を入れます。画面のどこに出ても、その言葉の部分にモザイクをかけます。名字を入れると、すぐ後に続く名前も隠します。すべての動画に使われます。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .listRowSeparator(.hidden)
            HStack {
                TextField("例：山田", text: $model.textWordDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addWord)
                Button("追加", action: addWord)
                    .disabled(model.textWordDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .listRowSeparator(.hidden)
            ForEach(model.textWords, id: \.self) { w in
                HStack {
                    Text(w)
                    Spacer()
                    Button {
                        model.removeTextWord(w)
                    } label: {
                        Label("「\(w)」を削除", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("この言葉を隠すのをやめます")
                }
                .listRowSeparator(.hidden)
            }
        } header: {
            SectionTitle("隠す言葉")
        }
    }

    private func addWord() {
        model.addTextWord(model.textWordDraft)
        model.textWordDraft = ""
    }

    // MARK: Lines

    private func linesSection(_ text: ScreenText) -> some View {
        let minFrames = max(2, Int((text.fps * 0.2).rounded()))
        let hidden = video.textMask?.hidden ?? []
        let isMain: (TextEntry) -> Bool = {
            $0.frameCount >= minFrames || !$0.kinds.isEmpty || hidden.contains($0.id) || video.textLines.contains($0.id)
        }
        let main = text.entries.filter(isMain)
        let flashes = text.entries.filter { !isMain($0) }
        return Section {
            Text("チェックを入れた行は、行全体にモザイクをかけます。文字を押すと、その行が映る場面を表示します。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .listRowSeparator(.hidden)
            if text.entries.isEmpty {
                Text("文字が見つかりませんでした。")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(main) { e in
                TextLineRow(model: model, video: video, text: text, entry: e)
            }
            if !flashes.isEmpty {
                DisclosureGroup("一瞬だけ読み取れた文字（\(flashes.count)件）", isExpanded: $model.showTextFlashes) {
                    ForEach(flashes) { e in
                        TextLineRow(model: model, video: video, text: text, entry: e)
                    }
                }
                .font(.callout)
                .listRowSeparator(.hidden)
            }
            Label {
                Text("読み取れなかった文字（小さい文字、画像や動画の中の文字、一瞬だけ映った文字）は隠せません。書き出した動画を必ず確かめてください。")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.callout)
            .listRowSeparator(.hidden)
        } header: {
            SectionTitle("見つかった文字（\(text.entries.count)行）")
        }
    }

    // MARK: States

    @ViewBuilder
    private var stateOverlay: some View {
        switch video.textState {
        case nil:
            if !video.isReady {
                ContentUnavailableView("読み込んでいます", systemImage: "film")
            }
        case .waiting:
            ContentUnavailableView {
                Label("順番を待っています", systemImage: "clock")
            } description: {
                Text("前の動画の文字を読み終わると、この動画を読みます。")
            } actions: {
                Button("中止") { model.cancelTextScan() }
            }
        case .running(let p):
            ContentUnavailableView {
                Label("画面の文字を読み取っています", systemImage: "text.viewfinder")
            } description: {
                VStack(spacing: 8) {
                    Text("電話番号や名前などを探しています。読み取りはこのMacの中だけで行います。")
                    ProgressView(value: p).frame(maxWidth: 220)
                    Text("\(Int(p * 100))%").monospacedDigit()
                }
            } actions: {
                Button("中止") { model.cancelTextScan() }
            }
        case .cancelled:
            ContentUnavailableView {
                Label("画面の文字を読み取っていません", systemImage: "text.viewfinder")
            } description: {
                Text("読み取りを中止しました。")
            } actions: {
                Button("読み取る") { model.scanText(video) }
                    .buttonStyle(.borderedProminent)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("画面の文字を読み取れませんでした", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("もう一度読み取る") { model.scanText(video) }
                    .buttonStyle(.borderedProminent)
            }
        case .loading, .converting, .done:
            EmptyView()
        }
    }
}

private struct TextLineRow: View {
    @Bindable var model: AppModel
    let video: VideoItem
    let text: ScreenText
    let entry: TextEntry

    var body: some View {
        let whole = video.textAll || video.textLines.contains(entry.id)
        let partly = !whole && (video.textMask?.hidden.contains(entry.id) ?? false)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(entry.text, isOn: Binding(get: { whole }, set: { model.setTextLine(entry.id, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(video.textAll)
                .help(whole ? "押すと、行全体のモザイクを外します" : "押すと、行全体にモザイクをかけます")
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(caption(whole: whole, partly: partly))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
            .onTapGesture { model.seek(to: text.times[entry.firstFrame]) }
            .help("押すと、この行が映る場面を表示します")
            Spacer(minLength: 0)
            if whole || partly {
                Image(systemName: "eye.slash")
                    .foregroundStyle(Color.accentColor)
                    .help(whole ? "行全体にモザイク" : "一部にモザイク")
            }
        }
        .padding(.vertical, 2)
    }

    private func caption(whole: Bool, partly: Bool) -> String {
        let at = formatTime(text.times[entry.firstFrame])
        if whole { return "\(at)から・行全体にモザイク" }
        if partly {
            var why = entry.kinds.filter { model.textKinds.contains($0) }.sorted { $0.rawValue < $1.rawValue }.map(\.shortLabel)
            if video.textMask?.wordHits.contains(entry.id) == true { why.append("言葉") }
            return "\(at)から・一部にモザイク（\(why.joined(separator: "・"))）"
        }
        return "\(at)から"
    }
}
