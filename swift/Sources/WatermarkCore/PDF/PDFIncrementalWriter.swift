import Foundation
import CoreGraphics

/// 通过「增量更新」给 PDF 加水印。
///
/// 保证：
/// - 原文件的每一个字节都原样保留，只在末尾追加内容
/// - 原页面内容流不解压、不重新压缩
/// - /Info、XMP、书签、注释、表单、嵌入字体、图片全部保留
/// - 已有数字签名仍然有效
///
/// 三个关键设计：
/// 1. **不复用现有对象号**：整棵页树重建为新编号，只改 trailer 的 /Root。
///    覆盖旧对象的写法在版本号上两头不讨好（递增则 /Kids 匹配失败，
///    沿用则同编号+版本重复时阅读器挑旧的）。
/// 2. **水印挂在内容流还是注释上，取决于页面有没有注释**：
///    PDF 的渲染顺序是「页面内容 → 注释」，注释永远盖在内容之上。
///    若页面带 /Annots（图形水印、印章、批注等），内容流水印会被完全遮住，
///    必须把水印本身做成注释追加到 /Annots 末尾，才能排在最上层。
/// 3. **内容流不压缩**：PDFKit 会拒绝这里自行生成的 zlib 流。
public struct PDFIncrementalWriter {
    public let document: PDFRawDocument
    public let config: WatermarkConfig

    public init(document: PDFRawDocument, config: WatermarkConfig) {
        self.document = document
        self.config = config
    }

    public struct Result: Sendable {
        public var data: Data
        public var pageCount: Int
        public var watermarkedPages: Int
        public var appendedBytes: Int
    }

    struct NewObject {
        var number: Int
        var generation: Int
        var object: PDFObject
    }

    /// 水印附加到页面的两种方式
    enum Attachment {
        /// 追加为页面内容流的最后一段
        case contentStream(PDFObject)
        /// 追加为一个注释（会渲染在所有注释之上）
        case annotation(PDFObject)
    }

    /// 页面「摆正」的结果：原内容被包进旋转变换后形成的新流，以及新的 MediaBox
    struct PageUpright {
        var contentRef: PDFObject
        var mediaBox: CGRect
    }

