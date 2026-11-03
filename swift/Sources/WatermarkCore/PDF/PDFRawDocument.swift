import Foundation
import CoreGraphics

// MARK: - 页信息

public struct PDFPageInfo: Sendable {
    public var objectNumber: Int
    public var dictionary: [String: PDFObject]
    /// 页面可视区域（已应用 /Rotate 前的原始 MediaBox）
    public var mediaBox: CGRect
    public var rotation: Int
    /// 页面自身声明的 /Resources（可能是引用或字典）
    public var ownResources: PDFObject?
    /// 从父节点继承下来的 /Resources
    public var inheritedResources: PDFObject?
    /// 页面内容流：单个引用或引用数组
    public var contents: PDFObject?

    public var resources: PDFObject? { ownResources ?? inheritedResources }
}

// MARK: - 原始文档

/// 只读的 PDF 结构层。只解析对象、交叉引用与页树，不渲染、不重编码任何流。
public final class PDFRawDocument {
    public let data: Data
    private let bytes: [UInt8]

    public private(set) var trailer: [String: PDFObject] = [:]
    public private(set) var startxrefOffset: Int = 0

    private struct XrefEntry {
        var type: UInt8
        var field2: Int
        var field3: Int
    }
    private var xref: [Int: XrefEntry] = [:]
    private var objectCache: [Int: PDFObject?] = [:]
    private var objectStreamCache: [Int: [Int: PDFObject]] = [:]

    public init(data: Data) throws {
        self.data = data
        self.bytes = [UInt8](data)
        try parseCrossReference()
    }

    public var isEncrypted: Bool { trailer["Encrypt"] != nil }

    /// 下一个可用的对象编号
    public var nextObjectNumber: Int {
        if let size = trailer["Size"]?.asInt { return size }
        return (xref.keys.max() ?? 0) + 1
    }

    /// 已存在的最大对象编号
    public var maxObjectNumber: Int { xref.keys.max() ?? 0 }

    /// 对象当前版本号
    ///
    /// 注意：父节点的 /Kids 里引用的是「编号 + 版本号」，而 Apple PDFKit 会按版本号
    /// 严格匹配。写新版本时若递增版本号，PDFKit 会因匹配不上而回退到旧对象，
    /// 表现为「水印写进去了却看不见」。因此这里返回的是应当沿用的版本号。
    public func generation(of number: Int) -> Int {
        guard let entry = xref[number] else { return 0 }
        // 对象流中的对象版本号恒为 0
        return entry.type == 2 ? 0 : entry.field3
    }

    public var catalog: [String: PDFObject]? {
        guard let root = trailer["Root"] else { return nil }
        return resolve(root)?.asDictionary
    }

    // MARK: - 交叉引用

    private func parseCrossReference() throws {
        if let sx = findLastStartXref() {
            startxrefOffset = sx
            parseChain(from: sx)
        }

        // 兜底：链上任一环节坏掉都可能让 /Root 或整张表丢失。
        // 这时暴力扫描全文的 "N G obj" 重建，能救回大量「打不开」的文件。
        if xref.isEmpty || trailer["Root"] == nil {
            rebuildByScanning()
        }

        if xref.isEmpty {
            throw WatermarkError.malformedPDF("交叉引用表为空且无法重建")
        }
    }

    /// 沿 startxref → /Prev → /XRefStm 链解析。单个节点坏了只跳过它，不整体失败。
    private func parseChain(from start: Int) {
        var visited = Set<Int>()
        var offsetStack: [Int] = [start]
        var isFirst = true

        while let offset = offsetStack.popLast() {
            guard offset > 0, offset < bytes.count, !visited.contains(offset) else { continue }
            visited.insert(offset)

            let entries: [Int: XrefEntry]
            let dict: [String: PDFObject]
            var pendingXRefStm: Int?

            do {
                if peekKeyword(at: offset, "xref") {
                    let parsed = try parseTraditionalXref(at: offset)
                    entries = parsed.entries
                    dict = parsed.trailer
                    pendingXRefStm = parsed.trailer["XRefStm"]?.asInt
                } else {
                    let parsed = try parseXrefStream(at: offset)
                    entries = parsed.entries
                    dict = parsed.trailer
                }
            } catch {
                continue      // 这一段坏了，继续尝试链上的其他段
            }

            // 先解析到的是较新的版本，只填补空缺
            for (num, entry) in entries where xref[num] == nil {
                xref[num] = entry
            }
            if isFirst {
                trailer = dict
                isFirst = false
            } else {
                for (k, v) in dict where trailer[k] == nil { trailer[k] = v }
            }

            if let prev = dict["Prev"]?.asInt {
                offsetStack.append(prev)
            }
            // /XRefStm 比 /Prev 更新，需要后入栈以便先处理
            if let xrefStm = pendingXRefStm {
                offsetStack.append(xrefStm)
            }
        }
    }

