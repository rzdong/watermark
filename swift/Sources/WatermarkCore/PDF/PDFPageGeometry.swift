import Foundation
import CoreGraphics

/// 页面旋转（/Rotate）的几何换算。
///
/// 阅读器会按 /Rotate 把整页顺时针转 θ 度后显示，所以「看到的样子」和
/// 「MediaBox 里写的坐标」是两套东西。预览画布必须按看到的样子来建，
/// 否则横向页面（如 /Rotate 270）会显示成横躺的一条。
public enum PDFPageGeometry {

    /// 阅读器实际呈现的画布尺寸：/Rotate 为 90/270 时宽高互换
    public static func visualSize(box: CGRect, rotation: Int) -> CGSize {
        let normalized = Self.normalize(rotation)
        return (normalized == 90 || normalized == 270)
            ? CGSize(width: box.height, height: box.width)
            : CGSize(width: box.width, height: box.height)
    }

    /// 把当前坐标系旋成「原始 MediaBox 坐标系」，
    /// 之后页面内容与水印都能直接按原始坐标绘制，预览与导出天然一致。
    ///
    /// 变换顺序必须「先旋转、后平移」——CoreGraphics 的 CTM 是右乘累积的，
    /// 反了会把页面转出画布。
    public static func applyRotation(to context: CGContext, rotation: Int, box: CGRect) {
        switch Self.normalize(rotation) {
        case 90:    // 顺时针 90：(x,y) → (y, W-x)
            context.rotate(by: -.pi / 2)
            context.translateBy(x: 0, y: box.width)
        case 180:   // (x,y) → (W-x, H-y)
            context.rotate(by: .pi)
            context.translateBy(x: box.width, y: box.height)
        case 270:   // 顺时针 270 → 逆时针 90：(x,y) → (H-y, x)
            context.rotate(by: .pi / 2)
            context.translateBy(x: box.height, y: 0)
        default:
            break
        }
    }

    /// 「视觉坐标 → 页面原始坐标」的 PDF cm 矩阵（**仅回退路径使用**）。
    ///
    /// 正常流程下页面会先被「摆正」（见 PDFIncrementalWriter.makeUprightContent），
    /// 此时 rotation 已经是 0、不会走到这里。只有摆正失败（比如内容流解压不了）
    /// 才退回这套补偿矩阵，代价是覆盖率只有五六成。
    ///
    /// 这里的取值是**逐个渲染实测**选出来的，不是推导出来的。
    /// 曾经照 `CGPDFPage.getDrawingTransform` 的逆矩阵写过一版，结果更差——
    /// 那个 API 给的不是渲染时真正使用的变换，别再信它。
    ///
    /// - Parameter box: **视觉画布**尺寸（90/270 时已互换过）
    public static func inverseRotationMatrix(box: CGSize, rotation: Int) -> String? {
        switch normalize(rotation) {
        case 0:
            return nil
        case 90:
            // 实测标定（见下方 270 的说明）：90° 用「0 -1 1 0 0 W」
            return "0 -1 1 0 0 \(num(box.width))"
        case 180:   // 逆即自身
            return "-1 0 0 -1 \(num(box.width)) \(num(box.height))"
        case 270:
            // 四种候选矩阵逐个渲染实测过，这一组覆盖率最高（56%×42%，
            // 渲染墨迹比另一组多 65%）。注意 90 与 270 的写法是互换的——
            // 按 PDF 规范推导出来的那组反而会让水印缩到右下一角。
            return "0 1 -1 0 \(num(box.height)) 0"
        default:
            return nil
        }
    }

    /// 当前选用的矩阵是否会让水印多转 180°。
    ///
    /// 覆盖率最优的那组矩阵（90/270 互换写法）附带一个 180° 翻转，
    /// 直接用的话文字是倒的；调用方需要把水印角度补 180° 抵消。
    public static func usesFlippedMatrix(rotation: Int) -> Bool {
        switch normalize(rotation) {
        case 90, 270: return true
        default: return false
        }
    }

    private static func num(_ v: CGFloat) -> String {
        String(format: "%.2f", v)
    }

    public static func normalize(_ rotation: Int) -> Int {
        ((rotation % 360) + 360) % 360
    }
}
