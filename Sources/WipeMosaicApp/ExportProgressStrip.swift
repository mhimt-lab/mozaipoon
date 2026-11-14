import SwiftUI

/// While exporting: the one progress bar and Cancel, in a strip under the toolbar above the
/// video. The video rows and the inspector show only "書き出し中 n%" (no second bar).
struct ExportProgressStrip: View {
    @Bindable var model: AppModel

    var body: some View {
        if let p = model.exportProgress, p.total >= 1 {
            // The video being written counts by its own progress, so one video's bar moves.
            let current = model.videos.lazy.compactMap { v -> Double? in
                if case .writing(let f) = v.job { return f } else { return nil }
            }.first ?? 0
            let fraction = min((Double(p.done) + current) / Double(max(p.total, 1)), 1)
            HStack(spacing: 12) {
                Label {
                    Text(p.total > 1
                         ? "書き出し中 \(Int(fraction * 100))%（\(min(p.done + 1, p.total))／\(p.total)本目）"
                         : "書き出し中 \(Int(fraction * 100))%")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
                .font(.callout)
                .fixedSize()
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(minWidth: 80, maxWidth: 320)
                Spacer(minLength: 0)
                Button(p.total > 1 ? "すべて中止" : "中止") { model.cancelExports() }
                    .controlSize(.small)
                    .help(p.total > 1 ? "書き出しをすべて中止します。途中までのファイルは削除します" : "書き出しを中止します。途中までのファイルは削除します")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
