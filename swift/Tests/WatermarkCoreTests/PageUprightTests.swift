import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import WatermarkCore

/// 回归：带 /Rotate 的页面会被「摆正」后再加水印
///
/// 之前靠补偿矩阵去猜阅读器的旋转，实测只能盖到一半（水印缩到右下一角）。
/// 现在改成先摆正页面——换 MediaBox、删 /Rotate、把原内容包进旋转变换——
/// 之后就是普通页面，水印自然铺满。这样也保住了文字层（不像打印成 PDF 会光栅化）。
final class PageUprightTests: XCTestCase {

    func testRotatedPageBecomesUpright() throws {
        let source = try makeRotatedPDF(rotation: 270, width: 842, height: 595)
        let url = URL(fileURLWithPath: "/tmp/wm_upright_270.pdf")
        try source.write(to: url)

        var config = WatermarkConfig()
        config.text.content = "机密"
        let result = try WatermarkProcessor(config: config).process(fileAt: url)

        guard let page = PDFDocument(data: result.data)?.page(at: 0) else {
            return XCTFail("输出无法打开")
        }
        XCTAssertEqual(page.rotation, 0, "摆正后页面不应再有 /Rotate")

        let box = page.bounds(for: .mediaBox)
        XCTAssertGreaterThan(box.height, box.width, "横向页面摆正后应当是竖向")
    }

    func testUprightPageGetsFullyCoveredWatermark() throws {
        let source = try makeRotatedPDF(rotation: 270, width: 842, height: 595)
        let url = URL(fileURLWithPath: "/tmp/wm_upright_cover.pdf")
        try source.write(to: url)

        var config = WatermarkConfig()
        config.text.content = "机密"
        config.layout.tiling = true
        let result = try WatermarkProcessor(config: config).process(fileAt: url)

        guard let page = PDFDocument(data: result.data)?.page(at: 0),
              let before = PDFDocument(data: source)?.page(at: 0) else {
            return XCTFail("样本处理失败")
        }
        guard let bounds = Self.inkBounds(after: page, before: before) else {
            return XCTFail("未检出水印墨迹")
        }
        XCTAssertGreaterThan(bounds.widthRatio, 0.9, "摆正后横向应基本铺满，实际 \(bounds.widthRatio)")
        XCTAssertGreaterThan(bounds.heightRatio, 0.8, "摆正后纵向应基本铺满，实际 \(bounds.heightRatio)")
    }

    func testUnrotatedPageIsLeftAlone() throws {
        let source = try makeRotatedPDF(rotation: 0, width: 595, height: 842)
        let url = URL(fileURLWithPath: "/tmp/wm_upright_none.pdf")
        try source.write(to: url)

        var config = WatermarkConfig()
        config.text.content = "机密"
        let result = try WatermarkProcessor(config: config).process(fileAt: url)

        guard let page = PDFDocument(data: result.data)?.page(at: 0) else {
            return XCTFail("输出无法打开")
        }
        // 没有 /Rotate 的页面不该被动到 MediaBox
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 595, accuracy: 1.0)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, 842, accuracy: 1.0)
    }

    // MARK: - 辅助

    private func makeRotatedPDF(rotation: Int, width: Int, height: Int) throws -> Data {
        let mutable = NSMutableData()
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let consumer = CGDataConsumer(data: mutable as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &rect, nil) else {
            throw WatermarkError.malformedPDF("无法创建 PDF")
        }
        ctx.beginPage(mediaBox: &rect)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Sample content", attributes: [.font: font])
        )
        ctx.textPosition = CGPoint(x: 40, y: height / 2)
        CTLineDraw(line, ctx)
        ctx.endPage()
        ctx.closePDF()
        guard let document = PDFDocument(data: mutable as Data), let page = document.page(at: 0) else {
            throw WatermarkError.malformedPDF("样本创建失败")
        }
        page.rotation = rotation
        return document.dataRepresentation() ?? Data()
    }

    private static func inkBounds(after: PDFPage, before: PDFPage) -> (widthRatio: Double, heightRatio: Double)? {
        guard let a = render(after), let b = render(before), a.0.count == b.0.count else { return nil }
        let w = a.1, h = a.2
        var minX = w, maxX = 0, minY = h, maxY = 0, n = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let o = Int(b.0[i]) + Int(b.0[i+1]) + Int(b.0[i+2])
                let m = Int(a.0[i]) + Int(a.0[i+1]) + Int(a.0[i+2])
                if o - m > 20 {
                    n += 1
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard n > 0 else { return nil }
        return (Double(maxX - minX) / Double(w), Double(maxY - minY) / Double(h))
    }

    private static func render(_ page: PDFPage) -> ([UInt8], Int, Int)? {
        let mb = page.bounds(for: .mediaBox)
        let w = Int(mb.width), h = Int(mb.height)
        guard w > 0, h > 0 else { return nil }
        let bytes = w * h * 4
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
        buf.initialize(repeating: 255, count: bytes)
        guard let ctx = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            buf.deallocate(); return nil
        }
        page.draw(with: .mediaBox, to: ctx)
        var out = [UInt8](repeating: 255, count: bytes)
        out.withUnsafeMutableBufferPointer { $0.baseAddress?.update(from: buf, count: bytes) }
        buf.deallocate()
        return (out, w, h)
    }
}
