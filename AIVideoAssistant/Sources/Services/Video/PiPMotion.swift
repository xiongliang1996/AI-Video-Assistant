//
//  PiPMotion.swift
//  画中画入场 / 出场的曲线
//
//  写成纯函数：给定样式和进度，返回「不透明度 × 缩放 × 位移」三个乘数。
//  系统合成器（setOpacityRamp / setTransformRamp）和自绘合成器（逐帧采样）
//  共用这一份实现——各写一份必然漂移，预览对得上、导出少淡一格这种 bug 最难查。
//

import Foundation
import CoreGraphics

/// 某一时刻的动效乘数
struct PiPMotionFactors: Equatable {
    var opacity: Double = 1
    var scale: Double = 1
    /// 水平位移，单位是「画中画自身宽度」的比例，正数向右
    var dx: Double = 0
    /// 垂直位移，单位是「画中画自身高度」的比例，正数向下（视频坐标）
    var dy: Double = 0

    var isIdentity: Bool {
        opacity == 1 && scale == 1 && dx == 0 && dy == 0
    }
}

enum PiPMotion {

    /// 单段动效在 `progress` 时的乘数。
    ///
    /// `progress` 的 0 表示「还没进来」（完全透明 / 完全偏移），1 表示就位。
    /// 出场时进度是从 1 掉到 0，同一条曲线反过来就是「越走越快」地离开，
    /// 正好符合观众对退场的预期，不用再写一套曲线。
    static func factors(_ style: PiPMotionStyle, progress: Double) -> PiPMotionFactors {
        guard style.isActive else { return PiPMotionFactors() }
        let p = min(max(progress, 0), 1)
        // 缓出：起步快、落位稳。三次方足够，不用贝塞尔
        let eased = 1 - pow(1 - p, 3)
        let remain = 1 - eased

        switch style {
        case .none:
            return PiPMotionFactors()
        case .fade:
            return PiPMotionFactors(opacity: eased)
        case .zoom:
            return PiPMotionFactors(opacity: eased, scale: 0.82 + 0.18 * eased)
        case .fromLeft:
            // 滑入时透明度收得比位移快：半透明地滑会看成「鬼影」
            return PiPMotionFactors(opacity: min(1, eased * 1.8), dx: -remain)
        case .fromRight:
            return PiPMotionFactors(opacity: min(1, eased * 1.8), dx: remain)
        case .fromBottom:
            return PiPMotionFactors(opacity: min(1, eased * 1.8), dy: remain)
        }
    }

    /// 入场 + 出场合成。两个时长各自夹到半个片段内，所以窗口不会重叠，
    /// 乘起来不会出现「同时淡入淡出」的怪异中间态
    static func combined(enter: PiPMotionStyle,
                         enterDuration: Double,
                         exit: PiPMotionStyle,
                         exitDuration: Double,
                         span: Double,
                         at local: Double) -> PiPMotionFactors {
        var result = PiPMotionFactors()
        let half = max(0.001, span / 2)
        let clampedLocal = min(max(local, 0), span)

        if enter.isActive, enterDuration > 0.001 {
            let duration = min(max(enterDuration, 0), half)
            if duration > 0.001 {
                let f = factors(enter, progress: clampedLocal / duration)
                result.opacity *= f.opacity
                result.scale *= f.scale
                result.dx += f.dx
                result.dy += f.dy
            }
        }

        if exit.isActive, exitDuration > 0.001 {
            let duration = min(max(exitDuration, 0), half)
            if duration > 0.001 {
                let f = factors(exit, progress: (span - clampedLocal) / duration)
                result.opacity *= f.opacity
                result.scale *= f.scale
                result.dx += f.dx
                result.dy += f.dy
            }
        }
        return result
    }

    /// 动效窗口内需要补的采样点（相对片段起点）。
    ///
    /// `setOpacityRamp` / `setTransformRamp` 在两点之间是**线性**的，而缓出曲线
    /// 是非线性的：只取窗口两端，整段会变成匀速滑入，起手的「快」全丢了。
    /// 每个窗口补 `steps` 个点，0.6 秒的动效大约 0.075 秒一个采样，足够顺。
    static func sampleOffsets(span: Double,
                              enterDuration: Double,
                              exitDuration: Double,
                              steps: Int = 8) -> [Double] {
        let half = max(0.001, span / 2)
        var offsets: [Double] = []

        let enter = min(max(enterDuration, 0), half)
        if enter > 0.001 {
            for index in 1...steps {
                offsets.append(enter * Double(index) / Double(steps))
            }
        }

        let exit = min(max(exitDuration, 0), half)
        if exit > 0.001 {
            // 从窗口起点（span - exit）开始，不能从 span 开始：
            // 从 span 开始等于把整个窗口的采样点整体右移一格，末段曲线会被压平
            let start = span - exit
            for index in 0..<steps {
                offsets.append(start + exit * Double(index) / Double(steps))
            }
        }
        return offsets
    }

    /// 把动效乘数套到一个已经算好的画中画变换上。
    ///
    /// 缩放绕**画中画矩形中心**，位移按矩形自身的宽高换算成像素——
    /// 这样同一套参数在 1080p 和 4K、在 32% 宽和 60% 宽的画中画上表现一致。
    static func apply(_ factors: PiPMotionFactors,
                      to transform: CGAffineTransform,
                      rect: CGRect) -> CGAffineTransform {
        guard !factors.isIdentity else { return transform }
        let centerX = rect.midX + CGFloat(factors.dx) * rect.width
        let centerY = rect.midY + CGFloat(factors.dy) * rect.height
        return transform
            .concatenating(CGAffineTransform(translationX: -rect.midX, y: -rect.midY))
            .concatenating(CGAffineTransform(scaleX: CGFloat(factors.scale),
                                             y: CGFloat(factors.scale)))
            .concatenating(CGAffineTransform(translationX: centerX, y: centerY))
    }
}
