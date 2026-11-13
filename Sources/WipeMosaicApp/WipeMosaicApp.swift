import AppKit
import SwiftUI

@main
struct WipeMosaicApp: App {
    // @State needs the SwiftUI macro plugin, which Command Line Tools lack; the App is created once.
    private let model: AppModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Needed when the binary is launched outside an .app bundle (e.g. during development).
        NSApplication.shared.setActivationPolicy(.regular)
        model = AppModel()
        AppDelegate.model = model
    }

    var body: some Scene {
        Window("モザイぷーん", id: "main") {
            ContentView(model: model)
                .onAppear {
                    NSApp.activate()
                    // `WipeMosaic <video>...` from a terminal adds those files.
                    let paths = CommandLine.arguments.dropFirst().filter {
                        !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0)
                    }
                    model.add(paths.map { URL(fileURLWithPath: $0) })
                }
        }
        .defaultSize(width: 1280, height: 780)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView(model: model)
                .buttonBorderShape(.capsule)
        }
    }
}

private struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("動画を追加…") { model.importingVideo = true }
                .keyboardShortcut("o")
            Menu("最近使った項目を開く") {
                ForEach(model.recentURLs, id: \.self) { url in
                    Button(url.lastPathComponent) { model.add([url]) }
                }
                if !model.recentURLs.isEmpty { Divider() }
                Button("メニューを消去") { model.clearRecent() }
                    .disabled(model.recentURLs.isEmpty)
            }
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("書き出す…") { model.requestExport() }
                .keyboardShortcut("e")
                .disabled(!model.canExport)
            if model.current?.summary != nil {
                Button("書き出したファイルをFinderで表示") { model.revealOutput() }
            }
            Divider()
            Button("一覧から取り除く") { model.requestRemove(model.currentID) }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(model.current == nil || model.current?.job.isActive == true)
        }
        CommandGroup(before: .toolbar) {
            Button("モザイクなし") { model.viewMode = .original }
                .keyboardShortcut("1")
                .disabled(!model.hasVideo)
            Button("モザイクあり") { model.viewMode = .mosaic }
                .keyboardShortcut("2")
                .disabled(!model.hasVideo)
            Button("書き出し結果") { model.viewMode = .result }
                .keyboardShortcut("3")
                .disabled(model.current?.summary == nil)
            Divider()
            Button(model.showFaceBoxes ? "顔の枠を隠す" : "顔の枠を表示") { model.showFaceBoxes.toggle() }
                .keyboardShortcut("b")
            Divider()
        }
        InspectorCommands()
        CommandMenu("人物") {
            Button("全員にモザイクをかける") { model.selectAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.current?.analysis == nil)
            Button("全員のモザイクを外す") { model.clearAll() }
                .disabled(model.current?.selected.isEmpty != false)
            Divider()
            Button("顔を探し直す") { model.reanalyze() }
                .disabled(!model.hasVideo || model.current?.analyzing != nil || model.current?.job.isActive == true)
        }
    }
}

/// Finder "Open With" / dropping on the Dock icon: AppKit hands over every file at once
/// (SwiftUI's onOpenURL receives only one when several are opened together).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?

    /// Quitting loses the people chosen (and stops a running export), so ask first —
    /// the same rule as removing a video from the list.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        let pending = model.videos.filter { $0.hasUnexportedWork(model.mosaicParams) }
        guard model.isExporting || !pending.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        if model.isExporting {
            alert.messageText = "書き出しの途中です。終了しますか？"
            alert.informativeText = "終了すると書き出しを中止し、途中のファイルは削除します。"
        } else {
            alert.messageText = "書き出していない動画があります。終了しますか？"
            alert.informativeText = "「\(pending[0].name)」\(pending.count > 1 ? "など\(pending.count)本" : "")で選んだ内容は、終了すると消えます。元の動画ファイルは削除されません。"
        }
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "終了").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        guard model.isExporting else { return .terminateNow }
        // Let the export stop and delete its partial file, then quit.
        model.cancelExports()
        Task { @MainActor in
            while model.isExporting { try? await Task.sleep(for: .milliseconds(50)) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Rewrapped MXF copies can be gigabytes; do not leave them in the temporary folder.
    func applicationWillTerminate(_ notification: Notification) {
        Remux.removeAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Self.model?.add(urls)
        showMainWindow()
    }

    /// The Window scene is not created when the app is launched to open files;
    /// show it through its Window-menu item.
    private func showMainWindow() {
        DispatchQueue.main.async {
            if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
                w.makeKeyAndOrderFront(nil)
            } else if let item = NSApp.windowsMenu?.items.first(where: { $0.title == "モザイぷーん" }),
                      let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
            NSApp.activate()
        }
    }
}
