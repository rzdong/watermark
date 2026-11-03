import XCTest
import CoreGraphics
@testable import WatermarkCore

/// 回归：PDFPage.draw(with:to:) 会把 context 的 textMatrix 留在页面最后一次 Tm 的状态。
/// CTLineDraw 依赖 textMatrix，若不重置，水印会被放大并整体偏移，
/// 表现为「预览里文字重叠、偏大」，而 PDF 导出走矢量路径不受影响——预览与导出对不上。
final class TextMatrixTests: XCTestCase {

    func testWatermarkIsIdenticalWhenTextMatrixIsPolluted() throws {
        var config = WatermarkConfig()
        config.text.content = "榴莲"
        config.layout.tiling = true

        let clean = try renderWatermark(config, polluteTextMatrix: false)
        let polluted = try renderWatermark(config, polluteTextMatrix: true)

        XCTAssertEqual(
            difference(clean, polluted), 0,
            "textMatrix 被污染时水印渲染结果必须完全一致，否则预览会与导出对不上"
        )
    }

    func testWatermarkIsNotBlankWhenTextMatrixIsPolluted() throws {
        var config = WatermarkConfig()
        config.text.content = "榴莲"
        let polluted = try renderWatermark(config, polluteTextMatrix: true)
        var ink = 0
        for i in 0..<(polluted.count / 4) where polluted[i * 4] < 240 { ink += 1 }
        XCTAssertGreaterThan(ink, 100, "污染状态下仍必须画出可见水印")
    }

    // MARK: - 辅助

    /// 在白底画布上只画水印；polluteTextMatrix 模拟 PDFPage.draw 留下的脏 textMatrix
    private func renderWatermark(_ config: WatermarkConfig,
                                 polluteTextMatrix: Bool) throws -> [UInt8] {
        let w = 600, h = 400
        let bytes = w * h * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
        buffer.initialize(repeating: 255, count: bytes)
        defer { buffer.deallocate() }

        guard let ctx = CGContext(data: buffer, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw WatermarkError.writeFailed("无法建立 context")
        }
        // 真实发票（醉烧串）实测留下的就是这个量级的缩放与位移
        if polluteTextMatrix {
            ctx.textMatrix = CGAffineTransform(a: 3.175, b: 0, c: 0, d: 3.175, tx: 15.875, ty: -2.86)
        }
        try ImagePipeline.drawWatermark(config, in: ctx, canvasSize: CGSize(width: w, height: h))

        var raw = [UInt8](repeating: 255, count: bytes)
        raw.withUnsafeMutableBufferPointer { target in
            target.baseAddress?.update(from: buffer, count: bytes)
        }
        return raw
    }

    private func difference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        precondition(a.count == b.count)
        var n = 0
        for i in 0..<(a.count / 4) {
            if abs(Int(a[i * 4]) - Int(b[i * 4])) > 8 { n += 1 }
        }
        return n
    }
}