    /// 扫描全文的「编号 版本号 obj」重建交叉引用表，并找出 Catalog。
    /// 用于 xref 损坏、startxref 偏移错误、trailer 丢失等场景。
    private func rebuildByScanning() {
        let objKeyword = Data("obj".utf8)
        var searchStart = 0
        var found: [Int: XrefEntry] = [:]
        var catalogNumber: Int?

        while let range = data.range(of: objKeyword, options: [], in: searchStart..<data.count) {
            searchStart = range.upperBound
            var p = range.lowerBound
            guard p > 0 else { continue }

            // 向前退过空白，读出版本号
            p -= 1
            while p > 0 && isWhitespace(bytes[p]) { p -= 1 }
            var genEnd = p + 1
            while p > 0 && bytes[p - 1] >= 0x30 && bytes[p - 1] <= 0x39 { p -= 1 }
            guard p < genEnd,
                  let generation = Int(String(decoding: bytes[p..<genEnd], as: UTF8.self)) else { continue }

            // 再退过空白，读出对象编号
            p -= 1
            while p > 0 && isWhitespace(bytes[p]) { p -= 1 }
            var numEnd = p + 1
            while p > 0 && bytes[p - 1] >= 0x30 && bytes[p - 1] <= 0x39 { p -= 1 }
            guard p < numEnd,
                  let number = Int(String(decoding: bytes[p..<numEnd], as: UTF8.self)) else { continue }

            found[number] = XrefEntry(type: 1, field2: p, field3: generation)

            // 顺手记下 Catalog：增量更新要用到 /Root。
            // 必须真正解析验证——只做字节匹配会把别的含 "Catalog" 字样的对象认错。
            if catalogNumber == nil, isCatalogObject(at: p) { catalogNumber = number }
        }

        guard !found.isEmpty else { return }

        // 只填补空缺，不覆盖链上已解析到的（后者更权威）
        for (num, entry) in found where xref[num] == nil {
            xref[num] = entry
        }
        if trailer["Root"] == nil, let catalogNumber {
            trailer["Root"] = .reference(objectNumber: catalogNumber, generation: 0)
        }
        if trailer["Size"] == nil {
            trailer["Size"] = .integer((xref.keys.max() ?? 0) + 1)
        }
    }

    /// 确认给定位置的对象是 Catalog：先做便宜的字节预筛，再真正解析验证。
    /// 只靠字节匹配不够——/Info、StructTreeRoot 等对象里也可能出现 "Catalog" 字样。
    private func isCatalogObject(at offset: Int) -> Bool {
        let end = min(offset + 400, bytes.count)
        guard offset < end else { return false }
        // 便宜的预筛：/Type 附近要有 Catalog
        guard let typeRange = data[offset..<end].range(of: Data("/Type".utf8)) else { return false }
        let after = typeRange.upperBound
        guard after < end,
              data[after..<min(after + 24, end)].range(of: Data("Catalog".utf8)) != nil else { return false }

        var parser = PDFObjectParser(bytes: bytes, pos: offset, resolve: { _, _ in nil })
        guard let parsed = try? parser.parseIndirectObject(),
              let dict = parsed.2.asDictionary,
              dict["Type"]?.asName == "Catalog",
              dict["Pages"] != nil else { return false }
        return true
    }

