//
//  TransitionGeometry.swift
//  转场曲线的纯函数部分
//
//  只描述「某一进度下两层各自的不透明度 / 缩放 / 位移」，不碰 AVFoundation。
//  系统合成器把它翻成 ramp，自绘合成器把它当采样点，两边共用同一份实现。
//

import CoreGraphics

/// 转场在某一进度下的系数
struct TransitionCurve: Equatable {
    var outAlpha: Double = 1
    var inAlpha: Double = 0
    /// 绕画幅中心缩放（1 = 不缩放）
    var outScale: CGFloat = 1
    var inScale: CGFloat = 1
    /// 渲染坐标系里的位移，**y 向下**
    var outOffset: CGSize = .zero
    var inOffset: CGSize = .zero

    /// 「无转场」的形态：两层都不动、都不透明
    static let identity = TransitionCurve(outAlpha: 1, inAlpha: 1)
}

enum TransitionGeometry {

    /// 缩放类转场的入场起手比例 / 出场收尾比例
    static let zoomInStart: CGFloat = 0.86
    static let zoomOutEnd: CGFloat = 1.15

    /// 某进度下两层的状态。`progress` 会被夹到 0...1。
    static func curve(_ type: TransitionType,
                      progress: Double,
                      renderSize: CGSize) -> TransitionCurve {
        let p = min(1, max(0, progress))
        let w = max(0, renderSize.width)
        let h = max(0, renderSize.height)

        switch type {
        case .none:
            return TransitionCurve(outAlpha: 1, inAlpha: 1)

        case .crossDissolve:
            return TransitionCurve(outAlpha: 1 - p, inAlpha: p)

        case .fadeThroughBlack:
            // 前半段前一段淡出到全黑，后半段后一段从全黑淡入。
            // 两半在中点必须恰好交接，否则中间会漏一格全黑或叠一格
            if p < 0.5 {
                return TransitionCurve(outAlpha: 1 - p * 2, inAlpha: 0)
            } else {
                return TransitionCurve(outAlpha: 0, inAlpha: (p - 0.5) * 2)
            }

        case .slideLeft:
            // 前一段往左走出画面，后一段从右边补上来（推入，不是叠化）
            return TransitionCurve(outAlpha: 1, inAlpha: 1,
                                   outOffset: CGSize(width: -w * p, height: 0),
                                   inOffset: CGSize(width: w * (1 - p), height: 0))

        case .slideRight:
            return TransitionCurve(outAlpha: 1, inAlpha: 1,
                                   outOffset: CGSize(width: w * p, height: 0),
                                   inOffset: CGSize(width: -w * (1 - p), height: 0))

        case .slideUp:
            // y 向下：往上走是负
            return TransitionCurve(outAlpha: 1, inAlpha: 1,
                                   outOffset: CGSize(width: 0, height: -h * p),
                                   inOffset: CGSize(width: 0, height: h * (1 - p)))

        case .slideDown:
            return TransitionCurve(outAlpha: 1, inAlpha: 1,
                                   outOffset: CGSize(width: 0, height: h * p),
                                   inOffset: CGSize(width: 0, height: -h * (1 - p)))

        case .zoomIn:
            // 后一段从略小推到原位，同时淡入；前一段淡出
            let s = zoomInStart + (1 - zoomInStart) * CGFloat(p)
            return TransitionCurve(outAlpha: 1 - p, inAlpha: p, inScale: s)

        case .zoomOut:
            // 前一段一边放大一边淡出，后一段在原位淡入——镜头被「拉近」
            let s = 1 + (zoomOutEnd - 1) * CGFloat(p)
            return TransitionCurve(outAlpha: 1 - p, inAlpha: p, outScale: s)
        }
    }

    /// 曲线在哪些进度上是「折点」，必须恰好采到。
    ///
    /// 黑场过渡是分段函数，只取两端再线性插值会变成一次普通交叉溶解——
    /// 自绘合成器（圆角 / 调色时才走）踩过这个坑。
    static func breakpoints(_ type: TransitionType) -> [Double] {
        switch type {
        case .fadeThroughBlack: return [0, 0.5, 1]
        default: return [0, 1]
        }
    }
}
