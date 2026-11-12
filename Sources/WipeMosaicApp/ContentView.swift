import SwiftUI
import UniformTypeIdentifiers
import WipeMosaicCore

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        root
            .frame(minWidth: 900, minHeight: 560)
            .fileImporter(
                isPresented: $model.importingVideo, allowedContentTypes: [.movie, .audiovisualContent],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { model.add(urls) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.add(urls)
                return !urls.isEmpty
            } isTargeted: { model.dropTargeted = $0 }
            .overlay { dropHighlight }
            .confirmationDialog(
                "一覧から取り除きますか？",
                isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
                presenting: model.pendingRemoval
            ) { id in
                Button("一覧から取り除く", role: .destructive) { model.remove(id) }
                Button("キャンセル", role: .cancel) {}
            } message: { id in
                Text("「\(model.videos.first { $0.id == id }?.name ?? "")」で選んだ人は、まだ書き出していません。元の動画ファイルは削除されません。")
            }
            .sheet(isPresented: $model.showingExportSheet) {
                ExportSheet(model: model)
            }
            .buttonBorderShape(.capsule)
            .onAppear { model.undoManager = undoManager }
            .onChange(of: undoManager) { _, um in model.undoManager = um }
            .alert(
                model.alert?.title ?? "",
                isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
                presenting: model.alert
            ) { _ in
                Button("OK") {}
            } message: { a in
                Text(a.message)
            }
    }

    @ViewBuilder
    private var root: some View {
        if model.videos.isEmpty {
            EmptyStateView(model: model)
                .navigationTitle("モザイぷーん")
        } else {
            NavigationSplitView {
                SidebarView(model: model)
            } detail: {
                detail
                    .navigationTitle(model.current?.name ?? "モザイぷーん")
                    .navigationSubtitle(model.current?.subtitle ?? "")
                    .modifier(DocumentProxy(url: model.current?.url))
                    .toolbar { toolbar }
                    .inspector(isPresented: $model.showInspector) {
                        if let v = model.current {
                            InspectorView(model: model, video: v)
                                .inspectorColumnWidth(min: 320, ideal: 360, max: 480)
                        } else {
                            Color.clear.inspectorColumnWidth(min: 320, ideal: 360, max: 480)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let v = model.current {
            if let info = v.info {
                ViewerView(model: model, video: v, videoSize: info.size)
                    .animation(.smooth(duration: 0.25), value: v.analyzing == nil)
            } else if case .failed(let message) = v.state {
                ContentUnavailableView {
                    Label("この動画を開けません", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("一覧から取り除く") { model.remove(v.id) }
                }
            } else {
                ProgressView(v.state == .converting ? "再生できる形式（MOV）の一時ファイルを作っています。元のファイルは変更しません…" : "読み込んでいます…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView("動画を選んでください", systemImage: "sidebar.left", description: Text("左の一覧から選びます。"))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.hasVideo {
            ToolbarItem(placement: .principal) {
                Picker("表示", selection: $model.viewMode) {
                    Text("モザイクなし").tag(ViewMode.original)
                    Text("モザイクあり").tag(ViewMode.mosaic)
                    if model.current?.summary != nil {
                        Text("書き出し結果").tag(ViewMode.result)
                    }
                }
                .pickerStyle(.segmented)
                .help("モザイクなし（元の動画）／モザイクあり（いま選んでいる人に、書き出しと同じモザイク）／書き出し結果（書き出したファイル）。⌘1〜⌘3")
            }
        }
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.requestExport()
            } label: {
                Label("書き出す…", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .disabled(!model.canExport)
            .help(exportHelp)
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showInspector.toggle()
            } label: {
                Label("人の一覧", systemImage: "sidebar.trailing")
            }
            .help(model.showInspector ? "人の一覧を隠す" : "人の一覧を表示")
        }
    }

    private var exportHelp: String {
        if model.isExporting { return "書き出し中です" }
        let n = model.exportable.count
        if n == 0 { return "モザイクをかける人を選ぶと書き出せます" }
        if n == 1 { return "モザイクをかけた動画を書き出します（⌘E）" }
        return "人を選んだ\(n)本の動画から、書き出すものを選びます（⌘E）"
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if model.dropTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 18))
                    .padding(10)
                VStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.accentColor)
                    Text("ドロップして一覧に追加")
                        .font(.title3.weight(.semibold))
                    Text("何本でもまとめて追加できます")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// Title-bar proxy icon for the shown video.
private struct DocumentProxy: ViewModifier {
    let url: URL?
    func body(content: Content) -> some View {
        if let url { content.navigationDocument(url) } else { content }
    }
}

private struct EmptyStateView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                Text("動画をここにドロップ")
                    .font(.title.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 16) {
                Step(number: 1, title: "動画を追加", detail: "何本でもまとめて追加できます。")
                Step(number: 2, title: "モザイクをかける人を選ぶ", detail: "映っている顔を自動で探して、人ごとに並べます。")
                Step(number: 3, title: "書き出す", detail: "選んだ人だけにモザイクをかけます。画質は元の動画のままです。")
            }
            .frame(maxWidth: 420, alignment: .leading)
            Button("動画を追加…", systemImage: "plus") { model.importingVideo = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            PrivacyNote()
                .padding(.bottom, 28)
        }
    }
}

/// On-device promise, styled like the privacy notes in Apple's own apps:
/// a Settings-style symbol tile, a headline and a quieter second line on a soft panel.
private struct PrivacyNote: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.green.gradient, in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("処理はすべてこのMacの中で行います")
                    .font(.headline)
                Text("動画や顔のデータはどこにも送信しません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .padding(.vertical, 10)
        .background(.quinary, in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct Step: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "\(number).circle.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
