import Foundation

/// 增量更新中新对象的编号分配器。从原文档的 /Size 之后开始，绝不复用已有编号。
public final class PDFObjectNumberAllocator {
    private var next: Int

    public init(startingAt: Int) {
        self.next = startingAt
    }

    public func allocate() -> Int {
        let n = next
        next += 1
        return n
    }
}
