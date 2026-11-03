import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PDFKit

public enum WatermarkFileKind: Sendable {
    case pdf
    case image
    case unsupported
}

public struct ProcessedFile: Sendable {
    public var data: Data
    public var fileExtension: String
    public var detail: String
    /// 该格式能否做到像素级无损
    public var isLossless: Bool
}

/// 图片与 PDF 的统一入口
public struct WatermarkProcessor {
    public let config: WatermarkConfig

    public init(config: WatermarkConfig) {
        self.config = config
    }

    /// 判定文件是否为可处理的 PDF 或图片
    ///
    /// 注意：不能只判断 `CGImageSourceCreateWithData` 是否返回非空——
    /// 它对任意二进制数据（dmg、zip…）都会成功创建 source，只是 type 为 nil、帧数为 0。
    /// 必须再确认「能识别出类型」且「至少有一帧」。
    public static func kind(of url: URL) -> WatermarkFileKind {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }

        // 先用 UTI 判断，最可靠，能直接挡住磁盘镜像、压缩包这类
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            return .image
        }

        // UTI 判不出来时退回内容嗅探
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) != nil,
              CGImageSourceGetCount(source) > 0 else {
            return .unsupported
        }
        return .image
    }

    public func process(fileAt url: URL) throws -> ProcessedFile {
        var data = try Data(contentsOf: url)
        switch Self.kind(of: url) {
        case .pdf:
            var document = try PDFRawDocument(data: data)
            var didStripProtection = false

            // 权限型加密（无需密码就能打开、只是禁止打印/编辑）很常见，
            // 尤其各类政务/信用报告。这类文件可以直接解出无加密副本再处理，
            // 免去用户先用别的软件另存一遍。
            if document.isEncrypted {
                guard let plain = Self.unprotectedCopy(of: data) else {
                    throw WatermarkError.encryptedPDF
                }
                data = plain
                document = try PDFRawDocument(data: plain)
                didStripProtection = true
            }

            let result = try PDFIncrementalWriter(document: document, config: config).process()
            // 一页都没匹配上时必须报错：否则用户只会看到「完成」却拿不到任何水印
            if result.watermarkedPages == 0 {
                throw WatermarkError.noPageMatched(config.pdf.pageRange.displayName)
            }
            return ProcessedFile(
                data: result.data,
                fileExtension: "pdf",
                detail: (didStripProtection ? "已解除保护 · " : "")
                    + "\(result.pageCount) 页 · 水印 \(result.watermarkedPages) 页"
                    + " · 增量 \(Self.byteText(result.appendedBytes))",
                // 解除保护那条路是整份重写，图片可能被重新编码，不能再算无损
                isLossless: !didStripProtection
            )

        case .image:
            let result = try ImagePipeline(config: config).process(data: data)
            let ext = Self.preferredExtension(for: result.uti, fallback: url.pathExtension)
            let size = result.pixelSize
            return ProcessedFile(
                data: result.data,
                fileExtension: ext,
                detail: "\(Int(size.width))×\(Int(size.height))" +
                        (result.isLossless ? " · 无损" : " · JPEG 复用原压缩档"),
                isLossless: result.isLossless
            )

        case .unsupported:
            throw WatermarkError.unsupportedFormat(url.lastPathComponent)
        }
    }

    /// 解出一份不带加密的副本。
    ///
    /// 只处理「权限型加密」——`isLocked == false` 说明空密码就能打开
    /// （WPS、预览都能直接看），只是限制了打印/编辑。真正需要密码的文档会返回 nil。
    ///
    /// 注意这条路是整份重写：PDFKit 会重新编码图片，扫描件可能有画质损失，
    /// 所以调用方要把结果标记为「非无损」。
    public static func unprotectedCopy(of data: Data) -> Data? {
        guard let document = PDFDocument(data: data), !document.isLocked else { return nil }
        guard let copy = document.dataRepresentation() else { return nil }
        // 必须确认副本真的不再带加密。PDFKit 对自己写出的加密文档会原样保留加密，
        // 这种情形我们无能为力，返回 nil 让调用方明确报错，而不是产出一份仍然加密的文件。
        guard let check = PDFDocument(data: copy), !check.isEncrypted else { return nil }
        return copy
    }

    public static func preferredExtension(for uti: String, fallback: String) -> String {
        if let type = UTType(uti), let ext = type.preferredFilenameExtension { return ext }
        return fallback
    }

    public static func byteText(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return String(format: "%.1f KB", Double(count) / 1024) }
        return String(format: "%.2f MB", Double(count) / 1024 / 1024)
    }
}
