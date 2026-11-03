import XCTest
import CoreGraphics
import PDFKit
@testable import WatermarkCore

/// 逐项验证「配置改了之后渲染是否真的跟着变」
final class ConfigEffectTests: XCTestCase {

    // MARK: - 工具

    private func whitePNG(_ size: Int = 500) throws -> Data {
        var raw = [UInt8](repeating: 255, count: size * size * 4)
        guard let ctx = CGContext(
            data: &raw, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage() else { throw WatermarkError.invalidImageData }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw WatermarkError.invalidImageData
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func baseConfig() -> WatermarkConfig {
        var c = WatermarkConfig()
        c.text.content = "测"
        c.layout.tiling = false
        c.layout.anchor = .center
        c.layout.opacity = 1
        c.layout.scalePercent = 60
        c.layout.rotationDegrees = 0
        return c
    }

    /// 统计明显偏红的像素数（R 高、G/B 低）
    private func redPixels(in planes: ImageSource.RGBAPlanes) -> Int {
        var n = 0
        for i in 0..<(planes.width * planes.height) {
            let r = planes.rgb[i * 3]
            let g = planes.rgb[i * 3 + 1]
            let b = planes.rgb[i * 3 + 2]
            if r > 150 && g < 90 && b < 90 { n += 1 }
        }
        return n
    }

    private func planes(_ data: Data) throws -> ImageSource.RGBAPlanes {
        guard let p = try ImageSource.make(from: data).renderRGBAPlanes() else {
            throw WatermarkError.invalidImageData
        }
        return p
    }

    // MARK: - 颜色

    func testTextColorAffectsImageOutput() throws {
        let png = try whitePNG()
        var config = baseConfig()
        config.text.color = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let out = try ImagePipeline(config: config).process(data: png)
        XCTAssertGreaterThan(redPixels(in: try planes(out.data)), 200, "红色文字应渲染出红色像素")
    }

    func testTextColorAffectsPDFOutput() throws {
        var config = baseConfig()
        config.text.color = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        config.layout.opacity = 1

        let pdf = try makePDF()
        let document = try PDFRawDocument(data: pdf)
        let result = try PDFIncrementalWriter(document: document, config: config).process()

        guard let raw = renderPDFPage(result.data, width: 500) else {
            return XCTFail("渲染失败")
        }
        var n = 0
        let pixels = raw.count / 4
        for i in 0..<pixels where raw[i * 4] > 150 && raw[i * 4 + 1] < 90 && raw[i * 4 + 2] < 90 { n += 1 }
        XCTAssertGreaterThan(n, 100, "PDF 里的红色水印应渲染出红色像素，实际 \(n)")
    }

    // MARK: - 描边颜色

    func testStrokeColorAffectsImageOutput() throws {
        let png = try whitePNG()
        var plain = baseConfig()
        plain.text.strokeWidth = 3
        plain.text.strokeColor = RGBAColor(red: 0, green: 0, blue: 1, alpha: 1)

        let out = try ImagePipeline(config: plain).process(data: png)
        let p = try planes(out.data)
        var blue = 0
        for i in 0..<(p.width * p.height) {
            if p.rgb[i * 3] < 90 && p.rgb[i * 3 + 1] < 90 && p.rgb[i * 3 + 2] > 150 { blue += 1 }
        }
        XCTAssertGreaterThan(blue, 100, "描边颜色应当生效")
    }

    // MARK: - 行距（当前 UI 没有入口，但渲染要支持）

    func testLineSpacingAffectsOutput() throws {
        let png = try whitePNG()
        var tight = baseConfig()
        tight.text.content = "第一行\n第二行"
        tight.text.lineSpacing = 1.0

        var loose = tight
        loose.text.lineSpacing = 3.0

        let a = try ImagePipeline(config: tight).process(data: png)
        let b = try ImagePipeline(config: loose).process(data: png)
        XCTAssertNotEqual(a.data, b.data, "行距变化应当改变渲染结果")
    }

    // MARK: - 指定页范围

    func testCustomPageRangeIsRespected() throws {
        let pdf = try makePDF(pageCount: 4)
        var config = baseConfig()
        config.pdf.pageRange = .custom(indices: [2, 4])

        let document = try PDFRawDocument(data: pdf)
        let result = try PDFIncrementalWriter(document: document, config: config).process()
        XCTAssertEqual(result.watermarkedPages, 2)
        XCTAssertEqual(result.pageCount, 4)
    }

    // MARK: - 页码表达式解析

    func testPageSpecParsing() {
        XCTAssertEqual(PDFPageRange.parse("1,3,5-9"), [1, 3, 5, 6, 7, 8, 9])
        XCTAssertEqual(PDFPageRange.parse("2"), [2])
        XCTAssertEqual(PDFPageRange.parse("1-3, 5"), [1, 2, 3, 5])
        XCTAssertEqual(PDFPageRange.parse(""), [])
        XCTAssertEqual(PDFPageRange.parse("abc"), [])
        XCTAssertEqual(PDFPageRange.parse("3-1"), [], "区间倒置应被忽略")
        XCTAssertEqual(PDFPageRange.parse("0,-2"), [1, 2], "越界页码应被收敛到合法范围")
    }

    // MARK: - 辅助

    private func makePDF(pageCount: Int = 1) throws -> Data {
        let mutable = NSMutableData()
        var rect = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: mutable as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &rect, nil) else {
            throw WatermarkError.malformedPDF("无法创建 PDF")
        }
        for i in 1...pageCount {
            ctx.beginPage(mediaBox: &rect)
            let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: "第 \(i) 页", attributes: [.font: font])
            )
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPage()
        }
        ctx.closePDF()
        return mutable as Data
    }

    private func renderPDFPage(_ data: Data, width: Int) -> [UInt8]? {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0 else { return nil }
        let height = Int(box.height / box.width * Double(width))
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &raw, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: Double(width) / box.width, y: Double(height) / box.height)
        page.draw(with: .mediaBox, to: ctx)
        return raw
    }
}
