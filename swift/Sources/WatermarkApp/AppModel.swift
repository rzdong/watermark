import SwiftUI
import AppKit
import CoreGraphics
import PDFKit
import WatermarkCore

extension CGImage {
    var nsImage: NSImage {
        NSImage(cgImage: self, size: NSSize(width: width, height: height))
    }
}

enum PreviewRenderer {
    static func preview(
        url: URL,
        kind: WatermarkFileKind,
        config: WatermarkConfig,
        pageIndex: Int = 0
    ) -> NSImage? {
        switch kind {
        case .pdf: return pdfPreview(url: url, config: config, pageIndex: pageIndex)
        case .image: return imagePreview(url: url, config: config)
        case .unsupported: return nil
        }
    }

    static func pageCount(of url: URL) -> Int {
        PDFDocument(url: url)?.pageCount ?? 1
    }

    private static func pdfPreview(
        url: URL,
        config: WatermarkConfig,
        pageIndex: Int,
        maxDimension: CGFloat = 900
    ) -> NSImage? {
        guard let document = PDFDocument(url: url) else { return nil }
        let index = max(0, min(pageIndex, document.pageCount - 1))
        guard let page = document.page(at: index) else { return nil }
        guard let cg = PDFPreviewRenderer.render(page: page, config: config, maxDimension: maxDimension) else {
            return nil
        }
        return cg.nsImage
    }

    private static func imagePreview(url: URL, config: WatermarkConfig, maxDimension: CGFloat = 900) -> NSImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let cg = try? ImagePipeline(config: config).preview(data: data, maxDimension: maxDimension) else {
            return nil
        }
        return cg.nsImage
    }
}

@MainActor
final class AppModel: ObservableObject {

    enum Status: Sendable, Equatable {
        case pending
        case processing
        case done(String)
        case failed(String)

        var label: String {
            switch self {
            case .pending: return "待处理"
            case .processing: return "处理中"
            case .done(let d): return "完成 · \(d)"
            case .failed(let m): return "失败 · \(m)"
            }
        }

        var color: Color {
            switch self {
            case .pending: return .secondary
            case .processing: return .orange
            case .done: return .green
            case .failed: return .red
            }
        }
    }

    struct Item: Identifiable, Sendable {
        let id = UUID()
        let url: URL
        let kind: WatermarkFileKind
        var status: Status = .pending
        var pageCount: Int = 1
    }

    /// 被拒绝的文件（格式不支持）
    struct RejectedFile: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let fileExtension: String

