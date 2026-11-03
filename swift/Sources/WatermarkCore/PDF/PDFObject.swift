import Foundation

/// PDF 流对象。data 保存的是原始（可能已压缩）字节，序列化时不会重新编码。
public struct PDFStream: Sendable {
    public var dictionary: [String: PDFObject]
    public var data: Data

    public init(dictionary: [String: PDFObject], data: Data) {
        self.dictionary = dictionary
        self.data = data
    }
}

public indirect enum PDFObject: Sendable {
    case null
    case boolean(Bool)
    case integer(Int)
    case real(Double)
    case name(String)
    case literalString(String)
    case hexString(String)
    case array([PDFObject])
    case dictionary([String: PDFObject])
    case stream(PDFStream)
    case reference(objectNumber: Int, generation: Int)

    // MARK: - 便捷取值

    public var asInt: Int? {
        switch self {
        case .integer(let v): return v
        case .real(let v): return Int(v)
        default: return nil
        }
    }

    public var asDouble: Double? {
        switch self {
        case .integer(let v): return Double(v)
        case .real(let v): return v
        default: return nil
        }
    }

    public var asName: String? {
        if case .name(let v) = self { return v }
        return nil
    }

    public var asArray: [PDFObject]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var asDictionary: [String: PDFObject]? {
        if case .dictionary(let v) = self { return v }
        return nil
    }

    public var isStream: Bool {
        if case .stream = self { return true }
        return false
    }

    public var streamDictionary: [String: PDFObject]? {
        if case .stream(let s) = self { return s.dictionary }
        return nil
    }

    public subscript(key: String) -> PDFObject? {
        if case .dictionary(let d) = self { return d[key] }
        if case .stream(let s) = self { return s.dictionary[key] }
        return nil
    }
}

// MARK: - 序列化

extension PDFObject {
    /// 序列化为 PDF 语法字节。流对象会写入正确的 /Length。
    public func serialized() -> Data {
        var out = Data()
        write(into: &out)
        return out
    }

    private func write(into out: inout Data) {
        switch self {
        case .null:
            out.append(contentsOf: "null".utf8)
        case .boolean(let v):
            out.append(contentsOf: (v ? "true" : "false").utf8)
        case .integer(let v):
            out.append(contentsOf: String(v).utf8)
        case .real(let v):
            out.append(contentsOf: Self.formatReal(v).utf8)
        case .name(let v):
            out.append(contentsOf: Self.escapeName(v).utf8)
        case .literalString(let v):
            out.append(contentsOf: Self.escapeLiteral(v).utf8)
        case .hexString(let v):
            out.append(contentsOf: "<\(v)>".utf8)
        case .array(let items):
            out.append(contentsOf: "[".utf8)
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(0x20) }
                item.write(into: &out)
            }
            out.append(contentsOf: "]".utf8)
        case .dictionary(let dict):
            Self.writeDictionary(dict, into: &out)
        case .stream(let s):
            var d = s.dictionary
            d["Length"] = .integer(s.data.count)
            Self.writeDictionary(d, into: &out)
            out.append(contentsOf: "\nstream\n".utf8)
            out.append(s.data)
            out.append(contentsOf: "\nendstream".utf8)
        case .reference(let n, let g):
            out.append(contentsOf: "\(n) \(g) R".utf8)
        }
    }

    private static func writeDictionary(_ dict: [String: PDFObject], into out: inout Data) {
        out.append(contentsOf: "<<".utf8)
        for (i, key) in dict.keys.sorted().enumerated() {
            if i > 0 { out.append(0x20) }
            out.append(contentsOf: escapeName(key).utf8)
            out.append(0x20)
            dict[key]!.write(into: &out)
        }
        out.append(contentsOf: ">>".utf8)
    }

    private static func formatReal(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int(v)) }
        let s = String(format: "%.6f", v)
        // 去掉尾随 0
        var result = s
        while result.hasSuffix("0") { result.removeLast() }
        if result.hasSuffix(".") { result.removeLast() }
        return result
    }

    private static func escapeName(_ name: String) -> String {
        var out = "/"
        for scalar in name.unicodeScalars {
            let c = Character(scalar)
            if c.isWhitespace || c.isNewline || "()<>[]{}/%".contains(c) {
                let v = scalar.value
                if v <= 0xFF {
                    out += String(format: "#%02X", v)
                } else {
                    out += String(scalar)
                }
            } else {
                out += String(scalar)
            }
        }
        return out
    }

    private static func escapeLiteral(_ s: String) -> String {
        var out = "("
        for scalar in s.unicodeScalars {
            switch scalar {
            case "(": out += "\\("
            case ")": out += "\\)"
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 32 {
                    out += String(format: "\\%03o", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + ")"
    }
}
