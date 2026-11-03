import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// 生成好的一页水印：可直接挂到页面 /Resources 的资源项，以及一段内容流。
///
/// 关于压缩：Apple PDFKit 会拒绝这里自行生成的 zlib 流（/FlateDecode），
/// 表现为水印写进去了却完全不显示。因此本文件一律不自己压缩：
/// - 文字走 Form XObject，字形路径在整份文档里只存一份
/// - 图片走 JPEG（/DCTDecode），由 ImageIO 产出标准 JPEG，PDF 原生支持
public struct PDFWatermarkContent {
    /// 需要合并进页面 /Resources 的条目（/ExtGState、/XObject、/ProcSet）
    public var resources: [String: PDFObject]
    /// 水印绘制指令
    public var contentStream: Data
    /// 需要一并写入文件的间接对象（Form / 图片 XObject / SMask）
    public var pendingObjects: [(number: Int, object: PDFObject)]

    public init(
        resources: [String: PDFObject],
        contentStream: Data,
        pendingObjects: [(number: Int, object: PDFObject)]
    ) {
        self.resources = resources
        self.contentStream = contentStream
        self.pendingObjects = pendingObjects
    }
}

public struct PDFWatermarkContentBuilder {
    public let config: WatermarkConfig
    public let allocator: PDFObjectNumberAllocator

    /// 文字水印的 Form XObject 资源名
    private static let formName = "WMForm"
    /// 图片水印的 XObject 资源名
    private static let imageName = "WMImg"
    /// 图形状态资源名
    private static let gstateName = "WMGS"

    public init(config: WatermarkConfig, allocator: PDFObjectNumberAllocator) {
        self.config = config
        self.allocator = allocator
    }

    public func build(canvasSize: CGSize) throws -> PDFWatermarkContent {
        let (resources, pending) = try makeResources()
        let stream = try makeContentStream(canvasSize: canvasSize)
        return PDFWatermarkContent(resources: resources, contentStream: stream, pendingObjects: pending)
    }

    // MARK: - 资源（全文档共享一份）

    public func makeResources() throws -> (resources: [String: PDFObject], pendingObjects: [(number: Int, object: PDFObject)]) {
        var pending: [(number: Int, object: PDFObject)] = []
        var resources: [String: PDFObject] = [:]

        resources["ProcSet"] = .array([
            .name("PDF"), .name("ImageB"), .name("ImageC"), .name("ImageI")
        ])
        // 图片分支也要有 ExtGState：文字走 Form 时自带 gs，图片分支若不设，
        // 导出的 PDF 里图片水印会是 100% 不透明，直接盖住正文（预览却正常）
        resources["ExtGState"] = .dictionary([
            Self.gstateName: Self.extGState(opacity: config.layout.opacity)
        ])

        switch config.kind {
        case .text:
            let natural = try WatermarkLayoutEngine(config: config).naturalSize()
            let form = try Self.buildTextForm(
                config.text,
                naturalSize: natural,
                opacity: config.layout.opacity,
                allocator: allocator
            )
            pending.append(form)
            resources["XObject"] = .dictionary([
                Self.formName: .reference(objectNumber: form.number, generation: 0)
            ])

        case .image:
            let built = try Self.buildImageObjects(config.image, allocator: allocator)
            pending.append(contentsOf: built.objects)
            resources["XObject"] = .dictionary([
                Self.imageName: .reference(objectNumber: built.imageNumber, generation: 0)
            ])
        }

        return (resources, pending)
    }

    private static func extGState(opacity: Double) -> PDFObject {
        .dictionary([
            "Type": .name("ExtGState"),
            "ca": .real(opacity),
            "CA": .real(opacity),
            "AIS": .boolean(false),
            "BM": .name("Normal")
        ])
    }

    // MARK: - 文字：Form XObject

