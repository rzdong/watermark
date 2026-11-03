import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// 图片加水印管道。
///
/// 保真策略：
/// - 输出使用与输入完全相同的 UTI（PNG 出 PNG，JPEG 出 JPEG）
/// - 元数据字典（EXIF / TIFF / GPS / IPTC / ICC）整体回写
/// - 沿用原图的色彩空间与位深
/// - 不改写 EXIF 方向，也不物理旋转像素
/// - JPEG 复用原量化表反推出的压缩档位
/// - 绝不覆盖原文件
public struct ImagePipeline {
    public let config: WatermarkConfig

    public init(config: WatermarkConfig) {
        self.config = config
    }

    public struct Result: Sendable {
        public var data: Data
        public var uti: String
        public var pixelSize: CGSize
        /// 该格式是否能做到像素级无损
        public var isLossless: Bool
    }

    public func process(data: Data) throws -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw WatermarkError.invalidImageData
        }
        guard let uti = CGImageSourceGetType(source) as String? else {
            throw WatermarkError.unsupportedFormat("未知图片格式")
        }

        let frameCount = CGImageSourceGetCount(source)
        if frameCount > 1 {
            throw WatermarkError.unsupportedFormat("动图（\(frameCount) 帧）加水印会丢失动画，暂不支持")
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw WatermarkError.invalidImageData
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw WatermarkError.invalidImageData }

        guard let context = makeContext(
            width: width,
            height: height,
            bitsPerComponent: image.bitsPerComponent,
            colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: image.bitmapInfo
        ) else {
            throw WatermarkError.unsupportedFormat(uti)
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let canvas = CGSize(width: width, height: height)
        try Self.drawWatermark(config, in: context, canvasSize: canvas)

        guard let output = context.makeImage() else {
            throw WatermarkError.writeFailed("无法生成输出位图")
        }

        var options = properties
        if isJPEG(uti) {
            if let quality = JPEGQualityEstimator.estimate(from: data) {
                options[kCGImageDestinationLossyCompressionQuality as String] = quality
            }
        } else if isHEIC(uti) {
            // HEIC 用 1.0 表示无损编码
            options[kCGImageDestinationLossyCompressionQuality as String] = 1.0
        }

        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out as CFMutableData, uti as CFString, 1, nil
        ) else {
            throw WatermarkError.unsupportedFormat(uti)
        }
        CGImageDestinationAddImage(destination, output, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw WatermarkError.writeFailed("写出失败")
        }

        return Result(
            data: out as Data,
            uti: uti,
            pixelSize: canvas,
            isLossless: Self.isLosslessFormat(uti)
        )
    }

    // MARK: - 预览

    /// 生成预览图。按比例缩放，但水印布局用的是同一套相对参数，效果与最终输出一致。
    public func preview(data: Data, maxDimension: CGFloat = 900) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw WatermarkError.invalidImageData
        }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxDimension / max(width, height))
        let targetWidth = max(Int(width * scale), 1)
        let targetHeight = max(Int(height * scale), 1)

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw WatermarkError.invalidImageData
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        try Self.drawWatermark(config, in: context, canvasSize: CGSize(width: targetWidth, height: targetHeight))
        guard let output = context.makeImage() else {
            throw WatermarkError.invalidImageData
        }
        return output
    }

    // MARK: - 画布

    private func makeContext(
        width: Int,
        height: Int,
        bitsPerComponent: Int,
        colorSpace: CGColorSpace,
        bitmapInfo: CGBitmapInfo
    ) -> CGContext? {
        var candidates: [(Int, UInt32)] = [(bitsPerComponent, bitmapInfo.rawValue)]
        if bitsPerComponent != 8 {
            candidates.append((8, bitmapInfo.rawValue))
        }
        candidates.append((8, CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        candidates.append((8, CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue))

        for (bits, info) in candidates {
            if let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: bits,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: info
            ) {
                return context
            }
        }
        return nil
    }

    // MARK: - 绘制

    /// 在任意 CGContext 上叠加水印。预览与正式输出共用这一份实现，保证所见即所得。
    public static func drawWatermark(
        _ config: WatermarkConfig,
        in context: CGContext,
        canvasSize: CGSize,
    ) throws {
        let engine = WatermarkLayoutEngine(config: config)
        let tiles = try engine.tiles(canvasSize: canvasSize)
        guard !tiles.isEmpty else { return }
        let natural = try engine.naturalSize()

        context.saveGState()
        // CGBitmapContext 本身就是左下原点、y 轴向上，与 PDF 同一套坐标，
        // 不需要再翻转——翻转反而会让 CoreText 画出来的文字上下颠倒
        //
        // 关键：必须先重置 textMatrix。PDFPage.draw(with:to:) 渲染完 PDF 文本后，
        // 会把 context 的 textMatrix 留在页面最后一次 Tm 指令的状态（实测某些发票
        // 会留下 3.175 倍的缩放和位移）。CTLineDraw 依赖 textMatrix，不重置的话
        // 水印会被放大且整体偏移，表现为「预览里文字重叠、偏大」，而 PDF 导出走
        // 矢量路径不受影响——于是预览与导出对不上。
        context.textMatrix = .identity
        context.setAlpha(CGFloat(config.layout.opacity))

        switch config.kind {
        case .text:
            for tile in tiles {
                context.saveGState()
                context.translateBy(x: tile.center.x, y: tile.center.y)
                context.rotate(by: tile.rotationRadians)
                context.scaleBy(x: tile.size.width / natural.width, y: tile.size.height / natural.height)
                Self.drawText(config.text, in: context, naturalSize: natural)
                context.restoreGState()
            }

        case .image:
            let source = try ImageSource.make(from: config.image.imageData)
            for tile in tiles {
                context.saveGState()
                context.translateBy(x: tile.center.x, y: tile.center.y)
                context.rotate(by: tile.rotationRadians)
                context.scaleBy(x: tile.size.width, y: tile.size.height)
                context.draw(source.cgImage, in: CGRect(x: -0.5, y: -0.5, width: 1, height: 1))
                context.restoreGState()
            }
        }

        context.restoreGState()
    }

    /// 在原点为中心、y 向上的坐标系里绘制多行文字
    private static func drawText(_ spec: TextWatermark, in context: CGContext, naturalSize: CGSize) {
        let font = WatermarkLayoutEngine.resolveFont(
            name: spec.fontName, size: CGFloat(spec.fontSize), bold: spec.bold
        )
        let lines = spec.content.components(separatedBy: "\n")
        var y = naturalSize.height / 2 - CGFloat(spec.strokeWidth) / 2

        for line in lines {
            let attributed = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)
            CFAttributedStringReplaceString(attributed, CFRangeMake(0, 0), line as CFString)
            let range = CFRangeMake(0, CFAttributedStringGetLength(attributed))
            CFAttributedStringSetAttribute(attributed, range, kCTFontAttributeName, font)
            // 关键：不声明这一条，CoreText 会用 attributed string 默认的黑色绘制，
            // 直接覆盖掉配置的填充色，表现为「改颜色没反应」
            CFAttributedStringSetAttribute(
                attributed, range,
                kCTForegroundColorFromContextAttributeName,
                kCFBooleanTrue
            )
            if spec.letterSpacing != 0 {
                CFAttributedStringSetAttribute(
                    attributed, range, kCTKernAttributeName,
                    NSNumber(value: spec.letterSpacing * spec.fontSize)
                )
            }
            let ctLine = CTLineCreateWithAttributedString(attributed!)

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))

            if spec.strokeWidth > 0 {
                context.setTextDrawingMode(.fillStroke)
                context.setLineWidth(CGFloat(spec.strokeWidth))
                context.setStrokeColor(spec.strokeColor.cgColor)
            } else {
                context.setTextDrawingMode(.fill)
            }
            context.setFillColor(spec.color.cgColor)
            context.textPosition = CGPoint(x: -lineWidth / 2, y: y - ascent)
            CTLineDraw(ctLine, context)

            y -= (ascent + descent) * CGFloat(spec.lineSpacing)
        }
    }

    // MARK: - 格式判断

    public static func isLosslessFormat(_ uti: String) -> Bool {
        switch uti {
        case "public.png", "public.tiff", "com.microsoft.bmp",
             "com.apple.icns", "public.QuickTimeImage", "com.truevision.tga-image",
             "org.oasis-open.opendocument.image", "public.svg-image":
            return true
        case "public.jpeg", "public.jpeg-2000", "com.google.webp":
            return false
        case "public.heic", "public.heif", "public.heics":
            return true      // 我们会强制无损编码
        default:
            return true
        }
    }

    private func isJPEG(_ uti: String) -> Bool {
        uti == "public.jpeg" || uti == "public.jpeg-2000"
    }

    private func isHEIC(_ uti: String) -> Bool {
        uti == "public.heic" || uti == "public.heif" || uti == "public.heics"
    }
}
