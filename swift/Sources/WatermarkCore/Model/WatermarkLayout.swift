import Foundation
import CoreGraphics
import CoreText
import ImageIO

public enum WatermarkError: Error, LocalizedError, Sendable {
    case emptyText
    case invalidImageData
    case unsupportedFormat(String)
    case encryptedPDF
    case malformedPDF(String)
    case encryptedOrUnsupportedPDF(String)
    case outputEqualsInput(URL)
    case noPageMatched(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            return "水印文字为空"
        case .invalidImageData:
            return "图片水印数据无法解码"
        case .unsupportedFormat(let f):
            return "暂不支持的格式：\(f)"
        case .encryptedPDF:
            // 只有真正需要密码的文档才会走到这里。
            // 无需密码就能打开的那类「权限型加密」已由 WatermarkProcessor 自动解出副本处理。
            return "该 PDF 需要密码才能打开，请先解除密码保护"
        case .malformedPDF(let m):
            return "PDF 结构异常：\(m)"
        case .encryptedOrUnsupportedPDF(let m):
            return "无法处理的 PDF：\(m)"
        case .outputEqualsInput(let u):
            return "输出路径与源文件相同，已拒绝：\(u.lastPathComponent)"
        case .noPageMatched(let detail):
            return "没有任何页面被加水印（\(detail)），请检查「PDF 选项」的页面范围"
        case .writeFailed(let m):
            return "写入失败：\(m)"
        }
    }
}

/// 一个已定位的水印实例。坐标系为左下原点（与 PDF 一致）。
public struct WatermarkTile: Sendable {
    public var center: CGPoint
    public var size: CGSize
    /// 逆时针弧度
    public var rotationRadians: CGFloat
    public var opacity: Double

    public init(center: CGPoint, size: CGSize, rotationRadians: CGFloat, opacity: Double) {
        self.center = center
        self.size = size
        self.rotationRadians = rotationRadians
        self.opacity = opacity
    }
}

public struct WatermarkLayoutEngine: Sendable {
    /// 文字水印的基准字号，与 TextWatermark 的默认值保持一致
    public static let baseFontSize: Double = 28

    public let config: WatermarkConfig

    public init(config: WatermarkConfig) {
        self.config = config
    }

    // MARK: - 字体

    /// 解析字体，失败时回退到系统中文字体
    public static func resolveFont(name: String, size: CGFloat, bold: Bool) -> CTFont {
        var font = CTFontCreateWithName(name as CFString, size, nil)
        // PostScript 名找不到时，CoreText 会返回一个默认字体，这里用家族名再试一次
        if CTFontCopyPostScriptName(font) as String != name {
            // 尝试把 "PingFangSC-Regular" 之类拆成家族名 + 去掉后缀
            let family = name.replacingOccurrences(of: "-", with: " ")
            font = CTFontCreateWithName(family as CFString, size, nil)
        }
        if bold {
            if let boldFont = CTFontCreateCopyWithSymbolicTraits(
                font, 0, nil, .boldTrait, .boldTrait
            ) {
                font = boldFont
            }
        }
        return font
    }

    // MARK: - 尺寸测量

    /// 水印内容在基准字号下的自然尺寸（文字：point；图片：像素）
    public func naturalSize() throws -> CGSize {
        switch config.kind {
        case .text:
            return try measureText(config.text)
        case .image:
            guard !config.image.imageData.isEmpty else {
                throw WatermarkError.invalidImageData
            }
            let source = try ImageSource.make(from: config.image.imageData)
            return source.orientedPixelSize
        }
    }

    private func measureText(_ spec: TextWatermark) throws -> CGSize {
        let trimmed = spec.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WatermarkError.emptyText }

        let font = Self.resolveFont(name: spec.fontName, size: CGFloat(spec.fontSize), bold: spec.bold)
        let lines = spec.content.components(separatedBy: "\n")

        var maxWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var lastLineHeight: CGFloat = 0

