//
//  AudioDucker.swift
//  音乐自动闪避（ducking）：配音一响，背景音乐就压下去
//
//  为什么这么做：AVFoundation 没有内建的 sidechain 压缩，做不了「按另一条轨
//  的电平实时压这条轨」。但音量关键帧这条路径是现成的（导出与预览走同一套
//  ramp，已经验证过），所以把「什么时候压、压多深」提前算成一条包络写进去。
//  好处是生成完还能在关键帧面板里手动微调，不是黑箱。
//
//  纯函数：语音区间、片段边界、参数进，包络点出。不碰磁盘、不碰 AVFoundation。
//

import Foundation

enum AudioDucker {

    // MARK: - 参数

    struct Options: Equatable {
        /// 闪避时压到原音量的比例（0.25 ≈ -12 dB）
        var duckRatio: Double = 0.25
        /// 语音开始前提前压下去的时间，避免「先听到半句再变小」
        var attack: Double = 0.18
        /// 语音结束后恢复的时间
        var release: Double = 0.45
        /// 两句之间停顿短于这个长度就不恢复，否则音乐会来回抽气
        var holdGap: Double = 0.40
        /// 真要恢复的话，抬起来至少要维持这么久。
        /// 少了这一条，间隔刚好比「恢复 + 再压」长一点点时，
        /// 音乐会抬起来 0.0x 秒又压下去，听感上是抽搐而不是呼吸
        var minimumPlateau: Double = 0.30

        static let gentle = Options(duckRatio: 0.45, attack: 0.16, release: 0.40, holdGap: 0.40)
        static let medium = Options()
        static let strong = Options(duckRatio: 0.12, attack: 0.20, release: 0.50, holdGap: 0.45)

        static let presets: [(title: String, options: Options)] = [
            ("轻", .gentle), ("中", .medium), ("重", .strong)
        ]

        /// 真正用来合并停顿的间隔：恢复 + 再压 + 最短平台期。
        /// 短于这个长度的停顿不值得恢复——抬起来还没听清就又下去了
        var effectiveHoldGap: Double { max(holdGap, attack + release + minimumPlateau) }

        var sanitized: Options {
            var copy = self
            copy.duckRatio = copy.duckRatio.isFinite
                ? min(max(copy.duckRatio, 0.02), 0.95) : 0.25
            copy.attack = copy.attack.isFinite ? min(max(copy.attack, 0), 1.5) : 0.18
            copy.release = copy.release.isFinite ? min(max(copy.release, 0), 2.0) : 0.45
            copy.holdGap = copy.holdGap.isFinite ? min(max(copy.holdGap, 0), 3.0) : 0.40
            copy.minimumPlateau = copy.minimumPlateau.isFinite
                ? min(max(copy.minimumPlateau, 0), 2.0) : 0.30
            return copy
        }

        /// 给面板显示用：压了多少 dB
        var duckDecibels: Double { AudioDucker.decibels(for: duckRatio) }
    }

    /// 包络上的一个折点：时间相对片段起点，值 = 音量倍数
    struct Point: Equatable {
        var time: Double
        var value: Double
    }

    /// 闪避的参考来源
    enum ReferenceSource: String, CaseIterable, Identifiable {
        /// 分析另一条音频轨的语音区间（离线 RMS / dBFS）
        case voiceTrack
        /// 直接用时间线上的字幕条目。字幕本来就是按发音对齐的，
        /// 比静音检测更贴，而且不用解码音频
        case subtitles

        var id: String { rawValue }

        var title: String {
            switch self {
            case .voiceTrack: return "配音语音"
            case .subtitles: return "字幕时间"
            }
        }
    }

    // MARK: - 单位换算

    static func decibels(for ratio: Double) -> Double {
        guard ratio > 0 else { return -160 }
        return 20 * log10(ratio)
    }

    /// 文件时间区间 → 时间线时间区间（片段可能被裁剪过、也可能变速）
    static func toTimeline(_ ranges: [ClosedRange<Double>],
                           clipStart: Double,
                           sourceStart: Double,
                           speed: Double) -> [ClosedRange<Double>] {
        let rate = max(0.1, speed)
        return ranges.map { range in
            let lo = clipStart + (range.lowerBound - sourceStart) / rate
            let hi = clipStart + (range.upperBound - sourceStart) / rate
            return lo...hi
        }
    }

    // MARK: - 合并

