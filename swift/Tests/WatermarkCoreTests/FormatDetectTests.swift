import XCTest
import CoreGraphics
import ImageIO
@testable import WatermarkCore

final class FormatDetectTests: XCTestCase {

    // MARK: - 样本

    private func writeTemp(_ name: String, _ data: Data) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        try data.write(to: url)
        return url
    }

    private func pngData() throws -> Data {
        var raw = [UInt8](repeating: 255, count: 60 * 60 * 4)
        guard let ctx = CGContext(
            data: &raw, width: 60, height: 60, bitsPerComponent: 8,
            bytesPerRow: 240, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage() else { throw WatermarkError.invalidImageData }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func pdfData() throws -> Data {
        let mutable = NSMutableData()
        var rect = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let consumer = CGDataConsumer(data: mutable as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &rect, nil) else {
            throw WatermarkError.malformedPDF("无法创建 PDF")
        }
        ctx.beginPage(mediaBox: &rect)
        ctx.endPage()
        ctx.closePDF()
        return mutable as Data
    }

    // MARK: - 测试

    func testSupportedFormatsAreAccepted() throws {
        XCTAssertEqual(WatermarkProcessor.kind(of: try writeTemp("wm_ok.png", pngData())), .image)
        XCTAssertEqual(WatermarkProcessor.kind(of: try writeTemp("wm_ok.pdf", pdfData())), .pdf)
    }

    /// ImageIO 会对任意二进制都创建出 source，必须靠类型与帧数把它挡掉
    func testUnsupportedFormatsAreRejected() throws {
        let cases: [(String, Data)] = [
            // zip 头 PK\x03\x04
            ("wm_bad.zip", Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 7, count: 200)),
            // 磁盘镜像常见魔数 koly
            ("wm_bad.dmg", Data("koly".utf8) + Data(repeating: 3, count: 200)),
            ("wm_bad.txt", Data("就是一段普通文本，不是图片也不是 PDF".utf8)),
            ("wm_bad.docx", Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 1, count: 300)),
            ("wm_bad.bin", Data(repeating: 0xAB, count: 500)),
            ("wm_bad", Data(repeating: 9, count: 100))
        ]
        for (name, data) in cases {
            let url = try writeTemp(name, data)
            XCTAssertEqual(
                WatermarkProcessor.kind(of: url), .unsupported,
                "\(name) 不应被当成可处理文件"
            )
        }
    }

    /// 真实文件回归：本工程自己打出来的 DMG 必须被拒
    func testRealDMGIsRejected() {
        let url = URL(fileURLWithPath: "/Users/adong/WorkBuddy/水印/swift/dist/Watermark.dmg")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        XCTAssertEqual(WatermarkProcessor.kind(of: url), .unsupported, "DMG 必须被拒绝")
    }
}
