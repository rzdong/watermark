import XCTest
import CoreGraphics
import ImageIO
@testable import WatermarkCore

final class ImagePipelineTests: XCTestCase {

    // MARK: - 样本

    private func makeSourceImage(width: Int = 400, height: Int = 300) throws -> CGImage {
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            raw[i * 4] = UInt8(i % 256)
            raw[i * 4 + 1] = 80
            raw[i * 4 + 2] = 160
            raw[i * 4 + 3] = 255
        }
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
        return image
    }

    private func encode(_ image: CGImage, uti: String, quality: CGFloat? = nil, properties: [CFString: Any] = [:]) throws -> Data {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, uti as CFString, 1, nil) else {
            throw WatermarkError.invalidImageData
        }
        var options = properties
        if let quality {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw WatermarkError.writeFailed("编码失败")
        }
        return out as Data
    }

    private func makeTextConfig() -> WatermarkConfig {
        var config = WatermarkConfig()
        config.text.content = "测试水印"
        config.layout.tiling = true
        config.layout.opacity = 0.3
        return config
    }

    // MARK: - 测试

    func testPNGStaysPNGWithSamePixelSize() throws {
        let image = try makeSourceImage()
        let png = try encode(image, uti: "public.png")
        let result = try ImagePipeline(config: makeTextConfig()).process(data: png)

        XCTAssertEqual(result.uti, "public.png", "PNG 进去必须 PNG 出来")
        XCTAssertTrue(result.isLossless)
        let output = try ImageSource.make(from: result.data)
        XCTAssertEqual(output.pixelSize, CGSize(width: 400, height: 300))
        XCTAssertEqual(output.cgImage.bitsPerComponent, image.bitsPerComponent)
    }

    func testMetadataIsCarriedOver() throws {
        let image = try makeSourceImage()
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "TestCamera" as CFString,
                kCGImagePropertyTIFFModel: "Model-X" as CFString
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "24-70mm" as CFString
            ]
        ]
        let png = try encode(image, uti: "public.png", properties: properties)

        let result = try ImagePipeline(config: makeTextConfig()).process(data: png)
        let output = try ImageSource.make(from: result.data)

        let tiff = output.properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake as String] as? String, "TestCamera")
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel as String] as? String, "Model-X")

        let exif = output.properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifLensModel as String] as? String, "24-70mm")
    }

    func testJPEGStaysJPEG() throws {
        let image = try makeSourceImage()
        let jpeg = try encode(image, uti: "public.jpeg", quality: 0.75)
        let result = try ImagePipeline(config: makeTextConfig()).process(data: jpeg)

        XCTAssertEqual(result.uti, "public.jpeg")
        XCTAssertFalse(result.isLossless, "JPEG 无法做到数学无损，必须如实标注")
        let output = try ImageSource.make(from: result.data)
        XCTAssertEqual(output.pixelSize, CGSize(width: 400, height: 300))
    }

    func testJPEGQualityIsEstimatedFromOriginal() throws {
        let image = try makeSourceImage()
        // 高档位（>0.8）的量化表已趋近饱和（值几乎全为 1），
        // 单靠量化表无法区分 0.85 与 1.0，因此这里允许 0.3 的误差。
        // 低中档位是准确可用的，也正是代际损失最需要控制区间。
        for target in [0.4, 0.7, 0.95] {
            let jpeg = try encode(image, uti: "public.jpeg", quality: target)
            guard let estimated = JPEGQualityEstimator.estimate(from: jpeg) else {
                return XCTFail("无法反推质量档位（目标 \(target)）")
            }
            XCTAssertEqual(
                estimated, target, accuracy: 0.3,
                "反推的档位应接近原图档位（目标 \(target)，实际 \(estimated)）"
            )
        }
    }

    func testAnimatedImageIsRejected() throws {
        // 两帧的 PNG 序列，用来触发动图拒绝逻辑
        let image = try makeSourceImage()
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 2, nil) else {
            throw WatermarkError.invalidImageData
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw WatermarkError.writeFailed("编码失败")
        }

        do {
            _ = try ImagePipeline(config: makeTextConfig()).process(data: out as Data)
            XCTFail("动图应当被拒绝")
        } catch let error as WatermarkError {
            switch error {
            case .unsupportedFormat:
                break
            default:
                XCTFail("应当返回不支持格式，实际是 \(error)")
            }
        }
    }
}
