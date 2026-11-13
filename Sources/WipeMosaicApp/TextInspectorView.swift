import SwiftUI
import WipeMosaicCore

extension TextKind {
    var label: String {
        switch self {
        case .number: "電話番号・カード番号などの数字"
        case .email: "メールアドレス"
        case .url: "URL"
        case .address: "住所・郵便番号"
        case .name: "人の名前"
        }
    }
    /// One line under the label; the details are in the help tag.
    var note: String {
        switch self {
        case .number: "6桁以上。ハイフン・空白や英字付き（A-123456）も"
        case .email: "〜@〜.〜 の形"
        case .url: "https://・www. で始まるもの、.com・.jp などで終わるもの"
        case .address: "〒や「〜県〜市」「〜区1-2-3」。行の終わりと、すぐ下の行も"
        case .name: "よくある名字と、続く名前や「さん」など。ほかの名前は「隠す言葉」へ"
        }
    }
    var detail: String {
        switch self {
        case .number: "電話番号・カード番号・会員番号など、6桁以上の数字（ハイフンや空白を含む。A-123456 のような英字付きも）を隠します。"
        case .email: "〜@〜.〜 の形の文字を隠します。2行に折り返したものも、つなげて探します。"
        case .url: "https:// や www. で始まる文字と、.com・.jp などで終わる文字を隠します。"
        case .address: "〒や「〜県〜市」「〜区〜1-2-3」の形の文字を、見つかった所から行の終わりまでと、すぐ下に続く行（建物名・部屋番号）も隠します。"
        case .name: "よくある名字に、名前や「さん」などが続く文字（「山田 花子」「田中さん」）を隠します。珍しい名字・ニックネーム・名前だけの呼びかけは見つからないので、「隠す言葉」に入れてください。"
        }
    }
    var shortLabel: String {
        switch self {
        case .number: "数字"
        case .email: "メール"
        case .url: "URL"
        case .address: "住所"
        case .name: "名前"
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
                if video.textMaskPending {
                    Label {
                        Text("モザイクを作り直しています…")
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                }
                kindsSection(text)
                wordsSection(text)
                thisVideoSection
                Section {
                    CoverStyleRows(model: model)
                        .padding(.vertical, 4)
                        .listRowSeparator(.hidden)
                } header: {
                    SectionTitle("隠し方（すべての動画に共通）")
                }
                linesSection(text)
            }
        }
        .overlay { stateOverlay }
        .onAppear(perform: startIfNeeded)
        .onChange(of: video.id) { _, _ in startIfNeeded() }
        .onChange(of: video.isReady) { _, _ in startIfNeeded() }
        .onChange(of: video.purpose) { _, _ in startIfNeeded() }
    }

    /// Read the text right away when it was asked for when the video was added; a video
    /// added for faces is read only with the button (opening the tab is not a request).
    private func startIfNeeded() {
        if video.textState == nil, video.isReady, video.purpose?.readsText == true { model.scanText(video) }
    }

    // MARK: Kinds

    private func kindsSection(_ text: ScreenText) -> some View {
        Section {
            Text(video.textAll
                 ? "この動画は、読み取れた文字をすべて隠しています（下の「この動画だけ」）。"
                 : "見つかった部分だけにモザイクをかけ、行のほかの文字は残します。外した種類は、ほかの動画でも隠しません。")
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
                        HStack(alignment: .firstTextBaseline) {
                            Text(kind.label)
                            Spacer(minLength: 4)
                            Text("\(count)行")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("この動画で\(count)行")
                        }
                        Text(kind.note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(video.textAll)
                .help(kind.detail)
                .listRowSeparator(.hidden)
            }
        } header: {
            SectionTitle("自動で隠すもの（すべての動画に共通）")
        }
    }

    // MARK: This video

