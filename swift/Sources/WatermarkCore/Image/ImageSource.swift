import Foundation
import CoreGraphics
import ImageIO

/// 解码后的图片及其原始属性。只读，不做任何重编码。
public struct ImageSource {
    public var cgImage: CGImage
    public var orientation: CGImagePropertyOrientation
    /// 完整的原始属性字典（EXIF / TIFF / GPS / IPTC / ICC 等）
    public var properties: [String: Any]
    public var utType: String?

    public var pixelSize: CGSize {
        CGSize(width: cgImage.width, height: cgImage.height)
    }

    /// 应用 EXIF 方向后的可视尺寸
    public var orientedPixelSize: CGSize {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: cgImage.height, height: cgImage.width)
        default:
            return pixelSize
        }
    }

    public static func make(from data: Data) throws -> ImageSource {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw WatermarkError.invalidImageData
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw WatermarkError.invalidImageData
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let raw = (props[kCGImagePropertyOrientation as String] as? Int) ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: UInt32(clamping: raw)) ?? .up
        return ImageSource(
            cgImage: image,
            orientation: orientation,
            properties: props,
            utType: CGImageSourceGetType(source) as String?
        )
    }

    /// 是否含有透明像素
    public var hasAlpha: Bool {
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }

    // MARK: - 像素展开

    /// 渲染为「未预乘 RGB + 独立 Alpha」的两块平面，尺寸已应用 EXIF 方向。
    /// 返回的尺寸为可视尺寸（方向为 5~8 时宽高互换）。
    public struct RGBAPlanes {
        public var rgb: [UInt8]
        public var alpha: [UInt8]
        public var width: Int
        public var height: Int
        public var hasAlpha: Bool
    }

    public func renderRGBAPlanes() -> RGBAPlanes? {
        let srcW = cgImage.width
        let srcH = cgImage.height
        guard srcW > 0, srcH > 0 else { return nil }

        let transposed: Bool
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            transposed = true
        default:
            transposed = false
        }
        let outW = transposed ? srcH : srcW
        let outH = transposed ? srcW : srcH

        var raw = [UInt8](repeating: 0, count: outW * outH * 4)
        guard let ctx = CGContext(
            data: &raw,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: outW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        applyOrientation(to: ctx, sourceWidth: srcW, sourceHeight: srcH, outputWidth: outW, outputHeight: outH)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))

        var rgb = [UInt8](repeating: 0, count: outW * outH * 3)
        var alpha = [UInt8](repeating: 0, count: outW * outH)
        var anyTransparent = false

        for i in 0..<(outW * outH) {
            let r = Int(raw[i * 4])
            let g = Int(raw[i * 4 + 1])
            let b = Int(raw[i * 4 + 2])
            let a = Int(raw[i * 4 + 3])
            if a < 255 { anyTransparent = true }
            if a > 0 {
                rgb[i * 3]     = UInt8(min(r * 255 / a, 255))
                rgb[i * 3 + 1] = UInt8(min(g * 255 / a, 255))
                rgb[i * 3 + 2] = UInt8(min(b * 255 / a, 255))
            }
            alpha[i] = UInt8(a)
        }

        return RGBAPlanes(rgb: rgb, alpha: alpha, width: outW, height: outH, hasAlpha: anyTransparent)
    }

    private func applyOrientation(
        to ctx: CGContext,
        sourceWidth: Int,
        sourceHeight: Int,
        outputWidth: Int,
        outputHeight: Int
    ) {
        let w = CGFloat(outputWidth)
        let h = CGFloat(outputHeight)
        switch orientation {
        case .up:
            break
        case .upMirrored:
            ctx.translateBy(x: w, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        case .down:
            ctx.translateBy(x: w, y: h)
            ctx.rotate(by: .pi)
        case .downMirrored:
            ctx.translateBy(x: 0, y: h)
            ctx.scaleBy(x: 1, y: -1)
        case .left:
            ctx.translateBy(x: 0, y: h)
            ctx.rotate(by: -.pi / 2)
        case .leftMirrored:
            ctx.translateBy(x: w, y: h)
            ctx.scaleBy(x: -1, y: 1)
            ctx.rotate(by: -.pi / 2)
        case .right:
            ctx.translateBy(x: w, y: 0)
            ctx.rotate(by: .pi / 2)
        case .rightMirrored:
            ctx.scaleBy(x: -1, y: 1)
            ctx.rotate(by: -.pi / 2)
        @unknown default:
            break
        }
    }
}
