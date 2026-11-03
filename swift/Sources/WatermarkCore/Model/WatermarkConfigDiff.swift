import Foundation

/// 一条配置差异，用于「恢复默认」前的前后对比
public struct WatermarkConfigChange: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let currentValue: String
    public let defaultValue: String

    public init(title: String, currentValue: String, defaultValue: String) {
        self.id = UUID()
        self.title = title
        self.currentValue = currentValue
        self.defaultValue = defaultValue
    }
}

/// 计算当前配置与默认配置的差异
public enum WatermarkConfigDiff {

    public static func changes(from current: WatermarkConfig) -> [WatermarkConfigChange] {
        let d = WatermarkConfig()
        var result: [WatermarkConfigChange] = []

        func add(_ title: String, _ a: String, _ b: String) {
            guard a != b else { return }
            result.append(WatermarkConfigChange(title: title, currentValue: a, defaultValue: b))
        }

        add("水印类型", kindName(current.kind), kindName(d.kind))

        // 文字与图片两组都要比：恢复默认会把两组一并重置，
        // 只比对当前生效类型的话，会漏掉另一组残留的改动
        add("文字内容", current.text.content, d.text.content)
        add("字体", current.text.fontName, d.text.fontName)
        add("字号", number(current.text.fontSize), number(d.text.fontSize))
        add("颜色", hex(current.text.color), hex(d.text.color))
        add("加粗", toggle(current.text.bold), toggle(d.text.bold))
        add("描边", number(current.text.strokeWidth), number(d.text.strokeWidth))
        add("描边颜色", hex(current.text.strokeColor), hex(d.text.strokeColor))
        add("字距", number(current.text.letterSpacing, digits: 2), number(d.text.letterSpacing, digits: 2))
        add("行距", number(current.text.lineSpacing, digits: 2), number(d.text.lineSpacing, digits: 2))

        add("水印图片",
            current.image.imageData.isEmpty ? "未选择" : "已选择",
            d.image.imageData.isEmpty ? "未选择" : "已选择")
        add("宽度占比", percent(current.image.scalePercent), percent(d.image.scalePercent))

        add("位置", anchorName(current.layout.anchor), anchorName(d.layout.anchor))
        add("旋转", degrees(current.layout.rotationDegrees), degrees(d.layout.rotationDegrees))
        add("大小占比", percent(current.layout.scalePercent), percent(d.layout.scalePercent))
        add("不透明度", number(current.layout.opacity, digits: 2), number(d.layout.opacity, digits: 2))
        add("边距", percent(current.layout.marginPercent), percent(d.layout.marginPercent))
        add("平铺", toggle(current.layout.tiling), toggle(d.layout.tiling))
        add("间距", number(current.layout.tileSpacing, digits: 1), number(d.layout.tileSpacing, digits: 1))
        add("错行", toggle(current.layout.staggerRows), toggle(d.layout.staggerRows))

        add("层级", placementName(current.pdf.placement), placementName(d.pdf.placement))
        add("页面范围", rangeName(current.pdf.pageRange), rangeName(d.pdf.pageRange))

        return result
    }

    // MARK: - 格式化

    private static func number(_ v: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f", v)
    }

    private static func percent(_ v: Double) -> String {
        "\(Int(v.rounded()))%"
    }

    private static func degrees(_ v: Double) -> String {
        "\(Int(v.rounded()))°"
    }

    private static func toggle(_ v: Bool) -> String {
        v ? "开" : "关"
    }

    private static func hex(_ c: RGBAColor) -> String {
        let r = Int(min(max(c.red, 0), 1) * 255)
        let g = Int(min(max(c.green, 0), 1) * 255)
        let b = Int(min(max(c.blue, 0), 1) * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func kindName(_ k: WatermarkKind) -> String {
        k == .text ? "文字" : "图片"
    }

    private static func anchorName(_ a: WatermarkAnchor) -> String {
        switch a {
        case .topLeft: return "左上"
        case .topCenter: return "上中"
        case .topRight: return "右上"
        case .middleLeft: return "左中"
        case .center: return "正中"
        case .middleRight: return "右中"
        case .bottomLeft: return "左下"
        case .bottomCenter: return "下中"
        case .bottomRight: return "右下"
        case .custom: return "自定义"
        }
    }

    private static func placementName(_ p: WatermarkPlacement) -> String {
        p == .above ? "内容之上" : "内容之下"
    }

    private static func rangeName(_ r: PDFPageRange) -> String {
        switch r {
        case .all: return "全部"
        case .first: return "仅首页"
        case .odd: return "奇数页"
        case .even: return "偶数页"
        case .custom(let indices): return "指定页 \(indices.count) 页"
        }
    }
}