    private var thisVideoSection: some View {
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
        } header: {
            SectionTitle("この動画だけ")
        }
    }

    // MARK: Words

    private func wordsSection(_ text: ScreenText) -> some View {
        // Counted where the mosaic is made (in the background); nothing while it is remade.
        let others = model.videos.filter { $0.id != video.id && $0.textMask != nil }
        return Section {
            Text("名前やアカウント名など。画面のどこに出ても、その言葉の部分を隠します。名字を入れると、続く名前も隠します。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .listRowSeparator(.hidden)
            ForEach(model.textWords, id: \.self) { w in
                VStack(alignment: .leading, spacing: 3) {
                    WordField(model: model, word: w, commit: { new, _ in model.replaceTextWord(w, with: new) },
                              delete: { model.removeTextWord(w) })
                    if let n = video.textMask?.wordLines[w] {
                        WordHits(count: n, elsewhere: others.compactMap { $0.textMask?.wordLines[w] }.reduce(0, +),
                                 othersRead: !others.isEmpty)
                    }
                }
                .listRowSeparator(.hidden)
            }
            if model.addingTextWord || model.textWords.isEmpty {
                // Return adds the word and leaves a new empty field, to type the next one.
                WordField(model: model, word: "", focused: model.addingTextWord,
                          canDelete: !model.textWords.isEmpty, commit: { w, submitted in
                    if AppModel.isBlank(w) {
                        model.addingTextWord = false
                    } else {
                        model.addTextWord(w)
                        // After Return, keep an empty field for the next word (not when the
                        // field was left: the focus belongs where the user clicked).
                        model.addingTextWord = submitted
                    }
                }, delete: { model.addingTextWord = false })
                .listRowSeparator(.hidden)
            }
            Button {
                model.addingTextWord = true
            } label: {
                Label("言葉を追加", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(model.addingTextWord)
            .help("隠す言葉の欄を増やします")
            .listRowSeparator(.hidden)
        } header: {
            SectionTitle("隠す言葉（すべての動画に共通）")
        }
    }

    // MARK: Lines

    private func linesSection(_ text: ScreenText) -> some View {
        let minFrames = max(2, Int((text.fps * 0.2).rounded()))
        let hidden = video.textMask?.hidden ?? []
        let isMain: (TextEntry) -> Bool = {
            $0.frameCount >= minFrames || !$0.kinds.isEmpty || hidden.contains($0.id) || video.textLines.contains($0.id)
        }
        // Lines not hidden as a whole: also the partly hidden ones, whose rest may be a name the
        // rules missed (090-0000-1111 犬飼 hides only the number).
        let isWhole: (TextEntry) -> Bool = { video.textAll || video.textLines.contains($0.id) }
        let shown: (TextEntry) -> Bool = { !model.textUnhiddenOnly || !isWhole($0) }
        let main = text.entries.filter { isMain($0) && shown($0) }
        let flashes = text.entries.filter { !isMain($0) && shown($0) }
        return Section {
            Label {
                Text("読み取れなかった文字（小さい文字、画像や動画の中の文字、一瞬だけ映った文字）は隠せません。書き出した動画を必ず最後まで確かめてください。")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.callout)
            .listRowSeparator(.hidden)
            Text("チェックを入れた行は、行全体を隠します。文字を押すと、その行が映る場面を表示します。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .listRowSeparator(.hidden)
            if !text.entries.isEmpty {
                Toggle("行全体は隠していない行だけを表示（\(text.entries.filter { !isWhole($0) }.count)行）", isOn: $model.textUnhiddenOnly)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("何も隠していない行と、一部だけ隠した行を並べます。一部だけの行は、残った文字に名前などがないか確かめてください")
                .listRowSeparator(.hidden)
            }
            if text.entries.isEmpty {
                Text("文字が見つかりませんでした。")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            } else if main.isEmpty, flashes.isEmpty {
                Text("行全体を隠していない行はありません。")
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
            } else if video.purpose == nil {
                ContentUnavailableView("隠すものを選んでください", systemImage: "questionmark.circle")
            } else {
                ContentUnavailableView {
                    Label("画面の文字は読み取っていません", systemImage: "text.viewfinder")
                } description: {
                    Text("この動画の画面に映る電話番号や名前なども隠すときは、読み取ってください。")
                } actions: {
                    Button("この動画の画面の文字を読み取る") { model.scanText(video) }
                        .buttonStyle(.borderedProminent)
                }
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
        case .loading, .converting, .idle, .done:
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
            Button {
                model.seek(to: text.times[entry.firstFrame])
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(caption(whole: whole, partly: partly))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("押すと、この行が映る場面を表示します")
            .accessibilityHint("この行が映る場面を表示します")
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
        if whole { return "行全体を隠しています・\(at)〜" }
        if partly {
            var why = entry.kinds.filter { model.textKinds.contains($0) }.sorted { $0.rawValue < $1.rawValue }.map(\.shortLabel)
            if video.textMask?.wordHits.contains(entry.id) == true { why.append("言葉") }
            if why.isEmpty { why.append("読み違えた行の続き") }
            return "一部を隠しています（\(why.joined(separator: "・"))）・\(at)〜"
        }
        return "隠していません・\(at)〜"
    }
}

/// How many lines of this video a word was found in. Found in no video is a warning (a
/// misreading, or 高 typed for 髙), since the user would otherwise believe the word is hidden;
/// found only in other videos is not (words are shared by every video).
private struct WordHits: View {
    let count: Int
    let elsewhere: Int
    let othersRead: Bool
    var body: some View {
        if count > 0 || elsewhere > 0 {
            Text(count > 0 ? "この動画で\(count)行" : "この動画にはありません（ほかの動画で\(elsewhere)行）")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        } else {
            Label {
                Text("\(othersRead ? "どの動画でも" : "この動画では")見つかりませんでした。字の違い（高／髙など）や読み違いがないか、下の一覧で確かめてください。")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.callout)
            .padding(.leading, 4)
        }
    }
}

/// One word to hide, edited in place: the change applies on Return or when the field is left
/// (not on every key, which would remake every video's mosaic). The text being typed is kept
/// in the model (`wordDrafts`): @State needs the SwiftUI macro plugin (see WipeMosaicApp).
private struct WordField: View {
    @Bindable var model: AppModel
    let word: String
    var focused = false
    /// The only (empty) field of an empty list cannot be closed.
    var canDelete = true
    /// The text, and whether Return was pressed (not the field left).
    let commit: (String, Bool) -> Void
    let delete: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            TextField("例：山田", text: Binding(
                get: { model.wordDrafts[word] ?? word }, set: { model.wordDrafts[word] = $0 }))
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { apply(submitted: true) }
                .onChange(of: isFocused) { _, now in if !now { apply(submitted: false) } }
                .accessibilityLabel(word.isEmpty ? "新しく隠す言葉" : "隠す言葉「\(word)」")
            if canDelete {
            Button {
                model.wordDrafts[word] = nil
                delete()
            } label: {
                Label(word.isEmpty ? "この欄を閉じる" : "「\(word)」を削除", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(word.isEmpty ? "この欄を閉じます" : "この言葉を隠すのをやめます")
            }
        }
        .onAppear { if focused { isFocused = true } }
        // Switching tabs or videos removes the field without a focus change: apply it then too.
        .onDisappear { apply(submitted: false) }
        .onChange(of: focused) { _, f in if f { isFocused = true } }
    }

    private func apply(submitted: Bool) {
        let text = model.wordDrafts.removeValue(forKey: word) ?? word
        guard text != word || word.isEmpty else { return }  // the new field left empty closes
        // Emptying a word removes it only on Return; leaving the field keeps the word, so one
        // being retyped is not dropped by scrolling or switching tabs.
        if !submitted, !word.isEmpty, AppModel.isBlank(text) { return }
        commit(text, submitted)
        // After Return, the new-word field stays, empty, for the next word. Not when the field
        // was left by clicking another one: that one keeps the focus.
        if submitted, word.isEmpty, !text.trimmingCharacters(in: .whitespaces).isEmpty { isFocused = true }
    }
}
