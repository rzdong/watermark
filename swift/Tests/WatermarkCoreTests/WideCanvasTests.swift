import XCTest
import CoreGraphics
@testable import WatermarkCore

final class WideCanvasTests: XCTestCase {

    /// 直接检查任意两块水印的旋转外接框是否相交
    func testNoOverlapAcrossCanvasShapes() throws {
        var config = WatermarkConfig()
        config.text.content = "机密文件"
        config.layout.tiling = true

        let canvases: [CGSize] = [
            CGSize(width: 595, height: 842),    // A4 纵向
            CGSize(width: 842, height: 595),    // A4 横向
            CGSize(width: 1400, height: 500),   // 宽发票
            CGSize(width: 2000, height: 300),   // 极端宽
            CGSize(width: 400, height: 1200)    // 窄长
        ]

        for canvas in canvases {
            let tiles = try WatermarkLayoutEngine(config: config).tiles(canvasSize: canvas)
            for i in 0..<tiles.count {
                for j in (i + 1)..<tiles.count {
                    let a = box(of: tiles[i])
                    let b = box(of: tiles[j])
                    if a.intersects(b) {
                        XCTFail("画布 \(canvas) 上第 \(i) 与第 \(j) 块重叠：\(a) / \(b)")
                        return
                    }
                }
            }
        }
    }

    private func box(of tile: WatermarkTile) -> CGRect {
        let c = abs(cos(tile.rotationRadians))
        let s = abs(sin(tile.rotationRadians))
        let w = tile.size.width * c + tile.size.height * s
        let h = tile.size.width * s + tile.size.height * c
        return CGRect(x: tile.center.x - w / 2, y: tile.center.y - h / 2, width: w, height: h)
    }
}
