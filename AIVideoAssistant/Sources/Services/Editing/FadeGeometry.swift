//
//  FadeGeometry.swift
//  时间线淡入淡出拖手柄的纯计算：吸附 / 限位 / 手柄落点
//
//  这些函数不碰视图也不碰 AppState，拖拽逻辑能单独断言。
//

import CoreGraphics

/// 拖的是哪一侧
enum FadeEdge: String {
    case fadeIn
    case fadeOut

    var label: String { self == .fadeIn ? "淡入" : "淡出" }
}

enum FadeGeometry {
    /// 小于这个值就当没设——拖回角落时能干脆地关掉，而不是留个 0.03 秒的尾巴
    static let minimum: Double = 0.06

    /// 吸附网格（秒）。0.05 秒足够细，又能顺手拖出 0.5 / 1.0 这种整数
    static let step: Double = 0.05

    /// 两侧之间留的缝，避免淡入淡出接成三角波
    static let gap: Double = 0.02

    /// 这一侧最长能拖到多少。
    ///
    /// 上限取「片段时长的一半」而不是「时长减去另一侧」，因为合成器里
    /// `min(fadeIn, 时长*0.5)` 就是这么钳的：手柄拖过一半，画面不会再多淡一点，
    /// 只会让人以为设了 1.8 秒其实只有 1 秒。手柄上限必须和渲染上限一致。
    static func maxLength(duration: Double, other: Double) -> Double {
        guard duration > 0 else { return 0 }
        let half = duration * 0.5
        let room = duration - max(0, other) - gap
        return max(0, min(half, room))
    }

    /// 从拖拽起点算出新的淡入 / 淡出秒数
    /// - Parameters:
    ///   - origin: 按下时的值（不是当前值，避免逐帧累加漂移）
    ///   - translation: 从按下点到现在的水平位移，向右为正
    ///   - edge: 淡入向右变长，淡出向左变长
    static func value(origin: Double,
                      translation: CGFloat,
                      pps: CGFloat,
                      duration: Double,
                      other: Double,
                      edge: FadeEdge) -> Double {
        guard pps > 0, translation.isFinite else { return max(0, origin) }
        let delta = Double(translation) / Double(pps)
        let raw = edge == .fadeIn ? origin + delta : origin - delta
        return snap(raw, duration: duration, other: other)
    }

    /// 夹到合法区间并吸附到 0.05 秒网格；贴近上限时直接贴上上限
    static func snap(_ raw: Double, duration: Double, other: Double) -> Double {
        guard duration > 0, raw.isFinite else { return 0 }
        let limit = maxLength(duration: duration, other: other)
        // 上限本身太短，淡入淡出没有意义，直接关掉
        guard limit >= minimum else { return 0 }

        var value = min(max(raw, 0), limit)
        if value < minimum { return 0 }
        if limit - value < step * 0.8 { return limit }

        value = (value / step).rounded() * step
        return min(max(value, 0), limit)
    }

    /// 手柄在片段里的横坐标。
    ///
    /// 0 秒时往里让 6pt：手柄和裁剪手柄都在片段边缘，完全重合会抢手势，
    /// 稍微错开一点就能「抓上边缘调淡入、抓中间调裁剪」。
    static func handleX(_ fade: Double, pps: CGFloat, width: CGFloat) -> CGFloat {
        let raw = CGFloat(max(0, fade)) * pps
        let inset: CGFloat = 6
        guard width > inset * 2 else { return min(inset, max(0, width * 0.5)) }
        if raw < 1 { return inset }
        return min(raw, width - 3)
    }

    /// 这一侧的淡入淡出此刻是否真的起作用。
    ///
    /// 入场转场生效时，淡入由转场接管（合成器里 `if plan.inTransition <= 0`），
    /// 此时拖淡入手柄不会改变画面，UI 上要把它画成虚的。
    static func isEffective(edge: FadeEdge, inTransitionActive: Bool, hasOpacityKeyframes: Bool) -> Bool {
        if hasOpacityKeyframes { return false }
        return edge == .fadeOut || !inTransitionActive
    }
}
