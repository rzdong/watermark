import Foundation

/// 在字节数组上做递归下降解析。只解析语法，不解压流。
struct PDFObjectParser {
    let bytes: [UInt8]
    var pos: Int
    let resolve: (Int, Int) -> PDFObject?

    init(bytes: [UInt8], pos: Int, resolve: @escaping (Int, Int) -> PDFObject?) {
        self.bytes = bytes
        self.pos = pos
        self.resolve = resolve
    }

    // MARK: - 空白与注释

    mutating func skipWhitespace() {
        while pos < bytes.count {
            let c = bytes[pos]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x00 || c == 0x0C {
                pos += 1
            } else if c == 0x25 {
                while pos < bytes.count && bytes[pos] != 0x0A && bytes[pos] != 0x0D { pos += 1 }
            } else {
                break
            }
        }
    }

    private mutating func skipEOL() {
        if pos < bytes.count && bytes[pos] == 0x0D { pos += 1 }
        if pos < bytes.count && bytes[pos] == 0x0A { pos += 1 }
    }

    // MARK: - 主入口

    /// 解析一个对象。遇到结束定界符或未知关键字时返回 nil（不移动 pos）。
    mutating func parseObject() throws -> PDFObject? {
        skipWhitespace()
        guard pos < bytes.count else { return nil }

        switch bytes[pos] {
        case 0x2F:                                   // /
            return .name(parseName())
        case 0x28:                                   // (
            return .literalString(parseLiteralString())
        case 0x5B:                                   // [
            return try parseArray()
        case 0x3C:                                   // < 或 <<
            if pos + 1 < bytes.count && bytes[pos + 1] == 0x3C {
                return try parseDictionary()
            }
            return .hexString(parseHexString())
        case 0x5D, 0x3E, 0x29:                       // ] > )
            return nil
        default:
            break
        }

        let token = readRegularToken()
        if token.isEmpty {
            pos += 1
            return nil
        }

        if let intValue = Int(token) {
            // 尝试识别间接引用 "N G R"
            let save = pos
            skipWhitespace()
            if let gen = readIntegerToken() {
                let saveAfterGen = pos
                skipWhitespace()
                if readRegularToken() == "R" {
                    return .reference(objectNumber: intValue, generation: gen)
                }
                pos = saveAfterGen
            }
            pos = save
            return .integer(intValue)
        }

        if let doubleValue = Double(token) { return .real(doubleValue) }

        switch token {
        case "true":  return .boolean(true)
        case "false": return .boolean(false)
        case "null":  return .null
        default:      return nil   // obj / endobj / stream / trailer / xref 等
        }
    }

    /// 解析 "N G obj ... endobj"，含流对象
    mutating func parseIndirectObject() throws -> (Int, Int, PDFObject)? {
        skipWhitespace()
        guard let number = readIntegerToken() else { return nil }
        skipWhitespace()
        guard let generation = readIntegerToken() else { return nil }
        skipWhitespace()
        guard readRegularToken() == "obj" else { return nil }

        guard let obj = try parseObject() else { return nil }

        skipWhitespace()
        if peekKeyword("stream") {
            pos += 6
            skipEOL()
            guard var dict = obj.asDictionary else {
                throw WatermarkError.malformedPDF("流对象头部不是字典")
            }
            var length = dict["Length"]?.asInt
            if length == nil, case .reference(let ln, let lg)? = dict["Length"] {
                length = resolve(ln, lg)?.asInt
            }
            guard let len = length, len >= 0 else {
                throw WatermarkError.malformedPDF("流缺少有效的 /Length")
            }
            let start = pos
            // /Length 来自文件，可能是天文数字：先夹到文件剩余长度，避免溢出与非法区间
            let remaining = max(bytes.count - start, 0)
            let end = start + min(len, remaining)
            let raw = Data(bytes[start..<end])
            pos = end
            skipWhitespace()
            if peekKeyword("endstream") { pos += 9 }
            dict["Length"] = .integer(raw.count)
            skipWhitespace()
            if peekKeyword("endobj") { pos += 6 }
            return (number, generation, .stream(PDFStream(dictionary: dict, data: raw)))
        }

        skipWhitespace()
        if peekKeyword("endobj") { pos += 6 }
        return (number, generation, obj)
    }

    // MARK: - 复合对象

    private mutating func parseArray() throws -> PDFObject {
        pos += 1
        var items: [PDFObject] = []
        while pos < bytes.count {
            skipWhitespace()
            // skipWhitespace 可能把 pos 推到文件末尾（数组被截断时），必须重新检查，
            // 否则下一行 bytes[pos] 直接越界崩溃
            guard pos < bytes.count else { break }
            if bytes[pos] == 0x5D { pos += 1; break }
            if let value = try parseObject() {
                items.append(value)
            } else if pos < bytes.count {
                pos += 1
            }
        }
        return .array(items)
    }