    private static func buildTextForm(
        _ spec: TextWatermark,
        naturalSize: CGSize,
        opacity: Double,
        allocator: PDFObjectNumberAllocator
    ) throws -> (number: Int, object: PDFObject) {
        let path = try Self.textPathOperators(spec, naturalSize: naturalSize)
        let halfWidth = naturalSize.width / 2
        let halfHeight = naturalSize.height / 2

        var ops = "q\n/\(gstateName) gs\n"
        ops += "\(Self.rgb(spec.color)) rg\n"
        ops += path
        ops += "f\n"
        if spec.strokeWidth > 0 {
            ops += "\(Self.rgb(spec.strokeColor)) RG\n"
            ops += "\(Self.num(CGFloat(spec.strokeWidth))) w\n"
            ops += "1 J 1 j\n"
            ops += path
            ops += "S\n"
        }
        ops += "Q\n"

        let dictionary: [String: PDFObject] = [
            "Type": .name("XObject"),
            "Subtype": .name("Form"),
            "BBox": .array([
                .real(-Double(halfWidth)), .real(-Double(halfHeight)),
                .real(Double(halfWidth)), .real(Double(halfHeight))
            ]),
            "Resources": .dictionary([
                "ExtGState": .dictionary([gstateName: extGState(opacity: opacity)]),
                "ProcSet": .array([.name("PDF")])
            ])
        ]
        return (allocator.allocate(), .stream(PDFStream(dictionary: dictionary, data: Data(ops.utf8))))
    }

    // MARK: - 内容流（每页一份，只放 cm + Do）

    public func makeContentStream(canvasSize: CGSize, pageRotation: Int = 0) throws -> Data {
        let engine = WatermarkLayoutEngine(config: config)
        var tiles = try engine.tiles(canvasSize: canvasSize)
        guard !tiles.isEmpty else { return Data() }

        // 覆盖率最优的那组矩阵会把水印多转 180°，这里把角度补回去抵消，
        // 于是「铺得开」和「方向正」可以兼得。
        if PDFPageGeometry.usesFlippedMatrix(rotation: pageRotation) {
            tiles = tiles.map { tile in
                var adjusted = tile
                adjusted.rotationRadians += .pi
                return adjusted
            }
        }

        var ops = "q\n"
        // 页面带 /Rotate 时，平铺是在「阅读器看到的那套坐标」里算的，
        // 这里写一个 cm 矩阵把它映射回页面原始坐标系。
        if let m = PDFPageGeometry.inverseRotationMatrix(box: canvasSize, rotation: pageRotation) {
            ops += "\(m) cm\n"
        }
        switch config.kind {
        case .text:
            let natural = try engine.naturalSize()
            for tile in tiles {
                let scaleX = tile.size.width / natural.width
                let scaleY = tile.size.height / natural.height
                let m = Self.matrix(
                    scaleX: scaleX, scaleY: scaleY,
                    rotation: tile.rotationRadians, center: tile.center
                )
                ops += "q\n\(m) cm\n/\(Self.formName) Do\nQ\n"
            }

        case .image:
            // 必须显式应用 ExtGState，否则图片水印会不透明地盖住正文
            ops += "/\(Self.gstateName) gs\n"
            for tile in tiles {
                let m = Self.imageMatrix(size: tile.size, rotation: tile.rotationRadians, center: tile.center)
                ops += "q\n\(m) cm\n/\(Self.imageName) Do\nQ\n"
            }
        }
        ops += "Q\n"
        return Data(ops.utf8)
    }

    // MARK: - 矩阵

    private static func matrix(scaleX: CGFloat, scaleY: CGFloat, rotation: CGFloat, center: CGPoint) -> String {
        let c = cos(rotation)
        let s = sin(rotation)
        let a = scaleX * c
        let b = scaleX * s
        let cc = -scaleY * s
        let d = scaleY * c
        return "\(num(a)) \(num(b)) \(num(cc)) \(num(d)) \(num(center.x)) \(num(center.y))"
    }

