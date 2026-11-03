import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import WatermarkCore

/// PDF 的渲染顺序是「页面内容 → 注释」，注释永远盖在内容之上。
/// 页面自带 /Annots（图形水印、印章、批注）时，内容流水印会被完全遮住，
/// 必须把水印本身做成注释追加到 /Annots 末尾。
///
/// 注：这里只验证「走了哪条分支」。注释之间的实际叠加次序由阅读器决定，
/// 合成样本里 PDFKit 的表现与真实发票不一致，真实场景已人工验证可见。
final class AnnotationTests: XCTestCase {

    /// 大面积注释（如整页平铺的「下载次数」图形水印）会盖住内容流水印，必须走注释方案
    func testFullPageAnnotationUsesAnnotationAttachment() throws {
        let source = try makePDFWithAnnotation(covering: 1.0)
        let parsed = try PDFRawDocument(data: source)
        guard let before = try parsed.pages().first else { return XCTFail("无页面") }
        let beforeAnnots = annotationCount(of: before, document: parsed)
        let beforeContents = contentsCount(of: before)
        XCTAssertGreaterThan(beforeAnnots, 0, "样本页面应当带注释")

        var config = WatermarkConfig()
        config.text.content = "已报销"
        config.layout.tiling = true

        let result = try PDFIncrementalWriter(document: parsed, config: config).process()
        let reparsed = try PDFRawDocument(data: result.data)
        guard let after = try reparsed.pages().first else { return XCTFail("无页面") }

        XCTAssertEqual(
            annotationCount(of: after, document: reparsed), beforeAnnots + 1,
            "页面有注释时，水印应作为注释追加到 /Annots"
        )
        XCTAssertEqual(
            contentsCount(of: after), beforeContents,
            "走注释方案时不应改动 /Contents"
        )
    }

    /// 只占页面一小块的注释（如一枚签名域/印章）不该让整份文件改走稳定性较差的注释方案。
    /// 走内容流时水印仅在那枚印章的一小块被遮住，其余照常可见。
    func testSmallAnnotationStillUsesContentStream() throws {
        let source = try makePDFWithAnnotation(covering: 0.05)
        let parsed = try PDFRawDocument(data: source)
        guard let before = try parsed.pages().first else { return XCTFail("无页面") }
        let beforeAnnots = annotationCount(of: before, document: parsed)
        let beforeContents = contentsCount(of: before)

        var config = WatermarkConfig()
        config.text.content = "已报销"
        config.layout.tiling = true

        let result = try PDFIncrementalWriter(document: parsed, config: config).process()
        let reparsed = try PDFRawDocument(data: result.data)
        guard let after = try reparsed.pages().first else { return XCTFail("无页面") }

        XCTAssertEqual(
            annotationCount(of: after, document: reparsed), beforeAnnots,
            "注释只占很小一块时不应额外新增注释"
        )
        XCTAssertEqual(
            contentsCount(of: after), beforeContents + 1,
            "小注释场景应把水印追加到 /Contents"
        )
    }

    func testPageWithoutAnnotationUsesContentStream() throws {
        let base = try makePDF()
        var config = WatermarkConfig()
        config.text.content = "测试"
        config.layout.tiling = true

        let document = try PDFRawDocument(data: base)
        let result = try PDFIncrementalWriter(document: document, config: config).process()
        let reparsed = try PDFRawDocument(data: result.data)
        guard let page = try reparsed.pages().first else { return XCTFail("无页面") }

        XCTAssertNil(page.dictionary["Annots"], "原页面没注释时不应凭空创建注释")
        guard let contents = page.contents?.asArray else {
            return XCTFail("/Contents 应为数组")
        }
        XCTAssertGreaterThan(contents.count, 1, "水印流应追加到 /Contents")
    }

    // MARK: - 页面范围（曾导致「水印 0 页」却显示完成）

    func testEmptyCustomPageRangeMatchesAllPages() {
        let range = PDFPageRange.custom(indices: [])
        XCTAssertTrue(range.contains(pageIndex: 1, pageCount: 1), "未填页码时应按全部处理")
        XCTAssertTrue(range.contains(pageIndex: 3, pageCount: 5))
        XCTAssertTrue(range.displayName.contains("未填写"), "文案应提示未填写")
    }

    func testEvenRangeMatchesNothingOnSinglePageDocument() {
        // 单页文档选「偶数页」确实匹配不到——这正是之前水印 0 页的原因，
        // 现在 WatermarkProcessor 会对此抛错，而不是显示「完成」
        XCTAssertFalse(PDFPageRange.even.contains(pageIndex: 1, pageCount: 1))
    }

    // MARK: - 辅助

    private func makePDF() throws -> Data {
        let mutable = NSMutableData()
        var rect = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: mutable as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &rect, nil) else {
            throw WatermarkError.malformedPDF("无法创建 PDF")
        }
        ctx.beginPage(mediaBox: &rect)
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "原始内容", attributes: [.font: font])
        )
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPage()
        ctx.closePDF()
        return mutable as Data
    }

    /// - Parameter covering: 注释占据页面的比例。1.0 = 铺满整页，0.05 = 只有一小块
    private func makePDFWithAnnotation(covering: CGFloat) throws -> Data {
        let base = try makePDF()
        guard let document = PDFDocument(data: base), let page = document.page(at: 0) else {
            throw WatermarkError.malformedPDF("样本 PDF 创建失败")
        }
        let box = page.bounds(for: .mediaBox)
        let side = min(box.width, box.height) * covering
        let rect = CGRect(
            x: box.midX - side / 2,
            y: box.midY - side / 2,
            width: side,
            height: side
        )
        let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        annotation.color = NSColor.blue
        annotation.interiorColor = NSColor.blue
        page.addAnnotation(annotation)
        guard let data = document.dataRepresentation() else {
            throw WatermarkError.malformedPDF("无法导出带注释的 PDF")
        }
        return data
    }

    private func annotationCount(of page: PDFPageInfo, document: PDFRawDocument) -> Int {
        guard let value = page.dictionary["Annots"] else { return 0 }
        if let array = value.asArray { return array.count }
        // /Annots 也可能是指向数组的间接引用
        if let resolved = document.resolve(value), let array = resolved.asArray { return array.count }
        return 0
    }

    private func contentsCount(of page: PDFPageInfo) -> Int {
        if let array = page.contents?.asArray { return array.count }
        return page.contents == nil ? 0 : 1
    }
}
