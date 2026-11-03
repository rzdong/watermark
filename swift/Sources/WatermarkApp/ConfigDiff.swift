import SwiftUI
import WatermarkCore

/// 「恢复默认设置」的确认弹窗：列出每一项的前后变化，确认后才真正执行
struct ResetConfirmView: View {
    @Environment(\.dismiss) private var dismiss
    let changes: [WatermarkConfigChange]
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("恢复默认设置")
                    .font(.headline)
                Text("以下 \(changes.count) 项将被重置")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            // 项数较多时可滚动
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(changes) { change in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(change.title)
                                .frame(width: 76, alignment: .leading)
                                .foregroundColor(.secondary)
                            Text(change.currentValue)
                                .lineLimit(2)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(change.defaultValue)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 13))
                        .padding(.vertical, 7)
                        Divider()
                    }
                }
                .padding(.horizontal)
            }

            Divider()

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认恢复") {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: 440)
    }
}