        for line in lines {
            let attr = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)
            CFAttributedStringReplaceString(attr, CFRangeMake(0, 0), line as CFString)
            let fullRange = CFRangeMake(0, CFAttributedStringGetLength(attr))
            CFAttributedStringSetAttribute(attr, fullRange, kCTFontAttributeName, font)
            if spec.letterSpacing != 0 {
                CFAttributedStringSetAttribute(
                    attr, fullRange, kCTKernAttributeName,
                    NSNumber(value: spec.letterSpacing * spec.fontSize)
                )
            }
            let ctLine = CTLineCreateWithAttributedString(attr ?? CFAttributedStringCreate(kCFAllocatorDefault, "" as CFString, nil)!)

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
            maxWidth = max(maxWidth, width)
            lastLineHeight = ascent + descent
            totalHeight += lastLineHeight
        }

        if lines.count > 1 {
            totalHeight += lastLineHeight * CGFloat(spec.lineSpacing - 1) * CGFloat(lines.count - 1)
        }
        // 描边会向外扩张半个线宽
        if spec.strokeWidth > 0 {
            let grow = CGFloat(spec.strokeWidth)
            maxWidth += grow
            totalHeight += grow
        }
        return CGSize(width: max(maxWidth, 1), height: max(totalHeight, 1))
    }

    // MARK: - 布局

    /// 计算画布上所有水印实例的位置
    public func tiles(canvasSize: CGSize) throws -> [WatermarkTile] {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return [] }

        let natural = try naturalSize()
        // 字号必须真正影响最终大小：基准字号下占比滑块就是 1:1，
        // 字号翻倍水印就翻倍（否则缩放会把字号的影响抵消掉）
        let fontSizeFactor = config.kind == .text
            ? max(config.text.fontSize, 1) / Self.baseFontSize
            : 1.0
        // 基准取宽高的几何平均，而不是画布宽度：
        // 按宽度算的话，发票这类又宽又矮的页面会把水印撑得格外大，
        // 相邻水印看上去就像叠在一起。几何平均让不同宽高比的页面观感一致。
        let base = sqrt(max(canvasSize.width, 1) * max(canvasSize.height, 1))
        let tileWidth = base
            * CGFloat(config.effectiveScalePercent / 100.0)
            * CGFloat(fontSizeFactor)
        let aspect = natural.height / natural.width
        let tileHeight = tileWidth * aspect

        // 页面旋转由「视觉坐标系 + 补偿矩阵」一并处理（见 PDFWatermarkContent），
        // 这里只负责用户设定的角度，不要再叠加 /Rotate，否则会双重补偿。
        let rotation = CGFloat(config.layout.rotationDegrees) * .pi / 180.0
        let opacity = config.layout.opacity
        // 旋转后的外接矩形，用于边界对齐
        let cosR = abs(cos(rotation))
        let sinR = abs(sin(rotation))
        let boundW = tileWidth * cosR + tileHeight * sinR
        let boundH = tileWidth * sinR + tileHeight * cosR

        if config.layout.tiling {
            return tilingTiles(
                canvasSize: canvasSize,
                tileWidth: tileWidth,
                tileHeight: tileHeight,
                rotation: rotation,
                opacity: opacity
            )
        }

        let margin = min(canvasSize.width, canvasSize.height) * CGFloat(config.layout.marginPercent / 100.0)
        let area = CGRect(
            x: margin,
            y: margin,
            width: max(canvasSize.width - margin * 2, 0),
            height: max(canvasSize.height - margin * 2, 0)
        )

        var unit = config.layout.anchor.unitPoint
        if config.layout.anchor == .custom {
            unit = config.layout.customPosition
        }

        // 用旋转后的外接框做对齐，保证旋转后仍完整落在画布内
        let cx = area.minX + CGFloat(unit.x) * max(area.width - boundW, 0) + boundW / 2
        let cy = area.minY + CGFloat(unit.y) * max(area.height - boundH, 0) + boundH / 2

        return [WatermarkTile(
            center: CGPoint(x: cx, y: cy),
            size: CGSize(width: tileWidth, height: tileHeight),
            rotationRadians: rotation,
            opacity: opacity
        )]
    }

    private func tilingTiles(
        canvasSize: CGSize,
        tileWidth: CGFloat,
        tileHeight: CGFloat,
        rotation: CGFloat,
        opacity: Double
    ) -> [WatermarkTile] {
        let spacing = max(config.layout.tileSpacing, 0.1)

        // 步长必须按「旋转后的外接框」算，否则扁长的文字水印在纵向上会互相重叠
        let cosR = abs(cos(rotation))
        let sinR = abs(sin(rotation))
        let boundW = tileWidth * cosR + tileHeight * sinR
        let boundH = tileWidth * sinR + tileHeight * cosR
        let stepX = boundW * CGFloat(spacing)
        let stepY = boundH * CGFloat(spacing)

        // 外扩半个外接框，让边角那一块也能露出一部分。
        // 实测外扩后横向覆盖更好（56% vs 不外扩的 48%），
        // 但别再多加——加一整个水印宽度会让大半的块落到页面外被裁掉。
        let padX = boundW / 2
        let padY = boundH / 2

        // 步长必须为正：配置被写坏（占比为 0）或画布退化时 stepX/stepY 会是 0，
        // 那样 x/y 永远不前进，内层循环无限 append 直到内存耗尽
        guard stepX > 0.01, stepY > 0.01, canvasSize.width > 0, canvasSize.height > 0 else {
            return []
        }

        // 从「画布外侧」一路铺到「对侧画布外」，保证整块画布被完整覆盖。
        //
        // 曾先把整片平铺居中再算行列数，两端会各留一截没铺到——对称是有了，
        // 但页面带 /Rotate 时那截空白会被放大，实测只剩四成覆盖。
        // 铺满优先于对称。
        let startX = -padX
        let startY = -padY
        let endX = canvasSize.width + padX
        let endY = canvasSize.height + padY
        let columns = max(Int(floor((endX - startX) / stepX)) + 1, 1)
        let rows = max(Int(floor((endY - startY) / stepY)) + 1, 1)
        let originX = startX
        let originY = startY

        var result: [WatermarkTile] = []
        // 上限保护：超大画布 + 极小间距会产出上百万块，足以让导出与阅读器卡死
        let maxTiles = 20000
        for row in 0..<rows {
            let offsetX = (config.layout.staggerRows && row % 2 == 1) ? stepX / 2 : 0
            for column in 0..<columns {
                result.append(WatermarkTile(
                    center: CGPoint(
                        x: originX + CGFloat(column) * stepX + offsetX,
                        y: originY + CGFloat(row) * stepY
                    ),
                    size: CGSize(width: tileWidth, height: tileHeight),
                    rotationRadians: rotation,
                    opacity: opacity
                ))
                if result.count >= maxTiles { return result }
            }
        }
        return result
    }
}
