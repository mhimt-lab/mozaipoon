import SwiftUI
import WipeMosaicCore

/// The list of videos: add several, each analyzed in turn, export one or all.
struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.currentID) {
            Section {
                ForEach(model.videos) { v in
                    VideoRow(model: model, video: v)
                        .tag(v.id)
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let v = model.videos.first(where: { $0.id == id }) {
                Button("Finderで表示", systemImage: "folder") { model.revealSource(id) }
                Divider()
                Button("一覧から取り除く", systemImage: "minus.circle") { model.requestRemove(id) }
                    .disabled(v.job.isActive)
            }
        }
        .onDeleteCommand { model.requestRemove(model.currentID) }
        // HIG: no actions at the sidebar's bottom edge; adding lives in the sidebar's toolbar,
        // the File menu (⌘O) and drag and drop.
        .toolbar {
            ToolbarItem {
                Button("動画を追加", systemImage: "plus") { model.importingVideo = true }
                    .help("動画を追加します（⌘O）。ウインドウにドロップしても追加できます")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 380)
    }

    /// Progress of a multi-video export (one video's progress is shown in its row and the inspector).
    @ViewBuilder
    private var footer: some View {
        if let p = model.exportProgress, p.total > 1 {
            HStack(spacing: 10) {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))) {
                    Text("書き出しています（\(min(p.done + 1, p.total))／\(p.total)本）")
                        .font(.callout)
                }
                Button("中止", role: .cancel) { model.cancelExports() }
                    .controlSize(.small)
                    .help("書き出しをすべて中止します")
            }
            .padding(12)
        }
    }
}

private struct VideoRow: View {
    @Bindable var model: AppModel
    let video: VideoItem

    var body: some View {
        HStack(spacing: 10) {
            poster
            VStack(alignment: .leading, spacing: 3) {
                Text(video.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
                    .font(.callout)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var poster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if let img = video.poster {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .frame(width: 72, height: 44)
        .clipShape(.rect(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var status: some View {
        switch video.job {
        case .writing(let p):
            progress("書き出し中", p)
        case .queued:
            StatusLabel("書き出し待ち", systemImage: "clock")
        case .failed:
            StatusLabel("書き出しに失敗しました", systemImage: "exclamationmark.triangle.fill", tint: .red, emphasized: true)
        default:
            analysisStatus
        }
    }

    @ViewBuilder
    private var analysisStatus: some View {
        switch video.state {
        case .loading:
            StatusLabel("読み込み中…", systemImage: "film")
        case .converting:
            StatusLabel("再生できる形式に変換中…", systemImage: "arrow.triangle.2.circlepath")
        case .idle:
            textStatus
        case .waiting:
            StatusLabel("順番待ち", systemImage: "clock")
        case .running(let p):
            progress("顔を探しています", p)
        case .cancelled:
            StatusLabel("顔を探していません", systemImage: "pause.circle")
        case .failed:
            StatusLabel("開けません", systemImage: "exclamationmark.triangle.fill", tint: .red, emphasized: true)
        case .done:
            if video.purpose?.readsText == true, video.textState == .waiting || video.textScanning != nil
                || video.textState == .cancelled || { if case .failed? = video.textState { true } else { false } }() {
                textStatus  // "both": the text is still being read, or was not
            } else if let a = video.analysis {
                if video.hasChoices {
                    choiceStatus
                } else if a.people.isEmpty {
                    StatusLabel("顔が見つかりません", systemImage: "person.crop.circle.badge.questionmark")
                } else {
                    StatusLabel("\(a.people.count)人中 0人を隠す", systemImage: "circle.dashed")
                }
            }
        }
    }

    /// A video not searched for faces (only text was chosen, or nothing chosen yet).
    @ViewBuilder
    private var textStatus: some View {
        switch video.textState {
        case nil:
            if video.purpose == nil {
                StatusLabel("隠すものを選んでください", systemImage: "questionmark.circle")
            } else {
                StatusLabel("顔を探していません", systemImage: "pause.circle")
            }
        case .waiting:
            StatusLabel("順番待ち", systemImage: "clock")
        case .running(let p):
            progress("文字を読み取っています", p)
        case .cancelled:
            StatusLabel("文字を読み取っていません", systemImage: "pause.circle")
        case .failed:
            StatusLabel("文字を読み取れませんでした", systemImage: "exclamationmark.triangle.fill", tint: .red, emphasized: true)
        case .done, .loading, .converting, .idle:
            if video.hasChoices {
                choiceStatus
            } else {
                StatusLabel("自動で見つかった個人情報はありません", systemImage: "circle.dashed")
            }
        }
    }

    @ViewBuilder
    private var choiceStatus: some View {
        if video.job == .done, !video.resultIsStale(model.mosaicParams) {
            StatusLabel("書き出し済み", systemImage: "checkmark.circle.fill", tint: .green)
        } else {
            StatusLabel(video.choiceSummary, systemImage: "eye.slash")
        }
    }

    private func progress(_ title: String, _ p: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title) \(Int(p * 100))%").foregroundStyle(.secondary).monospacedDigit()
            ProgressView(value: p).controlSize(.small)
        }
    }
}

/// A row status line that stays readable on the selected (accent-filled) row:
/// text is always primary/secondary, only the symbol carries color, and the symbol
/// falls back to the (white-on-accent) secondary style when the row is selected.
struct StatusLabel: View {
    let text: String
    let systemImage: String
    var tint: Color? = nil
    var emphasized = false
    @Environment(\.backgroundProminence) private var prominence

    init(_ text: String, systemImage: String, tint: Color? = nil, emphasized: Bool = false) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.emphasized = emphasized
    }

    var body: some View {
        let selected = prominence == .increased
        Label {
            Text(text)
                .foregroundStyle(emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .fontWeight(emphasized ? .medium : .regular)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(selected || tint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint!))
        }
    }
}
