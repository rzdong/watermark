import SwiftUI
import AppKit
import WatermarkCore

enum SettingsPanelKind: String, CaseIterable, Identifiable {
    case content
    case layout
    case pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .content: return "水印内容"
        case .layout:  return "水印布局"
        case .pdf:     return "PDF 选项"
        }
    }
}

/// 设置项放进独立的悬浮面板，不再占用主窗口
@MainActor
final class SettingsPanelManager: ObservableObject {
    private var panels: [SettingsPanelKind: NSPanel] = [:]

    func toggle(_ kind: SettingsPanelKind, model: AppModel) {
        if let existing = panels[kind], existing.isVisible {
            existing.close()
            panels[kind] = nil
            return
        }
        panels[kind] = nil

        let root = SettingsPanelView(kind: kind).environmentObject(model)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 500)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.title = kind.title
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panels[kind] = panel
    }

    func closeAll() {
        for (_, panel) in panels { panel.close() }
        panels.removeAll()
    }
}

struct SettingsPanelView: View {
    @EnvironmentObject private var model: AppModel
    let kind: SettingsPanelKind

    private let fontChoices: [(String, String)] = [
        ("苹方", "PingFangSC-Regular"),
        ("苹方 粗", "PingFangSC-Semibold"),
        ("宋体", "SongtiSC-Regular"),
        ("华文宋体", "STSong"),
        ("黑体", "STHeitiSC-Light"),
        ("Helvetica", "Helvetica"),
        ("Helvetica 粗", "Helvetica-Bold"),
        ("Times", "Times-Roman")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 内容较多时可滚动；ScrollView 占满除底部说明外的全部高度，
            // 这样内容不满时不会出现大片空白和多余的滚动条
            ScrollView {
                Form {
                    switch kind {
                    case .content: contentSection
                    case .layout:  layoutSection
                    case .pdf:     pdfSection
                    }
                }
                .formStyle(.grouped)
            }
            .frame(maxHeight: .infinity)

            Divider()

            Text("设置会自动保存，下次启动沿用")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 340)
    }

    // MARK: - 水印内容

    private var contentSection: some View {
        Group {
            Picker("", selection: $model.config.kind) {
                Text("文字").tag(WatermarkKind.text)
                Text("图片").tag(WatermarkKind.image)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.config.kind == .text {
                TextField("水印文字", text: $model.config.text.content)
                Picker("字体", selection: $model.config.text.fontName) {
                    ForEach(fontChoices, id: \.1) { name, postScript in
                        Text(name).tag(postScript)
                    }
                }
                sliderRow("字号", value: $model.config.text.fontSize,
                          range: 8...160, step: 1, format: "%.0f")
                ColorPicker("颜色", selection: colorBinding(
                    get: { model.config.text.color },
                    set: { model.config.text.color = $0 }
                ))
                Toggle("加粗", isOn: $model.config.text.bold)
                sliderRow("描边", value: $model.config.text.strokeWidth,
                          range: 0...6, step: 0.5, format: "%.1f")
                if model.config.text.strokeWidth > 0 {
                    ColorPicker("描边颜色", selection: colorBinding(
                        get: { model.config.text.strokeColor },
                        set: { model.config.text.strokeColor = $0 }
                    ))
                }
                sliderRow("字距", value: $model.config.text.letterSpacing,
                          range: -0.2...1, step: 0.02, format: "%.2f")
                sliderRow("行距", value: $model.config.text.lineSpacing,
                          range: 0.8...3, step: 0.05, format: "%.2f")
            } else {
                HStack(alignment: .top, spacing: 12) {
                    if let image = model.watermarkImagePreview {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 72, height: 72)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .frame(width: 72, height: 72)
                            .overlay(
                                Image(systemName: "photo")
                                    .foregroundColor(.secondary)
                            )
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Button("选择图片…") { model.chooseWatermarkImage() }
                        if !model.config.image.imageData.isEmpty {
                            Button("清除") { model.clearWatermarkImage() }
                        } else {
                            Text("尚未选择")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                sliderRow("宽度占比", value: $model.config.image.scalePercent,
                          range: 2...100, step: 1, format: "%.0f%%")
            }
        }
    }

    // MARK: - 布局

    private var layoutSection: some View {
        Group {
            Picker("位置", selection: $model.config.layout.anchor) {
                Text("左上").tag(WatermarkAnchor.topLeft)
                Text("上中").tag(WatermarkAnchor.topCenter)
                Text("右上").tag(WatermarkAnchor.topRight)
                Text("左中").tag(WatermarkAnchor.middleLeft)
                Text("正中").tag(WatermarkAnchor.center)
                Text("右中").tag(WatermarkAnchor.middleRight)
                Text("左下").tag(WatermarkAnchor.bottomLeft)
                Text("下中").tag(WatermarkAnchor.bottomCenter)
                Text("右下").tag(WatermarkAnchor.bottomRight)
                Text("自定义").tag(WatermarkAnchor.custom)
            }
            if model.config.layout.anchor == .custom {
                sliderRow("横向位置", value: Binding(
                    get: { model.config.layout.customPosition.x },
                    set: { model.config.layout.customPosition.x = $0 }
                ), range: 0...1, step: 0.01, format: "%.2f")
                sliderRow("纵向位置", value: Binding(
                    get: { model.config.layout.customPosition.y },
                    set: { model.config.layout.customPosition.y = $0 }
                ), range: 0...1, step: 0.01, format: "%.2f")
            }
            sliderRow("旋转", value: $model.config.layout.rotationDegrees,
                      range: -180...180, step: 1, format: "%.0f°")
            sliderRow("大小占比", value: $model.config.layout.scalePercent,
                      range: 2...100, step: 1, format: "%.0f%%")
            sliderRow("不透明度", value: $model.config.layout.opacity,
                      range: 0.02...1, step: 0.02, format: "%.2f")
            sliderRow("边距", value: $model.config.layout.marginPercent,
                      range: 0...25, step: 1, format: "%.0f%%")
            Toggle("平铺", isOn: $model.config.layout.tiling)
            if model.config.layout.tiling {
                // 下限为 1.0：小于 1 意味着步长小于水印自身外接框，必然重叠
                sliderRow("间距", value: $model.config.layout.tileSpacing,
                          range: 1...4, step: 0.1, format: "%.1f")
                Toggle("错行排列", isOn: $model.config.layout.staggerRows)
            }
        }
    }

    // MARK: - PDF

    private var pdfSection: some View {
        Group {
            Picker("层级", selection: $model.config.pdf.placement) {
                Text("内容之上").tag(WatermarkPlacement.above)
                Text("内容之下").tag(WatermarkPlacement.below)
            }
            Picker("页面范围", selection: pageRangeBinding) {
                Text("全部").tag(PageRangeOption.all)
                Text("仅首页").tag(PageRangeOption.first)
                Text("奇数页").tag(PageRangeOption.odd)
                Text("偶数页").tag(PageRangeOption.even)
                Text("指定页").tag(PageRangeOption.custom)
            }
            if case .custom = model.config.pdf.pageRange {
                TextField("页码", text: pageSpecBinding)
                Text("支持逗号与连字符：1,3,5-9；2- 表示到第末页；留空按全部处理")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text("PDF 走增量更新：原文件字节不动，元数据、书签、注释全部保留")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 辅助

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String
    ) -> some View {
        HStack {
            Slider(value: value, in: range, step: step) { Text(title) }
            Text(String(format: format, value.wrappedValue))
                .frame(width: 56, alignment: .trailing)
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
    }

    private func colorBinding(
        get: @escaping () -> RGBAColor,
        set: @escaping (RGBAColor) -> Void
    ) -> Binding<Color> {
        Binding(
            get: {
                let c = get()
                return Color(nsColor: NSColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha))
            },
            set: { newValue in
                let ns = NSColor(newValue)
                var converted = ns.usingColorSpace(.deviceRGB) ?? ns
                if converted.alphaComponent < 1, converted == NSColor.clear {
                    converted = NSColor(red: 0, green: 0, blue: 0, alpha: 1)
                }
                set(RGBAColor(
                    red: Double(converted.redComponent),
                    green: Double(converted.greenComponent),
                    blue: Double(converted.blueComponent),
                    alpha: Double(converted.alphaComponent)
                ))
            }
        )
    }

    private enum PageRangeOption: String, CaseIterable {
        case all, first, odd, even, custom
    }

    private var pageRangeBinding: Binding<PageRangeOption> {
        Binding(
            get: {
                switch model.config.pdf.pageRange {
                case .all: return .all
                case .first: return .first
                case .odd: return .odd
                case .even: return .even
                case .custom: return .custom
                }
            },
            set: { option in
                switch option {
                case .all: model.config.pdf.pageRange = .all
                case .first: model.config.pdf.pageRange = .first
                case .odd: model.config.pdf.pageRange = .odd
                case .even: model.config.pdf.pageRange = .even
                case .custom:
                    if case .custom = model.config.pdf.pageRange { return }
                    model.config.pdf.pageRange = .custom(indices: [])
                }
            }
        )
    }

    private var pageSpecBinding: Binding<String> {
        Binding(
            get: {
                if case .custom(let indices) = model.config.pdf.pageRange {
                    return indices.map(String.init).joined(separator: ",")
                }
                return ""
            },
            set: { text in
                model.config.pdf.pageRange = .custom(indices: PDFPageRange.parse(text))
            }
        )
    }
}
