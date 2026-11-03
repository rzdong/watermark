import Foundation

/// 从已有 JPEG 的量化表反推原始压缩档位。
///
/// JPEG 没有"质量"字段，只有量化表。重新编码时用回接近原图的档位，
/// 可以把二次压缩的代际损失压到最小（视觉无损，但不是数学无损）。
public enum JPEGQualityEstimator {

    /// Annex K.1 标准亮度量化表（zigzag 顺序）
    private static let standardLuminance: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61,
        12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77,
        24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99
    ]

    /// 返回 0.0~1.0 的质量档位，解析失败返回 nil
    public static func estimate(from data: Data) -> Double? {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }

        var i = 2
        while i + 3 < bytes.count {
            guard bytes[i] == 0xFF else { i += 1; continue }
            let marker = bytes[i + 1]

            // 无长度字段的独立标记
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
                i += 2
                continue
            }
            if marker == 0xD9 || marker == 0xDA { break }   // EOI / SOS，DQT 一定在此之前

            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            guard length >= 2 else { break }

            if marker == 0xDB {                              // DQT
                return parseQuantizationTable(bytes, start: i + 4, segmentEnd: i + 2 + length)
            }
            i += 2 + length
        }
        return nil
    }

    private static func parseQuantizationTable(_ bytes: [UInt8], start: Int, segmentEnd: Int) -> Double? {
        var p = start
        while p < segmentEnd && p < bytes.count {
            let precision = bytes[p] >> 4      // 0 = 8 bit, 1 = 16 bit
            let tableID = bytes[p] & 0x0F
            p += 1
            let elementSize = precision == 0 ? 1 : 2
            guard p + 64 * elementSize <= segmentEnd else { break }

            if precision == 0 && tableID == 0 {
                var table = [Int]()
                table.reserveCapacity(64)
                for k in 0..<64 { table.append(Int(bytes[p + k])) }
                return quality(fromTable: table)
            }
            p += 64 * elementSize
        }
        return nil
    }

    private static func quality(fromTable table: [Int]) -> Double? {
        guard table.count >= 64 else { return nil }

        // 判据：原表与标准表逐项之比是否恒定。
        // 恒定 → 标准表缩放型（相机、Photoshop、libjpeg）；
        // 不恒定 → 自定义表（Apple ImageIO 用的是低频平坦表），需另走一条曲线。
        var ratios: [Double] = []
        ratios.reserveCapacity(64)
        for (index, base) in standardLuminance.enumerated() {
            let value = table[index]
            guard base > 0, value > 0 else { continue }
            ratios.append(Double(value) / Double(base))
        }
        guard ratios.count >= 32 else { return nil }

        let mean = ratios.reduce(0, +) / Double(ratios.count)
        guard mean > 0 else { return nil }
        let variance = ratios.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(ratios.count)
        let coefficient = sqrt(variance) / mean

        if coefficient >= 0.3 {
            let lowFrequency = Array(table.prefix(16)).filter { $0 > 0 }
            guard !lowFrequency.isEmpty else { return nil }
            return qualityFromFlatTable(lowFrequency)
        }

        // libjpeg: q<=50 时 scale = 5000/q；q>50 时 scale = 200-2q
        let scale = mean * 100.0
        let q: Double
        if scale >= 100 {
            q = (200.0 - scale) / 2.0
        } else {
            q = 5000.0 / max(scale, 1.0)
        }
        return min(max(q / 100.0, 0.05), 1.0)
    }

    /// 平坦型量化表反推质量档位。采样点来自 ImageIO 的实际输出。
    private static func qualityFromFlatTable(_ values: [Int]) -> Double {
        let sorted = values.sorted()
        let median = Double(sorted[sorted.count / 2])
        let curve: [(value: Double, quality: Double)] = [
            (1, 1.00), (2, 0.70), (3, 0.62), (4, 0.57),
            (6, 0.50), (10, 0.40), (15, 0.30), (24, 0.22), (40, 0.15)
        ]
        if median <= curve[0].value { return curve[0].quality }
        for index in 1..<curve.count {
            let previous = curve[index - 1]
            let current = curve[index]
            if median <= current.value {
                let ratio = (median - previous.value) / (current.value - previous.value)
                return previous.quality + ratio * (current.quality - previous.quality)
            }
        }
        return 0.1
    }
}