    private static func imageMatrix(size: CGSize, rotation: CGFloat, center: CGPoint) -> String {
        let c = cos(rotation)
        let s = sin(rotation)
        let a = size.width * c
        let b = size.width * s
        let cc = -size.height * s
        let d = size.height * c
        let e = center.x - 0.5 * (a + cc)
        let f = center.y - 0.5 * (b + d)
        return "\(num(a)) \(num(b)) \(num(cc)) \(num(d)) \(num(e)) \(num(f))"
    }

    // MARK: - 文字转矢量路径

    /// 把文字转成 PDF 路径指令。不嵌字体，任意语言（含中文）都能正确渲染。
    static func textPathOperators(_ spec: TextWatermark, naturalSize: CGSize) throws -> String {
        let trimmed = spec.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WatermarkError.emptyText }

        let font = WatermarkLayoutEngine.resolveFont(
            name: spec.fontName, size: CGFloat(spec.fontSize), bold: spec.bold
        )
        let lines = spec.content.components(separatedBy: "\n")

        struct LineMetric { var text: String; var width: CGFloat; var ascent: CGFloat; var descent: CGFloat }
        var metrics: [LineMetric] = []

        for line in lines {
            let attr = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)
            CFAttributedStringReplaceString(attr, CFRangeMake(0, 0), line as CFString)
            let range = CFRangeMake(0, CFAttributedStringGetLength(attr))
            CFAttributedStringSetAttribute(attr, range, kCTFontAttributeName, font)
            if spec.letterSpacing != 0 {
                CFAttributedStringSetAttribute(
                    attr, range, kCTKernAttributeName,
                    NSNumber(value: spec.letterSpacing * spec.fontSize)
                )
            }
            let ctLine = CTLineCreateWithAttributedString(attr!)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
            metrics.append(LineMetric(text: line, width: width, ascent: ascent, descent: descent))
        }

        var baselineY = naturalSize.height / 2 - CGFloat(spec.strokeWidth) / 2
        var ops = ""

        for metric in metrics {
            let baseline = baselineY - metric.ascent
            var penX = -metric.width / 2

            let unichars = Array(metric.text.utf16)
            guard !unichars.isEmpty else {
                baselineY -= (metric.ascent + metric.descent) * CGFloat(spec.lineSpacing)
                continue
            }

            var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
            let ok = CTFontGetGlyphsForCharacters(font, unichars, &glyphs, unichars.count)
            guard ok else {
                baselineY -= (metric.ascent + metric.descent) * CGFloat(spec.lineSpacing)
                continue
            }

            var advances = [CGSize](repeating: .zero, count: unichars.count)
            CTFontGetAdvancesForGlyphs(font, .default, glyphs, &advances, unichars.count)
            let spacing = CGFloat(spec.letterSpacing) * CGFloat(spec.fontSize)

            for i in 0..<unichars.count {
                if let glyphPath = CTFontCreatePathForGlyph(font, glyphs[i], nil) {
                    var transform = CGAffineTransform(translationX: penX, y: baseline)
                    if let moved = glyphPath.copy(using: &transform) {
                        ops += pdfPathOperators(moved)
                    }
                }
                penX += advances[i].width + spacing
            }
            baselineY -= (metric.ascent + metric.descent) * CGFloat(spec.lineSpacing)
        }

        return ops
    }

    static func pdfPathOperators(_ path: CGPath) -> String {
        var out = ""
        var current = CGPoint.zero
        path.applyWithBlock { element in
            let e = element.pointee
            let p = e.points
            switch e.type {
            case .moveToPoint:
                out += "\(num(p[0].x)) \(num(p[0].y)) m\n"
                current = p[0]
            case .addLineToPoint:
                out += "\(num(p[0].x)) \(num(p[0].y)) l\n"
                current = p[0]
            case .addQuadCurveToPoint:
                let control = p[0]
                let end = p[1]
                let c1 = CGPoint(
                    x: current.x + 2.0 / 3.0 * (control.x - current.x),
                    y: current.y + 2.0 / 3.0 * (control.y - current.y)
                )
                let c2 = CGPoint(
                    x: end.x + 2.0 / 3.0 * (control.x - end.x),
                    y: end.y + 2.0 / 3.0 * (control.y - end.y)
                )
                out += "\(num(c1.x)) \(num(c1.y)) \(num(c2.x)) \(num(c2.y)) \(num(end.x)) \(num(end.y)) c\n"
                current = end
            case .addCurveToPoint:
                out += "\(num(p[0].x)) \(num(p[0].y)) \(num(p[1].x)) \(num(p[1].y)) \(num(p[2].x)) \(num(p[2].y)) c\n"
                current = p[2]
            case .closeSubpath:
                out += "h\n"
            @unknown default:
                break
            }
        }
        return out
    }

    // MARK: - 图片 XObject（JPEG / DCTDecode）

    private struct BuiltImage {
        var imageNumber: Int
        var objects: [(number: Int, object: PDFObject)]
    }

    private static func buildImageObjects(
        _ spec: ImageWatermark,
        allocator: PDFObjectNumberAllocator
    ) throws -> BuiltImage {
        let source = try ImageSource.make(from: spec.imageData)
        guard let planes = source.renderRGBAPlanes() else {
            throw WatermarkError.invalidImageData
        }

        // 由 ImageIO 产出标准 JPEG，避免自己压 zlib
        guard let rgbJPEG = jpegData(
            bytes: planes.rgb,
            width: planes.width,
            height: planes.height,
            components: 3,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else {
            throw WatermarkError.invalidImageData
        }

        let smaskNumber = planes.hasAlpha ? allocator.allocate() : nil
        let imageNumber = allocator.allocate()

        var imageDict: [String: PDFObject] = [
            "Type": .name("XObject"),
            "Subtype": .name("Image"),
            "Width": .integer(planes.width),
            "Height": .integer(planes.height),
            "ColorSpace": .name("DeviceRGB"),
            "BitsPerComponent": .integer(8),
            "Filter": .name("DCTDecode")
        ]

        var objects: [(number: Int, object: PDFObject)] = []

        if let smaskNumber {
            imageDict["SMask"] = .reference(objectNumber: smaskNumber, generation: 0)
            var smaskDict: [String: PDFObject] = [
                "Type": .name("XObject"),
                "Subtype": .name("Image"),
                "Width": .integer(planes.width),
                "Height": .integer(planes.height),
                "ColorSpace": .name("DeviceGray"),
                "BitsPerComponent": .integer(8)
            ]
            // 灰度遮挡层同样用 JPEG；失败则退回未压缩的原始灰度数据
            if let grayJPEG = jpegData(
                bytes: planes.alpha,
                width: planes.width,
                height: planes.height,
                components: 1,
                colorSpace: CGColorSpaceCreateDeviceGray()
            ) {
                smaskDict["Filter"] = .name("DCTDecode")
                objects.append((smaskNumber, .stream(PDFStream(dictionary: smaskDict, data: grayJPEG))))
            } else {
                objects.append((smaskNumber, .stream(PDFStream(dictionary: smaskDict, data: Data(planes.alpha)))))
            }
        }

        objects.append((imageNumber, .stream(PDFStream(dictionary: imageDict, data: rgbJPEG))))
        return BuiltImage(imageNumber: imageNumber, objects: objects)
    }

    private static func jpegData(
        bytes: [UInt8],
        width: Int,
        height: Int,
        components: Int,
        colorSpace: CGColorSpace
    ) -> Data? {
        guard width > 0, height > 0 else { return nil }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8 * components,
            bytesPerRow: width * components,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    // MARK: - 数值格式化

    private static func rgb(_ color: RGBAColor) -> String {
        "\(num(color.red)) \(num(color.green)) \(num(color.blue))"
    }

    static func num(_ value: CGFloat) -> String {
        let v = value.isFinite ? value : 0
        if v == 0 { return "0" }
        var s = String(format: "%.4f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
