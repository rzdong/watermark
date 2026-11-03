import Foundation
import Compression

/// 系统自带的 zlib 编解码。不引入任何第三方依赖。
public enum PDFCodec {
    /// 压缩成标准 zlib 容器（RFC 1950，带 2 字节头）。
    ///
    /// 注意：`compression_encode_buffer(COMPRESSION_ZLIB)` 产出的是**裸 deflate**
    /// （RFC 1951，没有 zlib 头），直接塞进 PDF 的 /FlateDecode 会让部分阅读器
    /// （含 Apple PDFKit）解不开。所以这里按 RFC 1950 手动补上 CMF/FLG 头与 Adler32 尾。
    public static func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        guard let body = rawDeflateEncode([UInt8](data)) else { return data }

        // CMF = 0x78（CM=8 deflate, CINFO=7），FLG 需满足 (CMF<<8 | FLG) % 31 == 0
        let cmf: UInt8 = 0x78
        let flg: UInt8 = 0x9C
        var out = Data([cmf, flg])
        out.append(body)
        // 大端 Adler32
        var checksum = adler32(of: data)
        for _ in 0..<4 {
            out.append(UInt8((checksum >> 24) & 0xFF))
            checksum <<= 8
        }
        return out
    }

    /// 解开 PDF 的 /FlateDecode（标准 zlib 容器）。
    ///
    /// 这里是踩过坑的地方，务必保持现状：
    /// 1. **不能用** `(NSData).decompressed(using: .zlib)`——实测它对这些流一律返回 nil。
    /// 2. **不能直接**把整段数据喂给 `compression_decode_buffer`——它解的是**裸 deflate**，
    ///    会把 zlib 的 2 字节头当成数据吃掉，产出 328 字节的垃圾（正确应为 576 字节），
    ///    表现为「xref stream 解压失败」，整份 PDF 打不开。
    ///    正确做法：先剥掉 zlib 头，再按裸 deflate 解。
    public static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let source = [UInt8](data)

        if Self.hasZlibHeader(source) {
            if let decoded = rawDeflateDecode(Array(source.dropFirst(2))) { return decoded }
        }
        // 少数文件缺 zlib 头，退化为裸 deflate
        return rawDeflateDecode(source)
    }

    // MARK: - 内部

    /// 校验 RFC 1950 的 zlib 头：CM 必须为 8，且 (CMF<<8 | FLG) 能被 31 整除
    private static func hasZlibHeader(_ s: [UInt8]) -> Bool {
        guard s.count >= 2 else { return false }
        let cmf = s[0], flg = s[1]
        guard (cmf & 0x0F) == 8 else { return false }
        return (Int(cmf) << 8 | Int(flg)) % 31 == 0
    }

    /// 裸 deflate 解码；输出大小事先未知，按 4 倍起步、不够就翻倍
    private static func rawDeflateDecode(_ source: [UInt8]) -> Data? {
        guard !source.isEmpty else { return Data() }
        var capacity = max(source.count * 4, 64 * 1024)
        for _ in 0..<14 {
            var destination = [UInt8](repeating: 0, count: capacity)
            let size = destination.withUnsafeMutableBytes { dst -> Int in
                source.withUnsafeBytes { src -> Int in
                    compression_decode_buffer(
                        dst.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        capacity,
                        src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        source.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if size == 0 { return nil }
            // 正好装满说明可能还没解完，扩容重试
            if size < capacity { return Data(destination[0..<size]) }
            capacity *= 2
        }
        return nil
    }

    private static func rawDeflateEncode(_ source: [UInt8]) -> Data? {
        guard !source.isEmpty else { return Data() }
        let capacity = source.count + 1024
        var destination = [UInt8](repeating: 0, count: capacity)
        let size = destination.withUnsafeMutableBytes { dst -> Int in
            source.withUnsafeBytes { src -> Int in
                compression_encode_buffer(
                    dst.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    capacity,
                    src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard size > 0, size <= capacity else { return nil }
        return Data(destination[0..<size])
    }

    private static func adler32(of data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}