    public func process() throws -> Result {
        guard !document.isEncrypted else { throw WatermarkError.encryptedPDF }

        let pages = try document.pages()
        guard !pages.isEmpty else { throw WatermarkError.malformedPDF("没有找到任何页面") }

        let startNumber = max(document.nextObjectNumber, document.maxObjectNumber + 1)
        let allocator = PDFObjectNumberAllocator(startingAt: startNumber)
        let builder = PDFWatermarkContentBuilder(config: config, allocator: allocator)

        // 资源只建一次，所有页面共享
        let (sharedResources, pending) = try builder.makeResources()
        var newObjects: [NewObject] = pending.map {
            NewObject(number: $0.number, generation: 0, object: $0.object)
        }

        var targets: Set<Int> = []
        for (index, page) in pages.enumerated() {
            if config.pdf.pageRange.contains(pageIndex: index + 1, pageCount: pages.count) {
                targets.insert(page.objectNumber)
            }
        }
        guard !targets.isEmpty else {
            return Result(
                data: document.data,
                pageCount: pages.count,
                watermarkedPages: 0,
                appendedBytes: 0
            )
        }

        var attachments: [Int: Attachment] = [:]
        /// 把带 /Rotate 的页面「摆正」：MediaBox 换成视觉尺寸、删掉 /Rotate，
        /// 并把原内容流包进一层旋转变换。
        ///
        /// 摆正后页面本身就是阅读器看到的方向，水印按普通页面处理即可铺满。
        /// 图片等资源只是被引用、不会重新编码，所以无损——
        /// 与预览.app「打印→存储为 PDF」的做法一致，但保住了文字层。
        func num(_ v: CGFloat) -> String { String(format: "%.2f", v) }
        func makeUprightContent(for page: PDFPageInfo) -> PageUpright? {
            let rotation = PDFPageGeometry.normalize(page.rotation)
            guard rotation != 0 else { return nil }

            var refs: [PDFObject] = []
            for candidate in [page.contents, page.dictionary["Contents"]] {
                guard let value = candidate else { continue }
                if case .reference = value { refs.append(value) }
                else if let array = value.asArray { refs.append(contentsOf: array) }
                if !refs.isEmpty { break }
            }
            guard !refs.isEmpty else { return nil }

            var combined = Data()
            for ref in refs {
                guard let obj = document.resolve(ref),
                      case .stream(let s) = obj,
                      let decoded = document.decodeStream(s) else { return nil }
                combined.append(decoded)
                if combined.last != 0x0A { combined.append(0x0A) }
            }
            guard !combined.isEmpty else { return nil }

            let box = page.mediaBox
            // 把「原内容坐标」映射到「摆正后的页面坐标」
            let matrix: String
            switch rotation {
            case 90:  matrix = "0 -1 1 0 0 \(num(box.width))"
            case 180: matrix = "-1 0 0 -1 \(num(box.width)) \(num(box.height))"
            case 270: matrix = "0 1 -1 0 \(num(box.height)) 0"
            default:  return nil
            }

            let wrapped = Data("q\n\(matrix) cm\n".utf8) + combined + Data("Q\n".utf8)
            let number = allocator.allocate()
            newObjects.append(NewObject(
                number: number,
                generation: 0,
                object: .stream(PDFStream(dictionary: [:], data: wrapped))
            ))

            let newBox = (rotation == 90 || rotation == 270)
                ? CGRect(x: 0, y: 0, width: box.height, height: box.width)
                : box
            return PageUpright(
                contentRef: .reference(objectNumber: number, generation: 0),
                mediaBox: newBox
            )
        }

        var uprights: [Int: PageUpright] = [:]
        for page in pages where targets.contains(page.objectNumber) {
            let box = page.mediaBox

            // 先把带 /Rotate 的页面「摆正」：换 MediaBox、删 /Rotate、把原内容包进旋转变换。
            // 摆正之后它就是个普通页面，水印按常规坐标系平铺即可自然铺满，
            // 不必再靠补偿矩阵去猜阅读器的旋转——那条路实测只能盖到一半。
            let upright = makeUprightContent(for: page)
            if let upright {
                uprights[page.objectNumber] = upright
            }

            let canvas = upright?.mediaBox.size
                ?? PDFPageGeometry.visualSize(box: box, rotation: page.rotation)
            let content = try builder.makeContentStream(
                canvasSize: canvas,
                pageRotation: upright == nil ? page.rotation : 0
            )

            // 注释永远渲染在页面内容之上，所以「有注释」时内容流水印会被盖住。
            // 但注释方案本身稳定性不如内容流（实测某些阅读器不接受我们构造的注释外观流），
            // 所以只在「注释确实大面积遮挡」时才走注释方案：
            //   - 整页平铺的图形水印（如发票的「下载次数」）→ 必须走注释
            //   - 只有一个小签名域/印章（只占页面百分之几）→ 走内容流更可靠，
            //     水印仅在那枚印章的很小一块被遮住，其余照常可见
            let useAnnotation = annotationCoverage(
                annotationArray(page.dictionary["Annots"]), pageSize: box.size
            ) > 0.3

            // 页面摆正后，注释与 Form 的尺寸要用新的 MediaBox
            let rectBox = upright?.mediaBox ?? box

            if useAnnotation {
                // 整页水印做成一个 Form，充当注释的外观流
                let formNumber = allocator.allocate()
                let formDict: [String: PDFObject] = [
                    "Type": .name("XObject"),
                    "Subtype": .name("Form"),
                    "BBox": .array([
                        .real(0), .real(0),
                        .real(Double(rectBox.width)), .real(Double(rectBox.height))
                    ]),
                    "Resources": .dictionary(sharedResources)
                ]
                newObjects.append(NewObject(
                    number: formNumber,
                    generation: 0,
                    object: .stream(PDFStream(dictionary: formDict, data: content))
                ))

                let annotNumber = allocator.allocate()
                let annotDict: [String: PDFObject] = [
                    "Type": .name("Annot"),
                    // 用 Square 而非 Stamp：PDFKit 会把 Stamp 渲染在 Square 之下，
                    // 遇到页面自带方形批注时水印仍会被盖住。Square 之间则按 /Annots 顺序。
                    "Subtype": .name("Square"),
                    "Rect": .array([
                        .real(0), .real(0),
                        .real(Double(rectBox.width)), .real(Double(rectBox.height))
                    ]),
                    "AP": .dictionary(["N": .reference(objectNumber: formNumber, generation: 0)]),
                    // F 的 bit 3 = 打印时同样输出
                    "F": .integer(4)
                ]
                newObjects.append(NewObject(
                    number: annotNumber,
                    generation: 0,
                    object: .dictionary(annotDict)
                ))
                attachments[page.objectNumber] = .annotation(
                    .reference(objectNumber: annotNumber, generation: 0)
                )
            } else {
                let streamNumber = allocator.allocate()
                // 内容流刻意不压缩：PDFKit 会拒绝这里自行生成的 zlib 流
                newObjects.append(NewObject(
                    number: streamNumber,
                    generation: 0,
                    object: .stream(PDFStream(dictionary: [:], data: content))
                ))
                attachments[page.objectNumber] = .contentStream(
                    .reference(objectNumber: streamNumber, generation: 0)
                )
            }
        }

        guard let rootRef = document.trailer["Root"],
              case .reference(let rootNumber, _) = rootRef else {
            throw WatermarkError.malformedPDF("trailer 缺少 /Root")
        }

        // 页对象号 → 实际生效的 /Resources。页面自身没有时要用从父节点继承的那份，
        // 否则重建页树会把继承来的字体/图片资源覆盖掉
        var effectiveResources: [Int: PDFObject] = [:]
        for page in pages {
            if let resources = page.resources {
                effectiveResources[page.objectNumber] = resources
            }
        }

        let rebuilder = TreeRebuilder(
            document: document,
            allocator: allocator,
            targets: targets,
            sharedResources: sharedResources,
            attachments: attachments,
            inheritedResources: effectiveResources,
            uprights: uprights,
            placement: config.pdf.placement
        )
        var visitedNodes: Set<Int> = []
        let newRoot = try rebuilder.rebuild(nodeNumber: rootNumber, parentNumber: nil, visited: &visitedNodes)
        newObjects.append(contentsOf: rebuilder.newObjects)

        let lastNumber = newObjects.map { $0.number }.max() ?? startNumber
        let size = max(document.nextObjectNumber, lastNumber + 1)
        let output = assemble(newObjects: newObjects, size: size, newRoot: newRoot)

        return Result(
            data: output,
            pageCount: pages.count,
            watermarkedPages: targets.count,
            appendedBytes: output.count - document.data.count
        )
    }

