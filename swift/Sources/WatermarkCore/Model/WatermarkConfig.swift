import Foundation
import CoreGraphics

// MARK: - 颜色

public struct RGBAColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)

    public var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

// MARK: - 二维点（避免依赖 CGPoint 的 Codable 实现）

public struct Point2D: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2D(x: 0, y: 0)
}

// MARK: - 水印类型

public enum WatermarkKind: String, Codable, CaseIterable, Sendable {
    case text
    case image
}

// MARK: - 文字水印

public struct TextWatermark: Codable, Equatable, Sendable {
    /// 水印文字，支持多行
    public var content: String = "机密文件"
    /// PostScript 名或字体全名，留空则用系统默认中文字体
    public var fontName: String = "PingFangSC-Regular"
    /// 基准字号（在 1000pt 参考画布下）
    public var fontSize: Double = 28
    public var color: RGBAColor = RGBAColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)
    /// 描边宽度，0 表示不描边。单位同基准字号
    public var strokeWidth: Double = 0
    public var strokeColor: RGBAColor = .white
    /// 字符间距，单位同基准字号
    public var letterSpacing: Double = 0
    /// 行距倍数
    public var lineSpacing: Double = 1.25
    public var bold: Bool = false

    public init() {}
}

// MARK: - 图片水印

public struct ImageWatermark: Codable, Equatable, Sendable {
    /// 原始图片字节（PNG / JPEG / TIFF 等，由 ImageIO 解码）
    public var imageData: Data = Data()
    /// 水印宽度占画布宽度的百分比
    public var scalePercent: Double = 25

    public init() {}
}

// MARK: - 位置锚点

public enum WatermarkAnchor: String, Codable, CaseIterable, Sendable {
    case topLeft
    case topCenter
    case topRight
    case middleLeft
    case center
    case middleRight
    case bottomLeft
    case bottomCenter
    case bottomRight
    case custom

    /// 在单位正方形（左下原点）中锚点对应的位置
    public var unitPoint: Point2D {
        switch self {
        case .topLeft:      return Point2D(x: 0, y: 1)
        case .topCenter:    return Point2D(x: 0.5, y: 1)
        case .topRight:     return Point2D(x: 1, y: 1)
        case .middleLeft:   return Point2D(x: 0, y: 0.5)
        case .center:       return Point2D(x: 0.5, y: 0.5)
        case .middleRight:  return Point2D(x: 1, y: 0.5)
        case .bottomLeft:   return Point2D(x: 0, y: 0)
        case .bottomCenter: return Point2D(x: 0.5, y: 0)
        case .bottomRight:  return Point2D(x: 1, y: 0)
        case .custom:       return Point2D(x: 0.5, y: 0.5)
        }
    }
}

// MARK: - 布局

public struct WatermarkLayout: Codable, Equatable, Sendable {
    public var anchor: WatermarkAnchor = .center
    /// 仅当 anchor 为 .custom 时生效，单位坐标（左下原点，相对画布）
    public var customPosition: Point2D = Point2D(x: 0.5, y: 0.5)
    /// 旋转角度，逆时针为正
    public var rotationDegrees: Double = 42
    /// 是否平铺
    public var tiling: Bool = true
    /// 平铺间距倍数（相对水印自身尺寸，1.0 表示紧贴）
    ///
    /// 1.6 时水印之间空出六成，整页只有稀稀拉拉几处，常被当成「没铺满」。
    /// 实测：0.9 虽然纵向更开，但整体观感反更稀疏；1.15 的包围盒最大（56%×42%），取它。
    public var tileSpacing: Double = 1.15
    /// 平铺时是否错行
    public var staggerRows: Bool = true
    /// 整体不透明度
    public var opacity: Double = 0.3
    /// 水印宽度占画布宽度的百分比
    public var scalePercent: Double = 28
    /// 边距占画布短边的百分比
    public var marginPercent: Double = 6

    public init() {}
}

// MARK: - PDF 专有选项

public enum WatermarkPlacement: String, Codable, CaseIterable, Sendable {
    /// 水印绘制在页面原有内容之上
    case above
    /// 水印绘制在页面原有内容之下
    case below
}

public enum PDFPageRange: Codable, Equatable, Sendable {
    case all
    case first
    case odd
    case even
    case custom(indices: [Int])   // 1-based 页码

    public func contains(pageIndex: Int, pageCount: Int) -> Bool {
        guard pageIndex >= 1, pageIndex <= pageCount else { return false }
        switch self {
        case .all:      return true
        case .first:    return pageIndex == 1
        case .odd:      return pageIndex % 2 == 1
        case .even:     return pageIndex % 2 == 0
        // 选了「指定页」却没填页码时按全部处理，否则整份文档一个水印都加不上
        case .custom(let indices): return indices.isEmpty ? true : indices.contains(pageIndex)
        }
    }

    /// 供界面与报错文案使用
    public var displayName: String {
        switch self {
        case .all: return "全部"
        case .first: return "仅首页"
        case .odd: return "奇数页"
        case .even: return "偶数页"
        case .custom(let indices):
            return indices.isEmpty
                ? "指定页（未填写页码）"
                : "指定页 \(indices.map(String.init).joined(separator: ","))"
        }
    }

    /// 解析页码表达式，支持 "1,3,5-9"、"2-"（到末页）、"-4"（从第 1 页起）
    public static func parse(_ text: String) -> [Int] {
        let upperLimit = 9999
        var result = Set<Int>()
        for chunk in text.split(separator: ",") {
            let part = chunk.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }

            // 先判区间：像 "-2" 表示「第 1 到 2 页」，不能当成负数单页
            if part.contains("-") {
                guard let dash = part.firstIndex(of: "-") else { continue }
                let left = String(part[part.startIndex..<dash]).trimmingCharacters(in: .whitespaces)
                let right = String(part[part.index(after: dash)...]).trimmingCharacters(in: .whitespaces)

                let low = left.isEmpty ? 1 : (Int(left) ?? 1)
                let high = right.isEmpty ? upperLimit : (Int(right) ?? upperLimit)
                guard low <= high else { continue }
                for page in max(low, 1)...min(high, upperLimit) { result.insert(page) }
                continue
            }

            if let single = Int(part) {
                if single >= 1, single <= upperLimit { result.insert(single) }
            }
        }
        return result.sorted()
    }
}

public struct PDFOptions: Codable, Equatable, Sendable {
    public var placement: WatermarkPlacement = .above
    public var pageRange: PDFPageRange = .all

    public init() {}
}

// MARK: - 总配置

public struct WatermarkConfig: Codable, Equatable, Sendable {
    public var kind: WatermarkKind = .text
    public var text: TextWatermark = TextWatermark()
    public var image: ImageWatermark = ImageWatermark()
    public var layout: WatermarkLayout = WatermarkLayout()
    public var pdf: PDFOptions = PDFOptions()

    public init() {}

    /// 水印宽度占画布宽度的比例（考虑类型各自的默认值来源）
    public var effectiveScalePercent: Double {
        kind == .text ? layout.scalePercent : image.scalePercent
    }
}