        var reason: String {
            fileExtension.isEmpty ? "无法识别的文件类型" : "\(fileExtension.uppercased()) 格式不支持"
        }
    }

    private static let configStorageKey = "watermark.config.v1"

    @Published var config: WatermarkConfig = WatermarkConfig() {
        didSet { persist() }
    }
    @Published var items: [Item] = []
    @Published var isProcessing = false
    @Published var selectedID: UUID?
    @Published var preview: NSImage?
    @Published var message: String?
    @Published var previewPageIndex = 0
    /// 图片水印素材的缩略图
    @Published var watermarkImagePreview: NSImage?
    /// 拖入或选择的文件里不被支持的部分
    @Published var rejectedFiles: [RejectedFile] = []
    @Published var showRejectionAlert = false

    var rejectionMessage: String {
        guard !rejectedFiles.isEmpty else { return "" }
        if rejectedFiles.count == 1 {
            let file = rejectedFiles[0]
            return "「\(file.name)」\(file.reason)。\n仅支持 PDF 与常见图片格式。"
        }
        let listed = rejectedFiles.prefix(5).map { $0.name }.joined(separator: "、")
        let suffix = rejectedFiles.count > 5 ? " 等 \(rejectedFiles.count) 个文件" : ""
        return "\(listed)\(suffix) 无法处理。\n仅支持 PDF 与常见图片格式。"
    }

    init() {
        restore()
        refreshWatermarkImagePreview()
    }

    // MARK: - 持久化（Bug 9：设置固定下来，下次直接沿用）

    private func persist() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.configStorageKey)
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.configStorageKey),
              let decoded = try? JSONDecoder().decode(WatermarkConfig.self, from: data) else { return }
        config = decoded
    }

    func resetConfig() {
        config = WatermarkConfig()
        refreshWatermarkImagePreview()
        refreshPreview()
    }

    // MARK: - 文件

    func add(urls: [URL]) {
        var rejected: [RejectedFile] = []
        var added = false
        for url in urls {
            let kind = WatermarkProcessor.kind(of: url)
            guard kind != .unsupported else {
                rejected.append(RejectedFile(
                    name: url.lastPathComponent,
                    fileExtension: url.pathExtension.replacingOccurrences(of: ".", with: "")
                ))
                continue
            }
            guard !items.contains(where: { $0.url == url }) else { continue }
            var item = Item(url: url, kind: kind)
            if kind == .pdf { item.pageCount = PreviewRenderer.pageCount(of: url) }
            items.append(item)
            added = true
        }
        if !rejected.isEmpty {
            rejectedFiles = rejected
            showRejectionAlert = true
        }
        if selectedID == nil || !items.contains(where: { $0.id == selectedID }) {
            selectedID = items.first?.id
            previewPageIndex = 0
        }
        if added { refreshPreview() }
    }

    func removeSelected() {
        guard let id = selectedID else { return }
        items.removeAll { $0.id == id }
        selectedID = items.first?.id
        previewPageIndex = 0
        refreshPreview()
    }

    func clear() {
        items.removeAll()
        selectedID = nil
        preview = nil
        message = nil
        previewPageIndex = 0
    }

    var selectedItem: Item? { items.first { $0.id == selectedID } }

    /// 当前预览文件是 PDF 时的总页数
    var previewPageCount: Int {
        guard let item = selectedItem, item.kind == .pdf else { return 1 }
        return item.pageCount
    }

    /// 当前预览的是否为 PDF（图片预览时才显示源文件提示）
    var isPreviewingPDF: Bool {
        selectedItem?.kind == .pdf
    }

    func gotoPage(_ index: Int) {
        let clamped = max(0, min(index, previewPageCount - 1))
        guard clamped != previewPageIndex else { return }
        previewPageIndex = clamped
        refreshPreview()
    }

    // MARK: - 预览

    func refreshPreview() {
        guard let item = selectedItem else {
            previewTask?.cancel()
            preview = nil
            return
        }
        let url = item.url
        let kind = item.kind
        let config = self.config
        let page = previewPageIndex
        // 拖动滑块会连着触发很多次，若不取消上一个任务，它们会排队渲染大文件，
        // 表现为预览明显滞后、界面发涩
        previewTask?.cancel()
        previewTask = Task.detached(priority: .userInitiated) {
            let image = PreviewRenderer.preview(url: url, kind: kind, config: config, pageIndex: page)
            guard !Task.isCancelled else { return }
            await MainActor.run { self.preview = image }
        }
    }

    private var previewTaskStorage: Task<Void, Never>?
    private var previewTask: Task<Void, Never>? {
        get { previewTaskStorage }
        set { previewTaskStorage = newValue }
    }

    // MARK: - 处理

    func run() {
        guard !isProcessing, !items.isEmpty else { return }
        if items.count == 1 {
            saveSingle(items[0])
        } else {
            chooseDirectoryAndRun()
        }
    }

    private func saveSingle(_ item: Item) {
        let panel = NSSavePanel()
        let base = item.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(base)_wm.\(item.url.pathExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return }
        process(items: [item]) { _ in target }
    }

    private func chooseDirectoryAndRun() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择输出目录"
        panel.message = "输出文件名将自动追加 _wm 后缀，不会覆盖原文件"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        process(items: items) { url in
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var candidate = directory.appendingPathComponent("\(base)_wm.\(ext)")
            var index = 1
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = directory.appendingPathComponent("\(base)_wm-\(index).\(ext)")
                index += 1
            }
            return candidate
        }
    }

    private func process(items: [Item], destination: @escaping (URL) -> URL) {
        let config = self.config
        let snapshot = items
        isProcessing = true
        message = nil
        for item in snapshot { setStatus(.processing, for: item.url) }

        Task.detached(priority: .userInitiated) {
            var succeeded = 0
            var failed = 0
            for item in snapshot {
                // 每个文件用完立刻释放：整份 PDF 会被读入内存并产出另一份，
                // 连续处理多个大文件时峰值内存会成倍累积
                autoreleasepool {
                    do {
                        let processor = WatermarkProcessor(config: config)
                        let result = try processor.process(fileAt: item.url)
                        let target = destination(item.url)
                        if target.standardizedFileURL == item.url.standardizedFileURL {
                            throw WatermarkError.outputEqualsInput(item.url)
                        }
                        try result.data.write(to: target)
                        succeeded += 1
                        // 每个文件结束后立刻回主线程刷新状态，别等整批完成
                        Task { await MainActor.run {
                            self.setStatus(.done(result.detail), for: item.url)
                        } }
                    } catch {
                        failed += 1
                        Task { await MainActor.run {
                            self.setStatus(.failed(error.localizedDescription), for: item.url)
                        } }
                    }
                }
            }
            let successCount = succeeded
            let failureCount = failed
            await MainActor.run {
                self.isProcessing = false
                self.message = "完成 \(successCount) 个" + (failureCount > 0 ? "，失败 \(failureCount) 个" : "")
            }
        }
    }

    private func setStatus(_ status: Status, for url: URL) {
        guard let index = items.firstIndex(where: { $0.url == url }) else { return }
        items[index].status = status
    }

    // MARK: - 图片水印素材（Bug 2：选完要能看到选了什么）

    func chooseWatermarkImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        config.kind = .image
        config.image.imageData = data
        refreshWatermarkImagePreview()
        refreshPreview()
    }

    func clearWatermarkImage() {
        config.image.imageData = Data()
        refreshWatermarkImagePreview()
        refreshPreview()
    }

    func refreshWatermarkImagePreview() {
        let data = config.image.imageData
        guard !data.isEmpty else {
            watermarkImagePreview = nil
            return
        }
        Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 120,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
            let image = cg.nsImage
            await MainActor.run { self.watermarkImagePreview = image }
        }
    }
}
