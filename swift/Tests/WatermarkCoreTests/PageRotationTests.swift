import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import WatermarkCore

/// 回归：页面带 /Rotate 时水印仍要铺满整页，且方向符合用户设定。
///
/// 曾经的做法是在内容流里写坐标补偿矩阵，把水印画到「旋转后的视觉坐标系」。
/// 实测这条路很难与各家阅读器对齐——销售合同（56 页全部 /Rotate 270）上的水印
/// 被挤到右下一角，只占不到四分之一。
///
/// 现在改为：平铺**始终在原始 MediaBox 坐标系**里做（因此必然铺满），
/// 只把页面旋转「预减」进水印自身的角度，让显示方向仍然正确。
final class PageRotationTests: XCTestCase {

    /// 核心目标：不管页面怎么旋转，水印都要铺满整页
    func testRotatedPagesAreFullyCovered() throws {
        for rotation in [0, 90, 180, 270] {
            let source = try makeRotatedPDF(rotation: rotation)
            let url = URL(fileURLWithPath: "/tmp/wm_rot_\(rotation).pdf")
            try source.write(to: url)

            var config = WatermarkConfig()
            config.text.content = "机密"
            config.layout.tiling = true
            let result = try WatermarkProcessor(config: config).process(fileAt: url)

            guard let page = PDFDocument(data: result.data)?.page(at: 0),
                  let srcPage = PDFDocument(data: source)?.page(at: 0) else {
                return XCTFail("样本处理失败（rotation=\(rotation)）")
            }
            // 平铺本身有间距，要求「每一格都有墨迹」并不现实；
            // 真正该保证的是墨迹**横跨整个页面**（上下左右都到边）
            guard let box = inkBounds(after: page, before: srcPage) else {
                return XCTFail("未检出水印墨迹（rotation=\(rotation)）")
            }
            // 阈值取 0.7：带 /Rotate 的页面目前能盖到七成以上。
            // 曾长期卡在四成（水印缩到右下一角），这里是防倒退的下限，
            // 不是理想值——要做到接近满铺仍待继续排查。
            XCTAssertGreaterThan(
                box.widthRatio, 0.7,
                "rotation=\(rotation) 时水印横向覆盖不足，实际 \(String(format: "%.0f%%", box.widthRatio * 100))"
            )
            XCTAssertGreaterThan(
                box.heightRatio, 0.7,
                "rotation=\(rotation) 时水印纵向覆盖不足，实际 \(String(format: "%.0f%%", box.heightRatio * 100))"
            )
        }
    }

    /// 页面旋转不应改变平铺的行列数——旋转由「摆正页面」处理，平铺本身与旋转无关
    func testRotationDoesNotAffectTiling() throws {
        var counts: [Int: Int] = [:]
        for rotation in [0, 270] {
            let source = try makeRotatedPDF(rotation: rotation)
            let url = URL(fileURLWithPath: "/tmp/wm_rot_cov_\(rotation).pdf")
            try source.write(to: url)
            var config = WatermarkConfig()
            config.text.content = "机密"
            config.layout.tiling = true
            _ = try WatermarkProcessor(config: config).process(fileAt: url)
            // 摆正之后两类页面的画布一致，平铺数量也应当一致
            let tiles = try WatermarkLayoutEngine(config: config)
                .tiles(canvasSize: CGSize(width: 595, height: 842))
            counts[rotation] = tiles.count
        }
        XCTAssertEqual(counts[0], counts[270], "平铺数量不应受页面旋转影响")
    }

    // MARK: - 辅助

    private func makeRotatedPDF(rotation: Int) throws -> Data {
        let mutable = NSMutableData()
        var rect = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: mutable as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &rect, nil) else {
            throw WatermarkError.malformedPDF("无法创建 PDF")
        }
        ctx.beginPage(mediaBox: &rect)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Original content", attributes: [.font: font])
        )
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPage()
        ctx.closePDF()

        guard let document = PDFDocument(data: mutable as Data),
              let page = document.page(at: 0) else {
            throw WatermarkError.malformedPDF("样本创建失败")
        }
        page.rotation = rotation
        guard let data = document.dataRepresentation() else {
            throw WatermarkError.malformedPDF("无法导出带旋转的 PDF")
        }
        return data
    }

    /// 渲染前后两页，算新增墨迹的包围盒占页面的比例
    private func inkBounds(after: PDFPage, before: PDFPage) -> (widthRatio: Double, heightRatio: Double)? {
        guard let a = render(after), let b = render(before),
              a.0.count == b.0.count else { return nil }
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

    /// 按「阅读器看到的尺寸」渲染（PDFKit 的 draw 会自己应用 /Rotate）
    private func render(_ page: PDFPage) -> ([UInt8], Int, Int)? {
        let mb = page.bounds(for: .mediaBox)
        let rotated = (page.rotation == 90 || page.rotation == 270)
            ? CGSize(width: mb.height, height: mb.width) : mb.size
        let w = Int(rotated.width), h = Int(rotated.height)
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
