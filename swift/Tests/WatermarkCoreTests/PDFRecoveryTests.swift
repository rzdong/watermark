import XCTest
import CoreGraphics
import Foundation
@testable import WatermarkCore

/// 回归：xref 损坏时的兜底重建能力
final class PDFRecoveryTests: XCTestCase {

    func testRecoversWhenStartXrefIsBroken() throws {
        let original = try makePDF(pageCount: 3)

        let healthy = try PDFRawDocument(data: original)
        XCTAssertEqual(try healthy.pages().count, 3)

        // 把 startxref 改成一个越界值，模拟文件尾部损坏
        var broken = original
        guard let range = broken.range(of: Data("startxref".utf8), options: .backwards),
              let lineEnd = broken[range.upperBound...].firstIndex(of: 0x0A) else {
            return XCTFail("样本里找不到 startxref")
        }
        broken.replaceSubrange(range.upperBound..<lineEnd, with: Data("99999999".utf8))

        let recovered = try PDFRawDocument(data: broken)
        let pages = try recovered.pages()
        XCTAssertFalse(pages.isEmpty, "startxref 损坏时必须能靠扫描重建，而不是直接失败")
        XCTAssertEqual(pages.count, 3)
    }

    func testRecoversWhenXrefTableIsGarbage() throws {
        let original = try makePDF(pageCount: 2)

        // 把 startxref 指向的位置整段涂掉
        var broken = original
        guard let range = broken.range(of: Data("startxref".utf8), options: .backwards),
              let lineEnd = broken[range.upperBound...].firstIndex(of: 0x0A) else {
            return XCTFail("样本里找不到 startxref")
        }
        broken.replaceSubrange(range.upperBound..<lineEnd, with: Data("0".utf8))

        let recovered = try PDFRawDocument(data: broken)
        XCTAssertFalse(try recovered.pages().isEmpty, "xref 全坏时仍应尽力恢复")
    }

    func testStillFailsClearlyOnNonPDF() {
        let junk = Data("这根本不是一个 PDF 文件，随便写点内容。".utf8)
        XCTAssertThrowsError(try PDFRawDocument(data: junk), "非 PDF 必须明确报错，不能静默产出空文档")
    }

    // MARK: - 辅助

    private func makePDF(pageCount: Int) throws -> Data {
        let mutable = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 500)
        guard let consumer = CGDataConsumer(data: mutable as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw WatermarkError.writeFailed("无法建立 PDF context")
        }
        for i in 0..<pageCount {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 20, width: 100, height: 30))
            ctx.endPDFPage()
            _ = i
        }
        ctx.closePDF()
        return mutable as Data
    }
}