    // MARK: - 页树重建

    /// /Annots 既可能是内联数组，也可能是指向数组的间接引用
    private func annotationArray(_ value: PDFObject?) -> [PDFObject] {
        guard let value else { return [] }
        if let array = value.asArray { return array }
        if let resolved = document.resolve(value), let array = resolved.asArray { return array }
        return []
    }

    /// 注释占据页面的面积比例（0...1）。用于判断内容流水印会不会被大面积遮住。
    /// 这里按矩形面积累加估算，忽略重叠——目的只是区分「整页水印」和「一枚小印章」。
    private func annotationCoverage(_ annots: [PDFObject], pageSize: CGSize) -> Double {
        guard !annots.isEmpty, pageSize.width > 0, pageSize.height > 0 else { return 0 }
        var covered: Double = 0
        for annot in annots {
            let dict: [String: PDFObject]?
            if case .reference(let n, _) = annot {
                dict = document.object(number: n)?.asDictionary
            } else {
                dict = annot.asDictionary
            }
            guard let rect = dict?["Rect"]?.asArray, rect.count == 4,
                  let x0 = rect[0].asDouble, let y0 = rect[1].asDouble,
                  let x1 = rect[2].asDouble, let y1 = rect[3].asDouble else { continue }
            let w = abs(x1 - x0), h = abs(y1 - y0)
            let xLow = max(min(x0, x1), 0), xHigh = min(max(x0, x1), pageSize.width)
            let yLow = max(min(y0, y1), 0), yHigh = min(max(y0, y1), pageSize.height)
            guard xHigh > xLow, yHigh > yLow else { continue }
            covered += (xHigh - xLow) * (yHigh - yLow)
            _ = w; _ = h
        }
        return min(covered / (pageSize.width * pageSize.height), 1.0)
    }

    private final class TreeRebuilder {
        let document: PDFRawDocument
        let allocator: PDFObjectNumberAllocator
        let targets: Set<Int>
        let sharedResources: [String: PDFObject]
        let attachments: [Int: Attachment]
        let placement: WatermarkPlacement

        var newObjects: [NewObject] = []
        var resourcesCache: [Int: Int] = [:]
        /// 页对象号 → 该页实际生效的 /Resources（自身 ?? 继承）
        let inheritedResources: [Int: PDFObject]
        /// 页对象号 → 摆正结果（仅带 /Rotate 的页面才有）
        let uprights: [Int: PageUpright]

        init(
            document: PDFRawDocument,
            allocator: PDFObjectNumberAllocator,
            targets: Set<Int>,
            sharedResources: [String: PDFObject],
            attachments: [Int: Attachment],
            inheritedResources: [Int: PDFObject],
            uprights: [Int: PageUpright],
            placement: WatermarkPlacement
        ) {
            self.document = document
            self.allocator = allocator
            self.targets = targets
            self.sharedResources = sharedResources
            self.attachments = attachments
            self.inheritedResources = inheritedResources
            self.uprights = uprights
            self.placement = placement
        }