    private mutating func parseDictionary() throws -> PDFObject {
        pos += 2
        var dict: [String: PDFObject] = [:]
        while pos < bytes.count {
            skipWhitespace()
            if pos >= bytes.count { break }
            if bytes[pos] == 0x3E {
                if pos + 1 < bytes.count && bytes[pos + 1] == 0x3E { pos += 2 } else { pos += 1 }
                break
            }
            guard let keyObj = try parseObject(), let key = keyObj.asName else {
                pos += 1
                continue
            }
            skipWhitespace()
            guard let value = try parseObject() else { break }
            dict[key] = value
        }
        return .dictionary(dict)
    }

    // MARK: - 词法单元

    private mutating func parseName() -> String {
        pos += 1
        var out = ""
        while pos < bytes.count {
            let c = bytes[pos]
            if isDelimiter(c) || isWhitespace(c) { break }
            if c == 0x23 {   // '#'
                let h1 = pos + 1 < bytes.count ? bytes[pos + 1] : 0
                let h2 = pos + 2 < bytes.count ? bytes[pos + 2] : 0
                if let v1 = hexValue(h1), let v2 = hexValue(h2) {
                    out.append(Character(UnicodeScalar(UInt8(v1 << 4 | v2))))
                    pos += 3
                    continue
                }
            }
            out.append(Character(UnicodeScalar(c)))
            pos += 1
        }
        return out
    }

    private mutating func parseHexString() -> String {
        pos += 1
        var out = ""
        while pos < bytes.count && bytes[pos] != 0x3E {
            // 必须写满两位：0x0A 写成 "A" 会让整个十六进制串错位、长度减半
            if let v = hexValue(bytes[pos]) { out.append(String(format: "%02X", v)) }
            pos += 1
        }
        if pos < bytes.count { pos += 1 }
        return out
    }

    private mutating func parseLiteralString() -> String {
        pos += 1
        var depth = 1
        var out = ""
        while pos < bytes.count {
            let c = bytes[pos]
            if c == 0x5C {                                   // 反斜杠
                pos += 1
                guard pos < bytes.count else { break }
                let e = bytes[pos]
                switch e {
                case 0x6E: out.append("\n"); pos += 1
                case 0x72: out.append("\r"); pos += 1
                case 0x74: out.append("\t"); pos += 1
                case 0x62: out.append(Character(UnicodeScalar(UInt8(8)))); pos += 1
                case 0x66: out.append(Character(UnicodeScalar(UInt8(12)))); pos += 1
                case 0x28: out.append("("); pos += 1
                case 0x29: out.append(")"); pos += 1
                case 0x5C: out.append("\\"); pos += 1
                case 0x0A: pos += 1
                case 0x0D:
                    pos += 1
                    if pos < bytes.count && bytes[pos] == 0x0A { pos += 1 }
                default:
                    if e >= 0x30 && e <= 0x37 {
                        var value = 0
                        var count = 0
                        while count < 3 && pos < bytes.count && bytes[pos] >= 0x30 && bytes[pos] <= 0x37 {
                            value = value * 8 + Int(bytes[pos] - 0x30)
                            pos += 1
                            count += 1
                        }
                        out.append(Character(UnicodeScalar(UInt8(value & 0xFF))))
                    } else {
                        out.append(Character(UnicodeScalar(e)))
                        pos += 1
                    }
                }
                continue
            }
            if c == 0x28 {
                depth += 1
                out.append("(")
            } else if c == 0x29 {
                depth -= 1
                if depth == 0 { pos += 1; break }
                out.append(")")
            } else {
                out.append(Character(UnicodeScalar(c)))
            }
            pos += 1
        }
        return out
    }

    private mutating func readRegularToken() -> String {
        var out = ""
        while pos < bytes.count {
            let c = bytes[pos]
            if isDelimiter(c) || isWhitespace(c) { break }
            out.append(Character(UnicodeScalar(c)))
            pos += 1
        }
        return out
    }

    private mutating func readIntegerToken() -> Int? {
        skipWhitespace()
        var digits = ""
        if pos < bytes.count && (bytes[pos] == 0x2B || bytes[pos] == 0x2D) {
            digits.append(Character(UnicodeScalar(bytes[pos])))
            pos += 1
        }
        var hasDigit = false
        while pos < bytes.count && bytes[pos] >= 0x30 && bytes[pos] <= 0x39 {
            digits.append(Character(UnicodeScalar(bytes[pos])))
            pos += 1
            hasDigit = true
        }
        guard hasDigit else { return nil }
        return Int(digits)
    }

    private mutating func peekKeyword(_ keyword: String) -> Bool {
        let needle = Array(keyword.utf8)
        guard pos + needle.count <= bytes.count else { return false }
        return Array(bytes[pos..<(pos + needle.count)]) == needle
    }

    private func isDelimiter(_ c: UInt8) -> Bool {
        switch c {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25:
            return true
        default:
            return false
        }
    }

    private func isWhitespace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x00 || c == 0x0C
    }

    private func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }
}
