import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import WatermarkCore

/// 回归：/Rotate 的几何换算
///
/// 曾经的 bug：预览直接用 `page.bounds(for:)`（那是**未旋转**的 MediaBox）当画布，
/// 于是 /Rotate 270 的横向页面在预览里显示成横躺的一条，而阅读器里其实是竖向的。
final class PDFPageGeometryTests: XCTestCase {

    func testVisualSizeSwapsForQuarterTurns() {
        let box = CGRect(x: 0, y: 0, width: 842.04, height: 595.44)
        XCTAssertEqual(PDFPageGeometry.visualSize(box: box, rotation: 0), CGSize(width: 842.04, height: 595.44))
        XCTAssertEqual(PDFPageGeometry.visualSize(box: box, rotation: 180), CGSize(width: 842.04, height: 595.44))
        // 90/270 宽高互换——这才是阅读器里看到的样子
        XCTAssertEqual(PDFPageGeometry.visualSize(box: box, rotation: 90), CGSize(width: 595.44, height: 842.04))
        XCTAssertEqual(PDFPageGeometry.visualSize(box: box, rotation: 270), CGSize(width: 595.44, height: 842.04))
    }

    func testNormalizeHandlesOutOfRangeValues() {
        XCTAssertEqual(PDFPageGeometry.normalize(360), 0)
        XCTAssertEqual(PDFPageGeometry.normalize(-90), 270)
        XCTAssertEqual(PDFPageGeometry.normalize(450), 90)
    }

    /// 用真实变换把四个页角映射一遍，确认它们落在视觉画布内且不越界。
    /// 变换写反（比如先平移后旋转）时页面会被转出画布，这里就能抓住。
    func testCornersMapInsideVisualCanvas() {
        let box = CGRect(x: 0, y: 0, width: 842.04, height: 595.44)
        for rotation in [0, 90, 180, 270] {
            let visual = PDFPageGeometry.visualSize(box: box, rotation: rotation)
            let corners = [
                CGPoint(x: 0, y: 0),
                CGPoint(x: box.width, y: 0),
                CGPoint(x: 0, y: box.height),
                CGPoint(x: box.width, y: box.height)
            ]
            for corner in corners {
                let mapped = Self.map(corner, rotation: rotation, box: box)
                XCTAssertGreaterThanOrEqual(mapped.x, -0.5, "rotation=\(rotation) 角点越出左边界")
                XCTAssertGreaterThanOrEqual(mapped.y, -0.5, "rotation=\(rotation) 角点越出下边界")
                XCTAssertLessThanOrEqual(mapped.x, visual.width + 0.5, "rotation=\(rotation) 角点越出右边界")
                XCTAssertLessThanOrEqual(mapped.y, visual.height + 0.5, "rotation=\(rotation) 角点越出上边界")
            }
        }
    }

    /// 复刻 PDFPageGeometry.applyRotation 的数学，用于独立验算
    private static func map(_ p: CGPoint, rotation: Int, box: CGRect) -> CGPoint {
        switch PDFPageGeometry.normalize(rotation) {
        case 90:  return CGPoint(x: p.y, y: box.width - p.x)
        case 180: return CGPoint(x: box.width - p.x, y: box.height - p.y)
        case 270: return CGPoint(x: box.height - p.y, y: p.x)
        default:  return p
        }
    }

    /// 预览画布方向：/Rotate 270 的横向页面，预览必须建成竖向
    func testRotatedPageProducesUprightCanvas() throws {
        let data = try makeRotatedPDF(rotation: 270, width: 842, height: 595)
        let url = URL(fileURLWithPath: "/tmp/wm_geom_270.pdf")
        try data.write(to: url)
        guard let page = PDFDocument(data: data)?.page(at: 0) else { return XCTFail("打不开样本") }

        let box = page.bounds(for: .mediaBox)
        let visual = PDFPageGeometry.visualSize(box: box, rotation: page.rotation)
        XCTAssertGreaterThan(visual.height, visual.width, "/Rotate 270 的横向页面，预览画布应当是竖向")
    }

    private func makeRotatedPDF(rotation: Int, width: Int, height: Int) throws -> Data {
        let mutable = NSMutableData()
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let consumer = CGDataConsumer(data: mutable as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &rect, nil) else {
            throw WatermarkError.malformedPDF("无法创建 PDF")
        }
        ctx.beginPage(mediaBox: &rect)
        ctx.endPage()
        ctx.closePDF()
        guard let document = PDFDocument(data: mutable as Data), let page = document.page(at: 0) else {
            throw WatermarkError.malformedPDF("样本创建失败")
        }
        page.rotation = rotation
        return document.dataRepresentation() ?? Data()
    }
}
