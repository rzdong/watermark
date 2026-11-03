import XCTest
@testable import WatermarkCore

final class ConfigDiffTests: XCTestCase {

    func testDefaultConfigHasNoChanges() {
        let changes = WatermarkConfigDiff.changes(from: WatermarkConfig())
        XCTAssertTrue(changes.isEmpty, "默认配置不应列出任何差异，否则恢复按钮会被永久禁用")
    }

    func testChangedFieldIsReportedWithBeforeAndAfter() {
        var config = WatermarkConfig()
        config.text.content = "机密"
        config.layout.opacity = 0.6

        let changes = WatermarkConfigDiff.changes(from: config)
        let titles = changes.map { $0.title }

        XCTAssertTrue(titles.contains("文字内容"))
        XCTAssertTrue(titles.contains("不透明度"))

        let content = changes.first { $0.title == "文字内容" }!
        XCTAssertEqual(content.currentValue, "机密")
        XCTAssertEqual(content.defaultValue, "机密文件")

        let opacity = changes.first { $0.title == "不透明度" }!
        XCTAssertEqual(opacity.currentValue, "0.60")
        XCTAssertEqual(opacity.defaultValue, "0.30")
    }

    func testSwitchingKindReportsKindChange() {
        var config = WatermarkConfig()
        config.kind = .image
        config.image.imageData = Data([0x89, 0x50])

        let changes = WatermarkConfigDiff.changes(from: config)
        let titles = changes.map { $0.title }

        XCTAssertTrue(titles.contains("水印类型"))
        XCTAssertTrue(titles.contains("水印图片"))
        // 切到图片后不应再列文字专属项
        XCTAssertFalse(titles.contains("文字内容"))

        let image = changes.first { $0.title == "水印图片" }!
        XCTAssertEqual(image.currentValue, "已选择")
        XCTAssertEqual(image.defaultValue, "未选择")
    }

    func testEveryFieldIsCovered() {
        // 逐个字段改动，确保没有漏项（漏项会导致恢复后仍有残留差异）
        let expectations: [(String, (inout WatermarkConfig) -> Void)] = [
            ("水印类型", { $0.kind = .image }),
            ("文字内容", { $0.text.content = "X" }),
            ("字体", { $0.text.fontName = "Helvetica" }),
            ("字号", { $0.text.fontSize = 40 }),
            ("颜色", { $0.text.color = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1) }),
            ("加粗", { $0.text.bold = true }),
            ("描边", { $0.text.strokeWidth = 2 }),
            ("描边颜色", { $0.text.strokeColor = RGBAColor(red: 0, green: 1, blue: 0, alpha: 1) }),
            ("字距", { $0.text.letterSpacing = 0.2 }),
            ("行距", { $0.text.lineSpacing = 2 }),
            ("宽度占比", { $0.image.scalePercent = 40 }),
            ("位置", { $0.layout.anchor = .bottomRight }),
            ("旋转", { $0.layout.rotationDegrees = 45 }),
            ("大小占比", { $0.layout.scalePercent = 60 }),
            ("不透明度", { $0.layout.opacity = 0.8 }),
            ("边距", { $0.layout.marginPercent = 10 }),
            ("平铺", { $0.layout.tiling = false }),   // 默认为开，取反才有差异
            ("间距", { $0.layout.tileSpacing = 2.5 }),
            ("错行", { $0.layout.staggerRows = false }),
            ("层级", { $0.pdf.placement = .below }),
            ("页面范围", { $0.pdf.pageRange = .odd })
        ]

        for (title, mutate) in expectations {
            var config = WatermarkConfig()
            mutate(&config)
            let titles = WatermarkConfigDiff.changes(from: config).map { $0.title }
            XCTAssertTrue(titles.contains(title), "字段「\(title)」改动后未被列入差异")
        }
    }
}
