import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import WatermarkCore

/// 用「真实渲染 + 像素比对」来验证肉眼可见的效果，补上纯结构断言覆盖不到的部分
final class RenderingTests: XCTestCase {

    // MARK: - 工具

    private func renderFirstPDFPage(_ data: Data, width: Int = 400) -> [UInt8]? {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0 else { return nil }
        let height = Int(box.height / box.width * Double(width))
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &raw,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: Double(width) / box.width, y: Double(height) / box.height)
        page.draw(with: .mediaBox, to: context)
        return raw
    }

    /// 非白像素占比，用来确认渲染确实产生了内容
    private func inkRatio(_ raw: [UInt8]) -> Double {
        guard !raw.isEmpty else { return 0 }
        let pixels = raw.count / 4
        var ink = 0
        for i in 0..<pixels where raw[i * 4] < 240 { ink += 1 }
        return Double(ink) / Double(pixels)
    }

    private func differenceRatio(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var different = 0
        let pixels = a.count / 4
        for i in 0..<pixels {
            if abs(Int(a[i * 4]) - Int(b[i * 4])) > 8 ||
               abs(Int(a[i * 4 + 1]) - Int(b[i * 4 + 1])) > 8 ||
               abs(Int(a[i * 4 + 2]) - Int(b[i * 4 + 2])) > 8 {
                different += 1
            }
        }
        return Double(different) / Double(pixels)
    }

    private func makePDF(pageCount: Int = 1) throws -> Data {
        let mutable = NSMutableData()
        var rect = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: mutable as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &rect, nil) else {
            throw WatermarkError.malformedPDF("无法创建测试 PDF")
        }
        for i in 1...pageCount {
            ctx.beginPage(mediaBox: &rect)
            let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: "原始内容 第 \(i) 页", attributes: [.font: font])
            )
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPage()
        }
        ctx.closePDF()
        return mutable as Data
    }

    private func makeWhitePNG(width: Int = 400, height: Int = 400) throws -> Data {
        var raw = [UInt8](repeating: 255, count: width * height * 4)
        guard let context = CGContext(
            data: &raw,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw WatermarkError.invalidImageData
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw WatermarkError.invalidImageData
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WatermarkError.invalidImageData }
        return out as Data
    }

    // MARK: - 测试

    /// Bug 4：导出后看不到水印。用渲染对比确认水印是否真的画上去了
    func testPDFWatermarkIsVisibleAfterExport() throws {
        let original = try makePDF(pageCount: 1)

        var config = WatermarkConfig()
        config.text.content = "机密 CONFIDENTIAL"
        config.layout.tiling = true
        config.layout.opacity = 0.6
        config.layout.scalePercent = 55

        let document = try PDFRawDocument(data: original)
        let result = try PDFIncrementalWriter(document: document, config: config).process()

        guard let before = renderFirstPDFPage(original),
              let after = renderFirstPDFPage(result.data) else {
            return XCTFail("无法渲染页面")
        }
        let inkBefore = inkRatio(before)
        let inkAfter = inkRatio(after)
        print("[dbg] 原文档墨迹比例 = \(inkBefore)，加水印后 = \(inkAfter)")
        XCTAssertGreaterThan(inkBefore, 0.001, "原 PDF 本身应当能渲染出内容，否则说明渲染函数有问题")
        let ratio = differenceRatio(before, after)
        XCTAssertGreaterThan(
            ratio, 0.01,
            "加水印后渲染结果应当与原图有明显差异（实际差异 \(ratio)）"
        )
    }

    /// 反复对同一份文件做增量更新（用户场景：输出再当输入）。
    /// 早期实现会在第二轮开始失效——同编号+版本的对象在文件里出现两次，阅读器会挑旧的。
    func testRepeatedIncrementalUpdatesKeepWorking() throws {
        var current = try makePDF(pageCount: 2)

        for round in 1...3 {
            var config = WatermarkConfig()
            config.text.content = "第 \(round) 轮"
            config.layout.tiling = true
            config.layout.opacity = 0.6
            config.layout.scalePercent = 55

            let document = try PDFRawDocument(data: current)
            let result = try PDFIncrementalWriter(document: document, config: config).process()

            XCTAssertEqual(
                result.data.prefix(current.count), current,
                "第 \(round) 轮：原文件字节必须逐字节保留"
            )
            XCTAssertEqual(result.pageCount, 2, "第 \(round) 轮：页数不应变化")

            guard let before = renderFirstPDFPage(current),
                  let after = renderFirstPDFPage(result.data) else {
                return XCTFail("第 \(round) 轮：渲染失败")
            }
            XCTAssertGreaterThan(
                differenceRatio(before, after), 0.01,
                "第 \(round) 轮：水印应当可见（差异 \(differenceRatio(before, after))）"
            )
            current = result.data
        }
    }

    /// Bug 1：文字上下颠倒。用「L」字验证——横笔在底部，墨迹应集中在下半部分
    func testTextWatermarkIsNotFlipped() throws {
        let png = try makeWhitePNG(width: 400, height: 400)

        var config = WatermarkConfig()
        config.text.content = "L"
        config.text.fontName = "Helvetica-Bold"
        config.text.fontSize = 120
        config.text.color = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
        config.layout.tiling = false
        config.layout.anchor = .center
        config.layout.opacity = 1
        config.layout.scalePercent = 40
        config.layout.rotationDegrees = 0

        let output = try ImagePipeline(config: config).process(data: png)
        let source = try ImageSource.make(from: output.data)
        guard let planes = source.renderRGBAPlanes() else {
            return XCTFail("无法读取输出像素")
        }

        let width = planes.width
        let height = planes.height
        var upper = 0
        var lower = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                // 白底上的深色墨迹
                if planes.rgb[i * 3] < 128 {
                    if y > height / 2 { upper += 1 } else { lower += 1 }
                }
            }
        }
        XCTAssertGreaterThan(upper + lower, 100, "应当画出了可见的墨迹")
        XCTAssertGreaterThan(
            lower, upper,
            "「L」的横笔在底部，下半部分墨迹应更多（上 \(upper) / 下 \(lower)）——若为下少上多即说明文字被翻转了"
        )
    }

    /// Bug 3：字号滑块应当真正改变水印大小
    func testFontSizeActuallyChangesWatermarkSize() throws {
        let png = try makeWhitePNG(width: 600, height: 600)

        func inkCount(fontSize: Double) throws -> Int {
            var config = WatermarkConfig()
            config.text.content = "测试"
            config.text.fontSize = fontSize
            config.text.color = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
            config.layout.tiling = false
            config.layout.opacity = 1
            config.layout.scalePercent = 30
            let output = try ImagePipeline(config: config).process(data: png)
            let planes = try ImageSource.make(from: output.data).renderRGBAPlanes()!
            var count = 0
            for i in 0..<(planes.width * planes.height) where planes.rgb[i * 3] < 128 { count += 1 }
            return count
        }

        let small = try inkCount(fontSize: 14)
        let large = try inkCount(fontSize: 56)
        XCTAssertGreaterThan(
            large, small * 2,
            "字号翻倍时墨迹面积应显著变大（14pt=\(small)，56pt=\(large)）"
        )
    }
}