        /// 返回该节点的新引用；子树无变动时返回原引用，避免产生多余对象
        func rebuild(nodeNumber: Int, parentNumber: Int?, visited: inout Set<Int>) throws -> PDFObject {
            // 页树成环（自引用或互为父子）会导致无限递归崩溃，必须挡住
            guard !visited.contains(nodeNumber) else { return originalReference(nodeNumber) }
            visited.insert(nodeNumber)

            guard let node = document.object(number: nodeNumber),
                  var dict = node.asDictionary else {
                return originalReference(nodeNumber)
            }

            // Catalog 走的是 /Pages，不是 /Kids——必须先单独处理，否则整棵树不会被重建
            if node["Kids"] == nil,
               let pagesRef = node["Pages"],
               case .reference(let pagesNumber, _) = pagesRef {
                guard subtreeContainsTarget(pagesNumber) else {
                    return originalReference(nodeNumber)
                }
                let newNumber = allocator.allocate()
                dict["Pages"] = try rebuild(nodeNumber: pagesNumber, parentNumber: nil, visited: &visited)
                newObjects.append(NewObject(number: newNumber, generation: 0, object: .dictionary(dict)))
                return .reference(objectNumber: newNumber, generation: 0)
            }

            if let kids = node["Kids"]?.asArray {
                let childNumbers = kids.compactMap { kid -> Int? in
                    if case .reference(let n, _) = kid { return n }
                    return nil
                }
                guard childNumbers.contains(where: { subtreeContainsTarget($0) }) else {
                    return originalReference(nodeNumber)
                }

                let newNumber = allocator.allocate()
                var newKids: [PDFObject] = []
                for kid in kids {
                    guard case .reference(let kidNumber, _) = kid else {
                        newKids.append(kid)
                        continue
                    }
                    if subtreeContainsTarget(kidNumber) {
                        newKids.append(try rebuild(nodeNumber: kidNumber, parentNumber: newNumber, visited: &visited))
                    } else {
                        newKids.append(kid)
                    }
                }
                dict["Kids"] = .array(newKids)
                if let parentNumber {
                    dict["Parent"] = .reference(objectNumber: parentNumber, generation: 0)
                }
                newObjects.append(NewObject(number: newNumber, generation: 0, object: .dictionary(dict)))
                return .reference(objectNumber: newNumber, generation: 0)
            }

            // 叶子节点：页面
            guard let attachment = attachments[nodeNumber] else {
                return originalReference(nodeNumber)
            }

            switch attachment {
            case .contentStream(let watermarkRef):
                var existingContents: [PDFObject] = []
                if case .reference = node["Contents"] {
                    existingContents.append(node["Contents"]!)
                } else if let array = node["Contents"]?.asArray {
                    existingContents.append(contentsOf: array)
                }

                // 页面被摆正时，原内容已被包进旋转变换，MediaBox 与 /Rotate 一并更新
                if let upright = uprights[nodeNumber] {
                    existingContents = [upright.contentRef]
                    dict["MediaBox"] = .array([
                        .real(0), .real(0),
                        .real(Double(upright.mediaBox.width)),
                        .real(Double(upright.mediaBox.height))
                    ])
                    dict.removeValue(forKey: "Rotate")
                }

                dict["Contents"] = placement == .above
                    ? .array(existingContents + [watermarkRef])
                    : .array([watermarkRef] + existingContents)
                dict["Resources"] = mergedResources(for: dict, objectNumber: nodeNumber)

            case .annotation(let annotRef):
                // 展开后追加到末尾，保证排在所有既有注释之上
                var annots = annotationArray(dict["Annots"])
                annots.append(annotRef)
                dict["Annots"] = .array(annots)
                // 不动 /Contents：注释本来就渲染在内容之上
            }

            if let parentNumber {
                dict["Parent"] = .reference(objectNumber: parentNumber, generation: 0)
            }

            let newNumber = allocator.allocate()
            newObjects.append(NewObject(number: newNumber, generation: 0, object: .dictionary(dict)))
            return .reference(objectNumber: newNumber, generation: 0)
        }

        private func originalReference(_ number: Int) -> PDFObject {
            .reference(objectNumber: number, generation: document.generation(of: number))
        }

        /// /Annots 既可能是内联数组，也可能是指向数组的间接引用
        private func annotationArray(_ value: PDFObject?) -> [PDFObject] {
            guard let value else { return [] }
            if let array = value.asArray { return array }
            if let resolved = document.resolve(value), let array = resolved.asArray { return array }
            return []
        }

