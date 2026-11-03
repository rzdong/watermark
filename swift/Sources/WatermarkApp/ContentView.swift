import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WatermarkCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var panels = SettingsPanelManager()
    @State private var showingResetConfirm = false
    @State private var pendingChanges: [WatermarkConfigChange] = []
    @State private var isDropTargeted = false

    /// 当前配置与默认配置的差异，已是默认时为空（按钮随之禁用）
    private var resetChanges: [WatermarkConfigChange] {
        WatermarkConfigDiff.changes(from: model.config)
    }

    /// 两栏之间的间隔
    private let gutter: CGFloat = 12

    var body: some View {
        VStack(spacing: 10) {
            toolbar
            // 用 HStack 而非 HSplitView：分栏条那条竖线拿不掉，且间隔不好精确控制
            HStack(spacing: gutter) {
                fileList
                    .frame(width: 260)
                previewPane
                    .frame(minWidth: 460)
            }
        }
        .padding(14)
        // 拖入时给一圈虚线高亮，让用户知道这里可以放
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.clear,
                    style: StrokeStyle(lineWidth: 3, dash: isDropTargeted ? [7, 5] : [])
                )
                .padding(6)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .alert("有文件无法处理", isPresented: $model.showRejectionAlert) {
            Button("好", role: .cancel) { }
        } message: {
            Text(model.rejectionMessage)
        }
        .onChange(of: model.config) { _ in
            model.refreshPreview()
        }
        .onChange(of: model.selectedID) { _ in
            model.previewPageIndex = 0
            model.refreshPreview()
        }
        .sheet(isPresented: $showingResetConfirm) {
            ResetConfirmView(changes: pendingChanges) {
                model.resetConfig()
            }
        }
    }

    // MARK: - 工具条

    private var toolbar: some View {
        HStack(spacing: 8) {
            ForEach(SettingsPanelKind.allCases) { kind in
                Button(kind.title) {
                    panels.toggle(kind, model: model)
                }
            }
            // 恢复默认设置左对齐，紧跟三个面板按钮；先弹窗列出改动项，确认后才执行
            Button("恢复默认设置") {
                pendingChanges = resetChanges
                showingResetConfirm = true
            }
            .disabled(resetChanges.isEmpty)
            .help(resetChanges.isEmpty ? "当前已是默认设置" : "查看将被重置的项目")

            Spacer()

            if model.isProcessing {
                ProgressView()
                    .controlSize(.small)
            }
            Button("处理并另存为…") { model.run() }
                .disabled(model.items.isEmpty || model.isProcessing)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - 文件列表

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 与右侧预览区保持同样的圆角容器
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if model.items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("无待处理文件")
                            .foregroundColor(.secondary)
                    }
                } else {
                    List(selection: $model.selectedID) {
                        ForEach(model.items) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.url.lastPathComponent)
                                    .lineLimit(1)
                                    .help(item.url.path)
                                Text(item.status.label)
                                    .font(.caption)
                                    .foregroundColor(item.status.color)
                                    .lineLimit(3)
                            }
                            .tag(item.id)
                            .padding(.vertical, 2)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                }
            }
            .frame(minHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("添加文件") { chooseFiles() }
                Button("移除") { model.removeSelected() }
                    .disabled(model.selectedID == nil)
                Spacer()
                Button("清空") { model.clear() }
                    .disabled(model.items.isEmpty)
            }
            .padding(.trailing, 4)
            .frame(height: 24)
        }
    }

    // MARK: - 预览（底部只保留翻页）

    private var previewPane: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if let image = model.preview {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("把图片或 PDF 拖到窗口任意位置")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(minHeight: 300)

            // 底部区域固定高度，保证左右两栏底部行始终对齐
            ZStack {
                // 只要是 PDF 就显示页码；单页时左右箭头自动置灰
                if model.isPreviewingPDF {
                    HStack(spacing: 10) {
                        Button {
                            model.gotoPage(model.previewPageIndex - 1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(model.previewPageIndex <= 0)

                        Text("第 \(model.previewPageIndex + 1) / \(model.previewPageCount) 页")
                            .monospacedDigit()

                        Button {
                            model.gotoPage(model.previewPageIndex + 1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(model.previewPageIndex >= model.previewPageCount - 1)
                    }
                } else if !model.isPreviewingPDF {
                    Text("不处理源文件，只生成新文件")
                        .foregroundColor(.secondary)
                }
            }
            .frame(height: 24)
        }
    }

    // MARK: - 辅助

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image]
        guard panel.runModal() == .OK else { return }
        model.add(urls: panel.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.add(urls: [url]) }
            }
        }
        return accepted
    }
}
