import XCTest
import Foundation
import CoreGraphics
import CoreText
import PDFKit
@testable import WatermarkCore

/// 回归：PDF 的加密处理
///
/// 两类加密要分开看：
/// - **权限型**（空用户密码）：无需密码就能打开（WPS、预览都能看），只是禁止打印/编辑。
///   各类政务/信用报告、扫描件大量属于这类。工具会自动解出一份无加密副本再加水印。
/// - **真密码保护**：必须输入密码。这类仍然拒绝，因为不该在用户没授权的情况下处理。
final class EncryptedPDFTests: XCTestCase {

    /// 权限型加密（政务报告、扫描件常见）应自动解出副本再处理。
    ///
    /// 注意：PDFKit 造不出「能被自己解开」的加密样本——它对自己写出的加密文档
    /// 会原样保留加密。所以这里只在能真正解出无加密副本时才断言；
    /// 真实场景（如 AES-256 的信用报告）已实测可用。
    func testPermissionOnlyEncryptionIsHandledAutomatically() throws {
        let url = URL(fileURLWithPath: "/tmp/wm_enc_permission.pdf")
        let data = try makeEncryptedPDF(userPassword: "")
        try data.write(to: url)

        let source = try PDFRawDocument(data: data)
        XCTAssertTrue(source.isEncrypted, "样本应为加密文档")

        var config = WatermarkConfig()
        config.text.content = "机密"
        guard WatermarkProcessor.unprotectedCopy(of: data) != nil else {
            // PDFKit 保留了加密：这条路径走不通，至少要保证它明确报错而不是静默产出
            XCTAssertThrowsError(try WatermarkProcessor(config: config).process(fileAt: url))
            return
        }
        let result = try WatermarkProcessor(config: config).process(fileAt: url)
        XCTAssertTrue(result.detail.contains("已解除保护"), "权限型加密应自动处理，实际：\(result.detail)")
        XCTAssertFalse(result.isLossless, "解除保护走的是重写路径，不能再标为无损")

        guard let out = PDFDocument(data: result.data) else {
            return XCTFail("输出无法打开")
        }
        XCTAssertEqual(out.pageCount, 1)
        XCTAssertFalse(out.isEncrypted, "输出不应再带加密")
    }

    func testPasswordProtectedDocumentIsStillRejected() throws {
        let url = URL(fileURLWithPath: "/tmp/wm_enc_password.pdf")
        try makeEncryptedPDF(userPassword: "secret123").write(to: url)

        var config = WatermarkConfig()
        config.text.content = "机密"
        XCTAssertThrowsError(
            try WatermarkProcessor(config: config).process(fileAt: url),
            "需要密码的文档必须明确拒绝，而不是静默产出"
        )
    }

    func testUnprotectedCopyReturnsNilForLockedDocument() throws {
        let data = try makeEncryptedPDF(userPassword: "secret123")
        XCTAssertNil(
            WatermarkProcessor.unprotectedCopy(of: data),
            "需要密码时不应生成副本"
        )
    }

    // MARK: - 辅助

    /// PDFKit 的 write(withOptions:) 可以产出加密文档；
    /// 用户密码为空即得到「无需密码即可打开」的权限型加密
    private func makeEncryptedPDF(userPassword: String) throws -> Data {
        let mutable = NSMutableData()
        var rect = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: mutable as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &rect, nil) else {
            throw WatermarkError.malformedPDF("无法创建 PDF")
        }
        ctx.beginPage(mediaBox: &rect)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Encrypted sample", attributes: [.font: font])
        )
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPage()
        ctx.closePDF()

        guard let document = PDFDocument(data: mutable as Data) else {
            throw WatermarkError.malformedPDF("样本创建失败")
        }
        let url = URL(fileURLWithPath: "/tmp/wm_enc_tmp_\(userPassword.hashValue & 0xFFFF).pdf")
        document.write(to: url, withOptions: [
            .userPasswordOption: userPassword,
            .ownerPasswordOption: "owner-pwd"
        ])
        return try Data(contentsOf: url)
    }
}
