import XCTest
import Foundation
@testable import WatermarkCore

/// 回归：zlib 编解码。
///
/// 这里锁住两个真实踩过的坑：
/// 1. `(NSData).decompressed(using: .zlib)` 对大量真实 PDF 的标准 zlib 流一律返回 nil。
/// 2. `compression_decode_buffer` 解的是**裸 deflate**，直接喂带头的 zlib 会把 2 字节头
///    当成数据吃掉，产出错误的短结果（实测 333 字节的输入应得 576 字节，却得到 328 字节垃圾），
///    表现为「xref stream 解压失败」，整份 PDF 打不开。
final class CodecTests: XCTestCase {

    /// 由 `zlib.compress(..., 9)` 生成的真实标准 zlib 容器（带 78 da 头）
    private let standardZlibHex =
        "78da0b4f2c492dca4d2cca56a8284a4d53282e294a4dcc5528492d2e5148492c495430343236313533b7b034" +
        "50484c4a4e494d4bcfc8cccacec9cdcb2f000072ed149f"
    private let expectedPlain = "Watermark xref stream test data 1234567890 abcdefghijklmnop"

    func testInflatesStandardZlibContainer() throws {
        let compressed = try XCTUnwrap(Data(hexString: standardZlibHex))
        let decoded = try XCTUnwrap(PDFCodec.inflate(compressed), "标准 zlib 必须能解开")
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), expectedPlain)
        // 关键断言：长度必须对。错位解压会得到明显更短的垃圾数据
        XCTAssertEqual(decoded.count, expectedPlain.utf8.count)
    }

    func testDeflateProducesStandardZlibHeader() {
        let original = Data(expectedPlain.utf8)
        let compressed = PDFCodec.deflate(original)
        XCTAssertEqual(compressed.first, 0x78, "必须是 RFC 1950 的 zlib 容器头，裸 deflate 会让 PDFKit 解不开")
        // (CMF<<8 | FLG) 必须能被 31 整除
        let check = (Int(compressed[0]) << 8) | Int(compressed[1])
        XCTAssertEqual(check % 31, 0, "zlib 头的 FLG 校验位不对")
    }

    func testRoundTrip() {
        let samples: [Data] = [
            Data(expectedPlain.utf8),
            Data(repeating: 0x41, count: 10_000),
            Data((0..<5000).map { UInt8($0 % 251) })
        ]
        for original in samples {
            let compressed = PDFCodec.deflate(original)
            XCTAssertLessThan(compressed.count, original.count + 64, "压缩应当有效")
            guard let decoded = PDFCodec.inflate(compressed) else {
                return XCTFail("往返解压失败")
            }
            XCTAssertEqual(decoded, original, "往返后必须逐字节一致")
        }
    }

    func testInflateHandlesEmptyAndRawDeflate() {
        XCTAssertEqual(PDFCodec.inflate(Data()) ?? Data(), Data(), "空数据不应崩溃")
        // 裸 deflate（无 zlib 头）也要能兜住
        let compressed = PDFCodec.deflate(Data(expectedPlain.utf8))
        let stripped = compressed.dropFirst(2).dropLast(4)
        XCTAssertNotNil(PDFCodec.inflate(Data(stripped)), "少数文件缺 zlib 头，应退化为裸 deflate")
    }
}

private extension Data {
    init?(hexString: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