    /// 把间隔很短的语音区间并成一段。
    /// 不合并的话，句子之间的换气会让音乐一次次抬起来又压下去，听起来像故障
    static func merge(_ ranges: [ClosedRange<Double>], holdGap: Double) -> [ClosedRange<Double>] {
        let sorted = ranges
            .filter { $0.upperBound - $0.lowerBound > 0.001 }
            .sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<Double>] = []
        for range in sorted {
            if let last = result.last, range.lowerBound - last.upperBound <= holdGap {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// 字幕条目 → 语音区间。
    ///
    /// 字幕的边界是「这句话显示到什么时候」，通常比静音检测晚一点点
    /// （句尾拖音、字幕多留 0.2 秒给阅读），所以先剔掉零长度的，
    /// 再按 holdGap 合并相邻条目——同一段话被拆成两行时不该抬起来。
    static func ranges(from spans: [ClosedRange<Double>],
                       holdGap: Double) -> [ClosedRange<Double>] {
        merge(spans.filter { $0.upperBound - $0.lowerBound > 0.02 }, holdGap: holdGap)
    }

    // MARK: - 增益曲线

    /// 语音增益：区间内 duckRatio，区间外 1，两端线性过渡
    static func speechGain(at time: Double,
                           ranges: [ClosedRange<Double>],
                           options: Options) -> Double {
        let duck = options.duckRatio
        for range in ranges {
            if time >= range.lowerBound && time <= range.upperBound { return duck }
            if options.attack > 0,
               time < range.lowerBound, time > range.lowerBound - options.attack {
                // 距离语音还有多远（1 = 刚好处在 attack 起点，0 = 已经进入语音）
                let ratio = (range.lowerBound - time) / options.attack
                return duck + (1 - duck) * ratio
            }
            if options.release > 0,
               time > range.upperBound, time < range.upperBound + options.release {
                let ratio = (time - range.upperBound) / options.release
                return duck + (1 - duck) * ratio
            }
        }
        return 1
    }

    /// 淡入淡出增益。有关键帧时 `applyVolume` 会把淡入淡出交给关键帧表达，
    /// 所以生成包络时要自己把这段乘进去，否则原来的淡入淡出会丢
    static func fadeGain(at time: Double,
                         duration: Double,
                         fadeIn: Double,
                         fadeOut: Double) -> Double {
        var gain = 1.0
        if fadeIn > 0.02, time < fadeIn {
            gain = min(gain, max(0, time / fadeIn))
        }
        if fadeOut > 0.02, time > duration - fadeOut {
            gain = min(gain, max(0, (duration - time) / fadeOut))
        }
        return min(1, max(0, gain))
    }

    // MARK: - 包络

    /// 生成音量包络。
    /// - Parameters:
    ///   - speech: 语音区间，**时间线绝对时间**
    ///   - clipStart / clipEnd: 目标片段在时间线上的起止
    ///   - baseLevel: 不闪避时的音量（片段自己的 volume）
    ///   - fadeIn / fadeOut: 片段原有的淡入淡出，会被乘进包络
    /// - Returns: 折点数组，时间为相对片段起点；不足两个点表示没什么可压的
    static func envelope(speech: [ClosedRange<Double>],
                         clipStart: Double,
                         clipEnd: Double,
                         baseLevel: Double,
                         fadeIn: Double = 0,
                         fadeOut: Double = 0,
                         options: Options = Options()) -> [Point] {
        let duration = clipEnd - clipStart
        guard duration > 0.05 else { return [] }
        let opts = options.sanitized
        let base = min(max(baseLevel.isFinite ? baseLevel : 1, 0), 2)

        // 绝对时间 → 片内相对时间，并裁到片段范围内
        var relative: [ClosedRange<Double>] = []
        for range in speech {
            let lo = max(range.lowerBound, clipStart) - clipStart
            let hi = min(range.upperBound, clipEnd) - clipStart
            guard hi - lo > 0.02 else { continue }
            relative.append(lo...hi)
        }
        guard !relative.isEmpty else { return [] }

        let merged = merge(relative, holdGap: opts.effectiveHoldGap)

        // 折点：每个区间的四条边 + 首尾 + 淡入淡出边界
        var times: [Double] = [0, duration]
        if fadeIn > 0.02 { times.append(min(duration, fadeIn)) }
        if fadeOut > 0.02 { times.append(max(0, duration - fadeOut)) }
        for range in merged {
            times.append(max(0, range.lowerBound - opts.attack))
            times.append(range.lowerBound)
            times.append(range.upperBound)
            times.append(min(duration, range.upperBound + opts.release))
        }
        let sorted = times.map { min(max(0, $0), duration) }.sorted()

        // 太近的折点没有意义，反而让 ramp 段数暴涨（每段都要一次 setVolumeRamp）
        var unique: [Double] = []
        for time in sorted where (unique.last.map { time - $0 > 0.02 } ?? true) {
            unique.append(time)
        }
        if unique.first != 0 { unique.insert(0, at: 0) }
        if let last = unique.last, last < duration - 0.001 { unique.append(duration) }

        var points: [Point] = []
        for time in unique {
            let gain = speechGain(at: time, ranges: merged, options: opts)
                * fadeGain(at: time, duration: duration, fadeIn: fadeIn, fadeOut: fadeOut)
            let value = base * gain
            // 同值又紧邻的折点是冗余的
            if let last = points.last,
               abs(last.value - value) < 0.0005, time - last.time < 0.02 {
                continue
            }
            points.append(Point(time: time, value: value))
        }
        return points.count >= 2 ? points : []
    }

    /// 包络 → 关键帧。用线性缓动：闪避的听感靠时长控制，
    /// 再叠一层缓动反而会让人声进来时音乐还没压到位
    static func keyframes(from points: [Point]) -> [Keyframe] {
        points.map { Keyframe(time: $0.time, value: $0.value, easing: .linear) }
    }
}
