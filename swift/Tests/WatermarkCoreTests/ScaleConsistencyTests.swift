import XCTest
import CoreGraphics
@testable import WatermarkCore

/// 预览用位图像素尺寸、导出用页面 pt 尺寸，两边的平铺结果必须一致
final class ScaleConsistencyTests: XCTestCase {

    func testTilingIsInvariantAcrossCanvasScales() throws {
        var config = WatermarkConfig()
        config.text.content = "已报销"
        config.layout.tiling = true

        let engine = WatermarkLayoutEngine(config: config)

        // 预览：位图像素；导出：页面 pt（醉烧串发票的实际尺寸）
        let previewSize = CGSize(width: 900, height: 600)
        let pageSize = CGSize(width: 595.2756, height: 396.8504)

        let previewTiles = try engine.tiles(canvasSize: previewSize)
        let pageTiles = try engine.tiles(canvasSize: pageSize)

        let previewRatio = (previewTiles.first?.size.width ?? 0) / previewSize.width
        let pageRatio = (pageTiles.first?.size.width ?? 0) / pageSize.width

        print("[scale] 预览 \(previewSize) → \(previewTiles.count) 块，占宽 \(String(format: "%.4f", previewRatio))")
        print("[scale] 页面 \(pageSize) → \(pageTiles.count) 块，占宽 \(String(format: "%.4f", pageRatio))")

        XCTAssertEqual(
            previewTiles.count, pageTiles.count,
            "同一份配置在不同画布尺度下，平铺块数应当一致，否则预览与导出观感会不一致"
        )
        XCTAssertEqual(
            previewRatio, pageRatio, accuracy: 0.001,
            "水印相对画布宽度的占比应当一致"
        )
    }
}