        private func subtreeContainsTarget(_ number: Int) -> Bool {
            if targets.contains(number) { return true }
            guard let node = document.object(number: number),
                  let kids = node["Kids"]?.asArray else { return false }
            for kid in kids {
                if case .reference(let n, _) = kid, subtreeContainsTarget(n) { return true }
            }
            return false
        }

        private func mergedResources(for page: [String: PDFObject], objectNumber: Int) -> PDFObject {
            // /Resources 是可继承属性：页面自己没声明时会从 Pages 祖先继承。
            // 这里若只写水印资源，等于整体覆盖掉继承来的 /Font、/XObject、/ExtGState，
            // 正文文字与图片会整页消失——只剩水印。
            let existing = page["Resources"] ?? inheritedResources[objectNumber]
            guard let existing else { return .dictionary(sharedResources) }

            if case .reference(let number, _) = existing {
                if let cached = resourcesCache[number] {
                    return .reference(objectNumber: cached, generation: 0)
                }
                guard let resolved = document.resolve(existing), var dict = resolved.asDictionary else {
                    return .dictionary(sharedResources)
                }
                merge(into: &dict, shared: sharedResources)
                let newNumber = allocator.allocate()
                resourcesCache[number] = newNumber
                newObjects.append(NewObject(number: newNumber, generation: 0, object: .dictionary(dict)))
                return .reference(objectNumber: newNumber, generation: 0)
            }

            if var dict = existing.asDictionary {
                merge(into: &dict, shared: sharedResources)
                return .dictionary(dict)
            }

            return .dictionary(sharedResources)
        }

        private func merge(into dict: inout [String: PDFObject], shared: [String: PDFObject]) {
            for (key, value) in shared {
                if var existingDict = dict[key]?.asDictionary, let addition = value.asDictionary {
                    for (k, v) in addition { existingDict[k] = v }
                    dict[key] = .dictionary(existingDict)
                } else {
                    dict[key] = value
                }
            }
        }
    }

    // MARK: - 组装

    private func assemble(newObjects: [NewObject], size: Int, newRoot: PDFObject) -> Data {
        var out = Data()
        out.append(document.data)
        if out.last != 0x0A { out.append(0x0A) }

        var entries: [(number: Int, generation: Int, offset: Int)] = []
        for item in newObjects.sorted(by: { $0.number < $1.number }) {
            let offset = out.count
            out.append(contentsOf: "\(item.number) \(item.generation) obj\n".utf8)
            out.append(item.object.serialized())
            out.append(contentsOf: "\nendobj\n".utf8)
            entries.append((item.number, item.generation, offset))
        }

        let xrefOffset = out.count
        out.append(buildXref(entries: entries))
        out.append(buildTrailer(size: size, newRoot: newRoot))
        out.append(contentsOf: "startxref\n\(xrefOffset)\n%%EOF\n".utf8)
        return out
    }

    private func buildXref(entries: [(number: Int, generation: Int, offset: Int)]) -> Data {
        var all: [(number: Int, generation: Int, offset: Int, free: Bool)] = [(0, 65535, 0, true)]
        for entry in entries {
            all.append((entry.number, entry.generation, entry.offset, false))
        }
        all.sort { $0.number < $1.number }

        var out = Data()
        out.append(contentsOf: "xref\n".utf8)

        var i = 0
        while i < all.count {
            var j = i
            while j + 1 < all.count && all[j + 1].number == all[j].number + 1 {
                j += 1
            }
            out.append(contentsOf: "\(all[i].number) \(j - i + 1)\n".utf8)
            for k in i...j {
                if all[k].free {
                    out.append(xrefEntry(offset: 0, generation: 65535, type: "f"))
                } else {
                    out.append(xrefEntry(offset: all[k].offset, generation: all[k].generation, type: "n"))
                }
            }
            i = j + 1
        }
        return out
    }

    private func xrefEntry(offset: Int, generation: Int, type: String) -> Data {
        let line = String(format: "%010d %05d %@\r\n", min(offset, 9_999_999_999), generation, type)
        return Data(line.utf8)
    }

    private func buildTrailer(size: Int, newRoot: PDFObject) -> Data {
        var dict = document.trailer
        dict["Size"] = .integer(size)
        dict["Prev"] = .integer(document.startxrefOffset)
        dict["Root"] = newRoot
        dict.removeValue(forKey: "XRefStm")

        var out = Data()
        out.append(contentsOf: "trailer\n".utf8)
        out.append(PDFObject.dictionary(dict).serialized())
        out.append(contentsOf: "\n".utf8)
        return out
    }
}
