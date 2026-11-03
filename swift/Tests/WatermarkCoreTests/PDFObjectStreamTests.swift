import XCTest
import Foundation
@testable import WatermarkCore

/// 回归：xref 里 type=2 的条目指向「对象流中的第 N 个」，而不是对象号本身。
///
/// 曾经按对象号建表却用序号去取，结果只有序号恰好等于某个对象号时才命中，
/// 且取到的是**错误对象**的内容——真实表现是一份 10 页的合同只有 1 页被加水印。
/// 现代 PDF 广泛使用对象流，这个 bug 影响面很大。
final class PDFObjectStreamTests: XCTestCase {

    func testPagesInsideObjectStreamAreAllFound() throws {
        let data = try makePDFWithObjectStream(pageCount: 4)
        let doc = try PDFRawDocument(data: data)
        let pages = try doc.pages()

        XCTAssertEqual(pages.count, 4, "对象流里的 4 个页对象必须全部被找到")
        // 每一页都要能拿到 MediaBox，说明取到的是真正的页对象而非错位的其他对象
        for page in pages {
            XCTAssertGreaterThan(page.mediaBox.width, 0)
            XCTAssertGreaterThan(page.mediaBox.height, 0)
        }
        // 页对象号与顺序都必须和 /Kids 一致（构造时用的是 3,5,7,9）
        XCTAssertEqual(pages.map { $0.objectNumber }, [3, 5, 7, 9])
    }

    func testWatermarkReachesEveryPageOfObjectStreamPDF() throws {
        let data = try makePDFWithObjectStream(pageCount: 3)
        let url = URL(fileURLWithPath: "/tmp/wm_objstm_sample.pdf")
        try data.write(to: url)

        var config = WatermarkConfig()
        config.text.content = "机密"
        let result = try WatermarkProcessor(config: config).process(fileAt: url)
        XCTAssertTrue(result.detail.contains("水印 3 页"), "3 页应全部加水印，实际：\(result.detail)")
        XCTAssertEqual(result.data.prefix(data.count), data, "原文件字节必须完整保留")
    }

    // MARK: - 构造样本

    /// 造一个「页对象全部放在对象流里、用 xref stream 索引」的 PDF。
    /// 系统 API（Quartz / PDFKit）都不会产出对象流，只能手工构造。
    private func makePDFWithObjectStream(pageCount: Int) throws -> Data {
        var body = Data()
        body.append(contentsOf: "%PDF-1.5\n".utf8)

        // 对象 1：Catalog；对象 2：Pages 节点
        var offsets: [Int: Int] = [:]
        let pageNumbers = (0..<pageCount).map { 3 + $0 * 2 }   // 3,5,7... 页对象号
        let kids = pageNumbers.map { "\($0) 0 R" }.joined(separator: " ")

        offsets[1] = body.count
        body.append(contentsOf: "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n".utf8)

        offsets[2] = body.count
        body.append(contentsOf: "2 0 obj\n<< /Type /Pages /Kids [\(kids)] /Count \(pageCount) >>\nendobj\n".utf8)

        // 对象流：装下所有页对象
        let pageBody = "<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 400]>>"
        let pageBodyLength = pageBody.utf8.count
        var header = ""
        var contents = ""
        for (index, number) in pageNumbers.enumerated() {
            header += "\(number) \(index * pageBodyLength) "
            contents += pageBody
        }
        header += "\n"
        let payload = Data((header + contents).utf8)
        let compressedPayload = PDFCodec.deflate(payload)
        let first = header.utf8.count

        let streamNumber = 1000
        offsets[streamNumber] = body.count
        body.append(contentsOf: "\(streamNumber) 0 obj\n".utf8)
        body.append(contentsOf: "<< /Type /ObjStm /N \(pageCount) /First \(first) /Filter /FlateDecode /Length \(compressedPayload.count) >>\nstream\n".utf8)
        body.append(compressedPayload)
        body.append(contentsOf: "\nendstream\nendobj\n".utf8)

        // xref stream：页对象用 type=2 指向对象流，其余用 type=1 指向文件偏移
        let xrefNumber = 1001
        let xrefOffset = body.count
        let maxObject = max(pageNumbers.max() ?? 0, xrefNumber) + 1

        var rows = Data()
        func appendRow(type: Int, field2: Int, field3: Int) {
            rows.append(UInt8(type))
            for shift in stride(from: 24, through: 0, by: -8) {
                rows.append(UInt8((field2 >> shift) & 0xFF))
            }
            for shift in stride(from: 8, through: 0, by: -8) {
                rows.append(UInt8((field3 >> shift) & 0xFF))
            }
        }
        for number in 0..<maxObject {
            if let order = pageNumbers.firstIndex(of: number) {
                appendRow(type: 2, field2: streamNumber, field3: order)
            } else if let offset = offsets[number] {
                appendRow(type: 1, field2: offset, field3: 0)
            } else if number == xrefNumber {
                appendRow(type: 1, field2: xrefOffset, field3: 0)
            } else {
                appendRow(type: 0, field2: 0, field3: 65535)
            }
        }
        let compressedRows = PDFCodec.deflate(rows)

        body.append(contentsOf: "\(xrefNumber) 0 obj\n".utf8)
        body.append(contentsOf: "<< /Type /XRef /Size \(maxObject) /Root 1 0 R /W [1 4 2] /Filter /FlateDecode /Length \(compressedRows.count) >>\nstream\n".utf8)
        body.append(compressedRows)
        body.append(contentsOf: "\nendstream\nendobj\n".utf8)
        body.append(contentsOf: "startxref\n\(xrefOffset)\n%%EOF\n".utf8)
        return body
    }
}
