import SwiftUI

extension Purpose {
    var title: String {
        switch self {
        case .text: "画面の文字"
        case .faces: "人の顔"
        case .both: "両方"
        }
    }
    var detail: String {
        switch self {
        case .text: "画面録画や、スマホなどの画面を撮った動画に映る電話番号・名前などを隠します。"
        case .faces: "映っている人を探して、選んだ人の顔を隠します。"
        case .both: "画面の文字と顔の両方を探します。同時に進めるので、片方だけより時間がかかります。"
        }
    }
    var symbol: String {
        switch self {
        case .text: "text.viewfinder"
        case .faces: "face.dashed"
        case .both: "square.stack.3d.up"
        }
    }
}

/// Asked when videos are added: nothing is searched until the user says what to hide, so a
/// screen recording does not wait for a face search first.
struct PurposeSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        let count = model.pendingPurpose.count
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("何を隠しますか？").font(.title2.bold())
                Text(count > 1
                     ? "追加した\(count)本の動画に使います。あとから右の欄の「画面の文字」「人の顔」で、もう一方も探せます。"
                     : "あとから右の欄の「画面の文字」「人の顔」で、もう一方も探せます。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Purpose.allCases, id: \.self) { p in
                option(p)
            }
            // Cancel steps back, so it sits on the leading side (HIG); the choices above go forward.
            HStack {
                Button("キャンセル", role: .cancel) { model.cancelPurpose() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                    .help("動画を追加せずに閉じます（esc）")
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func option(_ p: Purpose) -> some View {
        let isDefault = p == model.lastPurpose
        return Button {
            model.choosePurpose(p)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: p.symbol)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.title).font(.headline)
                    Text(p.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if isDefault {
                    // Return repeats the last choice: said, not shown as already chosen (a
                    // screen recording would otherwise look set to faces).
                    Text("前回と同じ ⏎")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .modifier(DefaultKey(isOn: isDefault))
    }
}

private struct DefaultKey: ViewModifier {
    let isOn: Bool
    func body(content: Content) -> some View {
        if isOn { content.keyboardShortcut(.defaultAction) } else { content }
    }
}
