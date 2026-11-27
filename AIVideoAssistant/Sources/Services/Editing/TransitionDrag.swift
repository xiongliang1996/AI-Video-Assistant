//
//  TransitionDrag.swift
//  时间线上拖转场重叠区的纯函数部分
//

import CoreGraphics

enum TransitionDragGeometry {
    /// 最短转场时长（和属性面板滑杆的下界一致）
    static let minimum: Double = 0.15

    /// 吸附网格（秒）。0.05 够细，又能顺手拖出 0.3 / 0.6 / 1.0 这种整数
    static let step: Double = 0.05

    /// 手柄离片段左边缘的最小距离。
    ///
    /// 左侧还压着裁剪手柄（12pt 宽），转场很短时如果手柄贴着重叠区右边缘画，
    /// 两个手柄会完全重合，裁剪就抓不住了。
    static let handleInset: CGFloat = 15

    /// 拖动重叠区右边缘时算出的新时长。
    ///
    /// - Parameters:
    ///   - origin: 按下那一刻的时长（每帧从它重算，拖过头再拖回来能原路返回）
    ///   - translation: 水平位移，向右为正
    ///   - pps: 每秒像素数
    ///   - ceiling: 渲染器能接受的最大重叠（`TimelineLayout.transitionCeiling`）
    static func duration(origin: Double,
                         translation: CGFloat,
                         pps: CGFloat,
                         ceiling: Double) -> Double {
        let safePPS = max(1, pps)
        let raw = max(0, origin) + Double(translation) / Double(safePPS)
        // 上限至少给到最小值：前一段太短时也得让人把转场拖到最短，
        // 否则手柄会卡在一个永远拖不动的位置
        let upper = max(minimum, min(ceiling, TimelineLayout.transitionMaxOverlap))
        let snapped = (raw / step).rounded() * step
        let clamped = min(upper, max(minimum, snapped))
        // 0.05 的整数倍乘出来会带浮点尾巴（0.30000000000000004），收拾干净
        return (clamped * 1000).rounded() / 1000
    }

    /// 手柄中心离片段左边缘的像素距离
    static func handleX(overlapWidth: CGFloat) -> CGFloat {
        max(max(0, overlapWidth), handleInset)
    }
}
