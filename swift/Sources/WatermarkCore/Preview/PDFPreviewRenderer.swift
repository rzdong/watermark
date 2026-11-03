import Foundation
import CoreGraphics
import PDFKit
import AppKit

/// PDF 预览渲染。
///
/// 放在 Core 而不是 App 层，是为了能被测试直接验证——预览一旦和导出用不同的
/// 坐标系，就会出现「预览看着对、导出不对」这类最难查的问题。
public enum PDFPreviewRenderer {

    /// 渲染单页预览（含水印）。
    ///
    /// 画布按**阅读器看到的方向**建立（/Rotate 90/270 时宽高互换），
    /// 然后把坐标系旋回原始 MediaBox，页面内容与水印都在这一套坐标里绘制，
    /// 因此预览与导出的方向、密度天然一致。
    public static func render(
        page: PDFPage,
        config: WatermarkConfig,
        maxDimension: CGFloat = 900
    ) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }

        let visual = PDFPageGeometry.visualSize(box: box, rotation: page.rotation)
        let scale = min(1, maxDimension / max(visual.width, visual.height))
        let width = max(Int(visual.width * scale), 1)
        let height = max(Int(visual.height * scale), 1)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // 页面交给系统的 thumbnail 渲染。
        // 不要自己拼旋转变换再用 drawPDFPage——那里会和页面自带的 /Rotate 叠加成
        // 「双重旋转」，内容只占画布中间一条（实测左右各空掉三成以上）。
        // thumbnail 已正确处理 /Rotate，内容铺满画布。
        let image = page.thumbnail(
            of: NSSize(width: width, height: height),
            for: .mediaBox
        )
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // 直接绘制即可——thumbnail 产出的位图方向已经是对的，
            // 再手动翻转反而会上下颠倒
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        // 此时坐标系就是「看到的样子」，水印直接按视觉画布平铺，角度无需再补偿。
        // 与导出端（原始 MediaBox 坐标系 + 角度预减）呈现结果一致。
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        try? ImagePipeline.drawWatermark(
            config,
            in: context,
            canvasSize: visual
        )
        context.restoreGState()
        return context.makeImage()
    }
}
