import SwiftUI
import UniformTypeIdentifiers
import WipeMosaicCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Tab("顔を探す", systemImage: "faceid") { DetectionSettings(model: model) }
            Tab("登録した顔", systemImage: "person.crop.square") { RegisteredSettings(model: model) }
            Tab("スタンプ", systemImage: "face.smiling") { StickerSettings(model: model) }
        }
        .frame(width: 520)
        .scenePadding(.minimum)
    }
}

private struct DetectionSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("顔を探す精度", selection: $model.accuracy) {
                    ForEach(Accuracy.allCases) { a in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.label)
                            Text(a.note).font(.callout).foregroundStyle(.secondary)
                        }
                        .tag(a)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } header: {
                // A header like the other tabs', not a label inside the box.
                Text("顔を探す精度")
            } footer: {
                Text("精度を上げるほど時間がかかります。変更は次に動画を開いたとき、または「探し直す」で反映されます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RegisteredSettings: View {
    @Bindable var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 88), spacing: 14)]

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(model.registered) { face in
                        RegisteredTile(model: model, face: face)
                    }
                    Button {
                        model.importingPhotos = true
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: model.registering ? "hourglass" : "plus")
                                .font(.title2)
                                .frame(width: 64, height: 64)
                                .background(.quaternary, in: .circle)
                            Text("追加…").font(.callout)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.registering)
                    .accessibilityLabel("顔写真を追加")
                }
                .padding(.vertical, 6)
                .dropDestination(for: URL.self) { urls, _ in
                    model.addPhotos(urls)
                    return !urls.isEmpty
                }
                ForEach(model.registerMessages, id: \.self) { m in
                    Label(m, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("どの動画でも隠す人の顔写真")
            } footer: {
                Text("動画を追加すると、ここの写真に似ている人に最初からチェックが入ります。判定は確実ではないので、一覧で必ず確かめてください。写真はドロップしても追加できます。写真はこのMacの中だけに保存され、どこにも送信されません。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(isPresented: $model.importingPhotos, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addPhotos(urls) }
        }
    }
}

private struct RegisteredTile: View {
    @Bindable var model: AppModel
    let face: RegisteredFace

    var body: some View {
        let hovered = model.hoveredFace == face.id
        VStack(spacing: 6) {
            Image(decorative: face.thumbnail, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 64)
                .clipShape(.circle)
                .overlay(alignment: .topTrailing) {
                    if hovered {
                        Button {
                            model.removeRegistered(face)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .secondary)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                        .help("登録を削除")
                        .transition(.opacity)
                    }
                }
        }
        .onHover { model.hoveredFace = $0 ? face.id : (model.hoveredFace == face.id ? nil : model.hoveredFace) }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .contextMenu {
            Button("登録を削除", systemImage: "trash", role: .destructive) { model.removeRegistered(face) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("登録した顔の写真")
        .accessibilityAction(named: "登録を削除") { model.removeRegistered(face) }
    }
}

private struct StickerSettings: View {
    @Bindable var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 88), spacing: 14)]

    var body: some View {
        Form {
            Section {
                if model.stickerLibrary.isEmpty {
                    Text("まだありません。メイン画面の人の一覧で、隠す人の「隠し方」メニューから画像を選ぶと、ここに並びます。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(Array(model.stickerLibrary.enumerated()), id: \.element.id) { i, item in
                            let hovered = model.hoveredSticker == item.id
                            // Delete on hover, as for the registered faces (not a blue link).
                            VStack(spacing: 6) {
                                Image(decorative: item.sticker.cgImage, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 64, height: 64)
                                    .overlay(alignment: .topTrailing) {
                                        if hovered {
                                            Button {
                                                model.stickerToRemove = item
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, .secondary)
                                                    .font(.title3)
                                            }
                                            .buttonStyle(.plain)
                                            .offset(x: 4, y: -4)
                                            .help("スタンプを削除")
                                            .transition(.opacity)
                                        }
                                    }
                                Text("スタンプ \(i + 1)").font(.callout)
                            }
                            .onHover { model.hoveredSticker = $0 ? item.id : (model.hoveredSticker == item.id ? nil : model.hoveredSticker) }
                            .animation(.easeOut(duration: 0.12), value: hovered)
                            .contextMenu {
                                Button("削除", systemImage: "trash", role: .destructive) { model.stickerToRemove = item }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("スタンプ \(i + 1)")
                            .accessibilityAction(named: "削除") { model.stickerToRemove = item }
                        }
                    }
                    .padding(.vertical, 6)
                }
            } header: {
                Text("顔に重ねる画像")
            } footer: {
                Text(model.stickerLibrary.isEmpty
                     ? "画像はこのMacの中だけに保存され、どこにも送信されません。"
                     : "追加は、メイン画面の人の一覧で、隠す人の「隠し方」メニューから画像を選びます。削除は、ポインタを重ねると出る × か、右クリックから。削除すると、使っていた人は基本の隠し方（モザイクかぼかし）に戻ります。削除は取り消せません。メイン画面の人の一覧の「隠し方」メニューの「保存したスタンプを削除」からも削除できます。画像はこのMacの中だけに保存され、どこにも送信されません。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .stickerRemovalDialog(model: model, item: $model.stickerToRemove)
    }
}

extension View {
    /// Asks before deleting a sticker (it cannot be undone, and every video using it loses it).
    func stickerRemovalDialog(model: AppModel, item: Binding<StickerItem?>) -> some View {
        let number = item.wrappedValue.flatMap { s in model.stickerLibrary.firstIndex { $0.id == s.id } }.map { $0 + 1 }
        return confirmationDialog(
            number.map { "スタンプ \($0) を削除しますか？" } ?? "このスタンプを削除しますか？",
            isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
            presenting: item.wrappedValue
        ) { s in
            Button("削除", role: .destructive) { model.removeSticker(s) }
            Button("キャンセル", role: .cancel) {}
        } message: { s in
            let users = model.videos.filter { $0.stickers.values.contains(s.id) }.count
            Text(users > 0
                 ? "\(users)本の動画で使っています。使っていた人は、基本の隠し方（モザイクかぼかし）に戻ります。削除は取り消せず、それまでの操作も取り消せなくなります。"
                 : "削除は取り消せず、それまでの操作も取り消せなくなります。")
        }
    }
}