    private func isWhitespace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x00 || c == 0x0C
    }

    private func findLastStartXref() -> Int? {
        let needle = Data("startxref".utf8)
        var searchRange: Range<Data.Index> = 0..<data.count
        while let found = data.range(of: needle, options: .backwards, in: searchRange) {
            var p = found.upperBound
            if let value = readInteger(at: &p) { return value }
            guard found.lowerBound > 0 else { break }
            searchRange = 0..<found.lowerBound
        }
        return nil
    }

    private func parseTraditionalXref(at start: Int) throws -> (entries: [Int: XrefEntry], trailer: [String: PDFObject]) {
        var pos = start
        _ = readKeyword(at: &pos)   // "xref"
        var entries: [Int: XrefEntry] = [:]

        while true {
            pos = skipWhitespace(at: pos)
            guard pos < bytes.count else { break }
            if peekKeyword(at: pos, "trailer") { break }
            guard let first = readInteger(at: &pos) else { break }
            pos = skipWhitespace(at: pos)
            guard let count = readInteger(at: &pos) else { break }
            // count 来自文件且未校验：读到 2e9 会空转几十亿次。
            // 每条记录至少 20 字节，据此夹一个合理上限
            let maxCount = max((bytes.count - pos) / 20 + 1, 1)
            guard count >= 0, count <= maxCount else { break }
            // 必须跳到下一行再开始读条目，否则会把残留的换行当成一条空记录
            pos = skipToNextLine(at: pos)
            for i in 0..<count {
                let (line, next) = readLine(at: pos)
                pos = next
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if fields.count >= 3, let f2 = Int(fields[0]), let f3 = Int(fields[1]),
                   let typeChar = fields[2].first {
                    let type: UInt8 = typeChar == "n" ? 1 : (typeChar == "f" ? 0 : 0)
                    entries[first + i] = XrefEntry(type: type, field2: f2, field3: f3)
                }
            }
        }

        guard peekKeyword(at: pos, "trailer") else {
            return (entries, [:])
        }
        _ = readKeyword(at: &pos)
        var parser = PDFObjectParser(bytes: bytes, pos: pos, resolve: resolveClosure())
        guard let obj = try parser.parseObject(), let dict = obj.asDictionary else {
            return (entries, [:])
        }
        return (entries, dict)
    }

    private func parseXrefStream(at offset: Int) throws -> (entries: [Int: XrefEntry], trailer: [String: PDFObject]) {
        var parser = PDFObjectParser(bytes: bytes, pos: offset, resolve: resolveClosure())
        guard let (_, _, obj) = try parser.parseIndirectObject() else {
            throw WatermarkError.malformedPDF("xref stream 解析失败")
        }
        guard case .stream(let s) = obj else {
            throw WatermarkError.malformedPDF("xref stream 不是流对象")
        }
        // 必须**先**拿到 /W 再解压：xref stream 的 PNG predictor 行宽等于 W 各字段之和，
        // 而绝大多数生成器不会在 /DecodeParms 里写 /Columns。若按默认的 1 字节行宽去反解
        // predictor，整张表会错位，表现为对象类型出现 188/217 这类非法值、/Root 解析不出来。
        guard let widths = s.dictionary["W"]?.asArray, widths.count >= 3,
              let w0 = widths[0].asInt, let w1 = widths[1].asInt, let w2 = widths[2].asInt,
              // /W 也来自文件：过大宽度会让 w0+w1+w2 溢出、且读出的字段宽到无意义
              w0 >= 0, w1 >= 0, w2 >= 0, w0 <= 8, w1 <= 8, w2 <= 8 else {
            throw WatermarkError.malformedPDF("xref stream 的 /W 无效")
        }
        let rowLength = w0 + w1 + w2
        guard rowLength > 0 else {
            throw WatermarkError.malformedPDF("xref stream /W 全为 0")
        }

        guard let decoded = decodeStream(s, defaultColumns: rowLength) else {
            throw WatermarkError.malformedPDF("xref stream 解压失败")
        }

        var indexRanges: [Int] = []
        if let index = s.dictionary["Index"]?.asArray {
            indexRanges = index.compactMap { $0.asInt }
        } else {
            let size = s.dictionary["Size"]?.asInt ?? 0
            indexRanges = [0, size]
        }

        let raw = [UInt8](decoded)
        var entries: [Int: XrefEntry] = [:]
        var rowStart = 0
        var rangeIdx = 0
        while rangeIdx + 1 < indexRanges.count {
            let first = indexRanges[rangeIdx]
            let count = indexRanges[rangeIdx + 1]
            rangeIdx += 2
            for i in 0..<count {
                guard rowStart >= 0, rowStart + rowLength <= raw.count else { break }
                var p = rowStart
                let f1 = w0 > 0 ? Self.readBigEndian(raw, at: &p, width: w0) : 1
                let f2 = w1 > 0 ? Self.readBigEndian(raw, at: &p, width: w1) : 0
                let f3 = w2 > 0 ? Self.readBigEndian(raw, at: &p, width: w2) : 0
                // 类型只能是 0/1/2，其他值说明这份表已经错位，丢弃而不是写入脏数据
                guard f1 >= 0, f1 <= 2 else { rowStart += rowLength; continue }
                entries[first + i] = XrefEntry(type: UInt8(f1), field2: f2, field3: f3)
                rowStart += rowLength
            }
        }
        return (entries, s.dictionary)
    }

    private static func readBigEndian(_ raw: [UInt8], at p: inout Int, width: Int) -> Int {
        var value = 0
        for _ in 0..<width {
            guard p < raw.count else { p += 1; continue }
            value = value << 8 | Int(raw[p])
            p += 1
        }
        return value
    }

    // MARK: - 对象访问

    private func resolveClosure() -> ((Int, Int) -> PDFObject?) {
        return { [weak self] number, _ in
            self?.object(number: number)
        }
    }

    public func object(number: Int) -> PDFObject? {
        if let cached = objectCache[number] { return cached }
        guard let entry = xref[number] else { return nil }
        objectCache[number] = nil     // 防止循环引用导致无限递归
        var result: PDFObject?
        switch entry.type {
        case 1:
            var parser = PDFObjectParser(bytes: bytes, pos: entry.field2, resolve: resolveClosure())
            result = try? parser.parseIndirectObject()?.2
        case 2:
            result = objectFromObjectStream(streamNumber: entry.field2, index: entry.field3)
        default:
            result = nil
        }
        objectCache[number] = result
        return result
    }

    public func resolve(_ obj: PDFObject?) -> PDFObject? {
        guard let obj else { return nil }
        if case .reference(let n, let g) = obj {
            return object(number: n) ?? .reference(objectNumber: n, generation: g)
        }
        return obj
    }

    private func objectFromObjectStream(streamNumber: Int, index: Int) -> PDFObject? {
        if let cached = objectStreamCache[streamNumber] {
            return cached[index]
        }
        guard let stm = object(number: streamNumber), case .stream(let s) = stm,
              let decoded = decodeStream(s),
              let first = s.dictionary["First"]?.asInt,
              let count = s.dictionary["N"]?.asInt else {
            objectStreamCache[streamNumber] = [:]
            return nil
        }

        // 前 N 对整数是「对象号 偏移」
        let raw = [UInt8](decoded)
        var p = 0
        var pairs: [(number: Int, offset: Int)] = []
        for _ in 0..<count {
            guard let n = readInteger(at: &p, in: raw) else { break }
            p = skipWhitespace(at: p, in: raw)
            guard let off = readInteger(at: &p, in: raw) else { break }
            p = skipWhitespace(at: p, in: raw)
            pairs.append((n, off))
        }

        // 必须按「在流中的序号」建表：xref 里 type=2 条目的 field3 是序号而非对象号。
        // 早先按对象号建表却用序号去取，只有序号恰好等于某个对象号时才命中，
        // 而且取到的还是**错误对象**的内容——表现为整份 PDF 大面积丢页。
        var table: [Int: PDFObject] = [:]
        for (order, pair) in pairs.enumerated() {
            let pos = first + pair.offset
            guard pos >= 0, pos < raw.count else { continue }
            var parser = PDFObjectParser(bytes: raw, pos: pos, resolve: resolveClosure())
            if let obj = try? parser.parseObject() {
                table[order] = obj
            }
        }
        objectStreamCache[streamNumber] = table
        return table[index]
    }

    // MARK: - 流解码

    /// - Parameter defaultColumns: /DecodeParms 里没写 /Columns 时使用的行宽。
    ///   xref stream 必须传 W 各字段之和，否则 predictor 会按 1 字节一行反解而错位。
    func decodeStream(_ s: PDFStream, defaultColumns: Int? = nil) -> Data? {
        var result = s.data
        if let filter = s.dictionary["Filter"] {
            let names: [String]
            if let n = filter.asName {
                names = [n]
            } else if let arr = filter.asArray {
                names = arr.compactMap { $0.asName }
            } else {
                names = []
            }
            for name in names {
                switch name {
                case "FlateDecode":
                    guard let inflated = PDFCodec.inflate(result) else { return nil }
                    result = inflated
                case "LZWDecode":
                    // 真正的数据编码过滤器，解不了就不能假装成功
                    return nil
                case "DCTDecode", "JPXDecode", "CCITTFaxDecode", "JBIG2Decode", "RunLengthDecode":
                    // 图片编码，我们不需要解它，原样保留即可
                    break
                default:
                    // 未知过滤器多半不是数据编码（如数字签名的 Adobe.PPKLite、
                    // 加密的 Adobe.PPKLite/Crypt），跳过而不是判死
                    break
                }
            }
        }

        let parms = s.dictionary["DecodeParms"] ?? s.dictionary["DP"]
        if let parmsDict = resolve(parms)?.asDictionary ?? parms?.asDictionary,
           let predictor = parmsDict["Predictor"]?.asInt, predictor >= 10 {
            let colors = parmsDict["Colors"]?.asInt ?? 1
            let bpc = parmsDict["BitsPerComponent"]?.asInt ?? 8
            let columns = parmsDict["Columns"]?.asInt ?? defaultColumns ?? 1
            result = Self.applyPredictor(result, colors: colors, bitsPerComponent: bpc, columns: columns)
        }
        return result
    }

    /// PNG predictor 解码（PDF 里几乎都是 Up = 2）
    static func applyPredictor(_ data: Data, colors: Int, bitsPerComponent: Int, columns: Int) -> Data {
        let bpp = max(1, (colors * bitsPerComponent + 7) / 8)
        let rowLength = max(1, (columns * colors * bitsPerComponent + 7) / 8)
        let raw = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(raw.count)
        var prev = [UInt8](repeating: 0, count: rowLength)
        var offset = 0

        while offset < raw.count {
            let filterType = Int(raw[offset])
            offset += 1
            let available = min(rowLength, raw.count - offset)
            if available <= 0 { break }
            var cur = [UInt8](repeating: 0, count: rowLength)
            for i in 0..<available {
                let x = Int(raw[offset + i])
                let a = i >= bpp ? Int(cur[i - bpp]) : 0
                let b = Int(prev[i])
                let c = i >= bpp ? Int(prev[i - bpp]) : 0
                let v: Int
                switch filterType {
                case 0: v = x
                case 1: v = x + a
                case 2: v = x + b
                case 3: v = x + (a + b) / 2
                case 4: v = x + paeth(a, b, c)
                default: v = x
                }
                cur[i] = UInt8(v & 0xFF)
            }
            out.append(contentsOf: cur)
            prev = cur
            offset += rowLength
        }
        return Data(out)
    }

    private static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a)
        let pb = abs(p - b)
        let pc = abs(p - c)
        if pa <= pb && pa <= pc { return a }
        if pb <= pc { return b }
        return c
    }

    // MARK: - 页树

    public func pages() throws -> [PDFPageInfo] {
        guard let catalog else { throw WatermarkError.malformedPDF("缺少 /Root") }
        guard let pagesRef = catalog["Pages"] else { throw WatermarkError.malformedPDF("缺少 /Pages") }
        guard let rootNode = resolve(pagesRef) else { throw WatermarkError.malformedPDF("/Pages 无法解析") }

        var result: [PDFPageInfo] = []
        var visited: Set<Int> = []
        try walk(node: rootNode, inherited: [:], into: &result, visited: &visited)
        return result
    }

    private func walk(
        node: PDFObject,
        inherited: [String: PDFObject],
        into result: inout [PDFPageInfo],
        visited: inout Set<Int>
    ) throws {
        var current = inherited
        for key in ["Resources", "MediaBox", "CropBox", "Rotate"] {
            if node[key] != nil { current[key] = node[key] }
        }

        // 绝大多数用 /Kids，少数生成器写成 /Pages，两者都要认
        let kidsArray = node["Kids"]?.asArray ?? node["Pages"]?.asArray
        guard let kids = kidsArray else {
            throw WatermarkError.malformedPDF("页树节点缺少 /Kids")
        }

        for kid in kids {
            guard case .reference(let number, _) = kid else { continue }
            // 坏节点跳过而不是让整份文件失败：个别损坏页不应拖垮其余页面
            guard !visited.contains(number), let obj = object(number: number) else { continue }
            visited.insert(number)

            if obj["Kids"] != nil || obj["Pages"] != nil {
                try walk(node: obj, inherited: current, into: &result, visited: &visited)
                continue
            }

            let dict = obj.asDictionary ?? [:]
            let mediaBox = mediaBox(from: obj, inherited: current)
            let rotation = (obj["Rotate"] ?? current["Rotate"])?.asInt ?? 0
            let own = obj["Resources"]
            let inheritedRes = current["Resources"]

            result.append(PDFPageInfo(
                objectNumber: number,
                dictionary: dict,
                mediaBox: mediaBox,
                rotation: rotation,
                ownResources: own,
                inheritedResources: inheritedRes,
                contents: obj["Contents"]
            ))
        }
    }

    private func mediaBox(from page: PDFObject, inherited: [String: PDFObject]) -> CGRect {
        let box = page["MediaBox"] ?? inherited["MediaBox"] ?? page["CropBox"] ?? inherited["CropBox"]
        guard let arr = resolve(box)?.asArray, arr.count == 4,
              let x = arr[0].asDouble, let y = arr[1].asDouble,
              let w = arr[2].asDouble, let h = arr[3].asDouble else {
            return CGRect(x: 0, y: 0, width: 612, height: 792)
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - 字节工具

    func skipWhitespace(at pos: Int) -> Int {
        skipWhitespace(at: pos, in: bytes)
    }

    private func skipWhitespace(at pos: Int, in raw: [UInt8]) -> Int {
        var p = pos
        while p < raw.count {
            let c = raw[p]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x00 || c == 0x0C {
                p += 1
            } else if c == 0x25 {   // '%' 注释
                while p < raw.count && raw[p] != 0x0A && raw[p] != 0x0D { p += 1 }
            } else {
                break
            }
        }
        return p
    }

    private func readInteger(at pos: inout Int) -> Int? {
        readInteger(at: &pos, in: bytes)
    }

    private func readInteger(at pos: inout Int, in raw: [UInt8]) -> Int? {
        var p = skipWhitespace(at: pos, in: raw)
        var digits = ""
        if p < raw.count && (raw[p] == 0x2B || raw[p] == 0x2D) {
            digits.append(Character(UnicodeScalar(raw[p])))
            p += 1
        }
        var hasDigit = false
        while p < raw.count && raw[p] >= 0x30 && raw[p] <= 0x39 {
            digits.append(Character(UnicodeScalar(raw[p])))
            p += 1
            hasDigit = true
        }
        guard hasDigit, let value = Int(digits) else { return nil }
        pos = p
        return value
    }

    private func readKeyword(at pos: inout Int) -> String? {
        var p = skipWhitespace(at: pos)
        let raw = bytes
        var token = ""
        while p < raw.count, (raw[p] >= 0x41 && raw[p] <= 0x5A) || (raw[p] >= 0x61 && raw[p] <= 0x7A) {
            token.append(Character(UnicodeScalar(raw[p])))
            p += 1
        }
        if token.isEmpty { return nil }
        pos = p
        return token
    }

    private func peekKeyword(at pos: Int, _ keyword: String) -> Bool {
        let p = skipWhitespace(at: pos)
        let needle = Array(keyword.utf8)
        guard p + needle.count <= bytes.count else { return false }
        return Array(bytes[p..<(p + needle.count)]) == needle
    }

    /// 跳过当前行尾的空白与换行，定位到下一行开头
    private func skipToNextLine(at pos: Int) -> Int {
        var p = pos
        while p < bytes.count, bytes[p] == 0x20 || bytes[p] == 0x09 { p += 1 }
        if p < bytes.count && bytes[p] == 0x0D { p += 1 }
        if p < bytes.count && bytes[p] == 0x0A { p += 1 }
        return p
    }

    private func readLine(at pos: Int) -> (String, Int) {
        var p = pos
        var chars = ""
        let raw = bytes
        while p < raw.count && raw[p] != 0x0A && raw[p] != 0x0D {
            chars.append(Character(UnicodeScalar(raw[p])))
            p += 1
        }
        while p < raw.count && (raw[p] == 0x0A || raw[p] == 0x0D) { p += 1 }
        return (chars, p)
    }
}
