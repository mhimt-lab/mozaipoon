import SwiftUI
import WipeMosaicCore

/// Shown by the one "書き出す…" button: which videos to write and where.
struct ExportSheet: View {
    @Bindable var model: AppModel

    /// Videos with something chosen to hide (faces, text or both), searched or still searching.
    private var candidates: [VideoItem] { model.videos.filter { $0.isReady && $0.purpose != nil } }
    private var chosen: [VideoItem] { model.videos.filter { model.exportChoice.contains($0.id) && $0.canExport } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(candidates.count == 1 ? "書き出す" : "書き出す動画を選んでください")
                .font(.title2.weight(.semibold))
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 12)

            if candidates.count > 1 {
                Toggle(sources: choiceBindings, isOn: \.self) {
                    Text("すべて（\(chosen.count)／\(candidates.filter(\.canExport).count)本）")
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 37)
                .padding(.bottom, 8)
            }

            // A plain scroll view (not a List): a focused List swallows Esc, so the
            // sheet could not be cancelled from the keyboard.
            Group {
                // Rows size themselves (a warning adds a line); scroll only for long lists.
                if candidates.count <= 4 {
                    rows
                } else {
                    ScrollView { rows }.frame(height: 340)
                }
            }
            .background(.background, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .padding(.horizontal, 24)
            if model.videos.count > candidates.count {
                Text("開けない動画や、何を隠すか選んでいない動画（\(model.videos.count - candidates.count)本）は表示していません。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }

            destination
                .padding(.horizontal, 24)
                .padding(.top, 16)

            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { model.showingExportSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "書き出す" : "\(chosen.count)本を書き出す") { model.confirmExport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty)
            }
            .controlSize(.large)
            .padding(24)
        }
        .frame(width: 520)
        .buttonBorderShape(.capsule)
        // Esc must cancel even while the list has keyboard focus (the list would eat it).
        .onExitCommand { model.showingExportSheet = false }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { i, v in
                if i > 0 { Divider().padding(.leading, 104) }
                ExportRow(model: model, video: v)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 6)
    }

    private var choiceBindings: [Binding<Bool>] {
        candidates.filter(\.canExport).map { v in
            Binding(get: { model.exportChoice.contains(v.id) },
                    set: { if $0 { model.exportChoice.insert(v.id) } else { model.exportChoice.remove(v.id) } })
        }
    }

    /// Like the save panel's "Where" pop-up.
    private var destination: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("保存先") {
                Menu {
                    // Checkmarks show the current choice, like the save panel's "Where" pop-up.
                    Toggle("元の動画と同じフォルダ", isOn: Binding(
                        get: { model.exportFolder == nil }, set: { if $0 { model.exportFolder = nil } }))
                    if let f = model.exportFolder {
                        Toggle(f.lastPathComponent, isOn: .constant(true))
                    }
                    Divider()
                    Button("ほかのフォルダを選ぶ…") { model.chooseExportFolder() }
                } label: {
                    Label(model.exportFolder?.lastPathComponent ?? "元の動画と同じフォルダ", systemImage: "folder")
                }
                .fixedSize()
                .help(model.exportFolder?.path ?? "それぞれの元の動画と同じフォルダに保存します")
            }
            Text("元の動画は変わりません。名前の後ろに「_mosaic」を付けて保存します（同じ名前があるときは上書きせず、番号を付けます）。画質・形式・音声は元の動画のままです。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label {
                Text("自動で見つからなかった顔や文字は隠れません。公開する前に、書き出した動画を最後まで確かめてください。")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.callout)
        }
    }
}

private struct ExportRow: View {
    @Bindable var model: AppModel
    let video: VideoItem

    var body: some View {
        let on = Binding(
            get: { model.exportChoice.contains(video.id) && video.canExport },
            set: { if $0 { model.exportChoice.insert(video.id) } else { model.exportChoice.remove(video.id) } })
        // The whole row is the checkbox's label, so one click toggles exactly once.
        Toggle(isOn: on) {
            HStack(spacing: 12) {
                Group {
                    if let img = video.poster {
                        Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "film").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, height: 40)
                .background(.quaternary)
                .clipShape(.rect(cornerRadius: 6))
                .opacity(video.canExport ? 1 : 0.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(video.canExport ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if video.canExport, let skipped = video.skippedSearch {
                        warning(skipped)
                    }
                    if video.canExport, let a = video.analysis, !a.people.isEmpty, video.selected.isEmpty {
                        warning("顔が\(a.people.count)人見つかりましたが、誰も選んでいません（顔は隠れません）")
                    }
                    if video.canExport, video.text != nil, !video.textAll, !model.textKinds.isSuperset(of: TextKind.allCases) {
                        let off = TextKind.allCases.filter { !model.textKinds.contains($0) }.map { "「\($0.label)」" }
                        warning("\(off.joined(separator: ""))は、自動で隠さない設定です")
                    }
                    if video.canExport, let note = notSearched {
                        Text(note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if video.canExport, !video.uncheckedHints.isEmpty {
                        HStack(spacing: 8) {
                            Label {
                                Text("選んでいない似た人が\(video.uncheckedHints.count)人います")
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                            Button("確かめる") { model.review(video.id) }
                                .buttonStyle(.link)
                                .help("シートを閉じて、この動画の人の一覧を表示します")
                        }
                        .font(.callout)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .disabled(!video.canExport)
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.callout)
    }

    /// The kind of search not asked for when the video was added (not a warning: the user
    /// chose it, but a video may show both faces and a screen).
    private var notSearched: String? {
        switch video.purpose {
        case .faces? where video.textState == nil: "画面の文字は読み取っていません"
        case .text? where video.state == .idle: "人の顔は探していません"
        default: nil
        }
    }

    private var detail: String {
        if let searching = video.searchingLabel { return searching + "…終わると書き出せます" }
        if video.textMaskPending { return "文字のモザイクを作っています…" }
        if !video.hasChoices {
            var why: [String] = []
            if let a = video.analysis { why.append(a.people.isEmpty ? "顔が見つかりませんでした" : "人を選んでいません") }
            if video.text != nil { why.append("隠す文字がありません") }
            if let skipped = video.skippedSearch { why.append(skipped) }
            return why.joined(separator: "・")
        }
        let base = video.choiceSummary
        if video.job == .done, !video.resultIsStale(model.mosaicParams) { return base + "・書き出し済み" }
        return base
    }
}
