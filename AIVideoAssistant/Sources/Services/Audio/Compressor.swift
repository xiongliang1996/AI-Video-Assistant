//
//  Compressor.swift
//  动态压缩：前馈峰值检测 + 软膝 + 自动补偿
//
//  为什么需要它：均衡、降噪、响度标准化都不改变「动态范围」。
//  响度标准化只是把整条音轨抬到 −14 LUFS，段内忽大忽小照样忽大忽小；
//  压缩才是那个把「大声的字」压下来、「小声的字」相对抬上去的东西。
//
//  三个设计选择：
//  - **峰值检测 + 慢释放**（8 ms / 120 ms）。口播里漏掉字头最明显，
//    所以启动要快；释放慢一点，音节之间才不会「一压一放」地抽搐。
//    不用 RMS 窗：窗长本身就要 10–20 ms，等于给字头又加了延迟
//  - **软膝 6 dB**：门限附近用二次曲线过渡，硬折会在「刚好超过门限」的
//    那些字上产生可听的音色跳变
//  - **补偿量自动算**：取「有压缩的帧上，平均压下去多少 dB」，原样补回来。
//    这样响的部分回到原来的电平，安静的部分相对被抬高——听感是「变平」，
//    而不是「整体变响」。手动补偿滑杆在口播场景里基本只会调错
//
//  立体声必须联动：增益由两声道里较大的那个决定，同一条增益作用到两个
//  声道上。分别算会让声像随内容左右飘
//

import Foundation

/// 压缩设置。门限单位 dBFS（0 是满刻度），比率是「超出部分压成几分之一」
struct CompressorSettings: Codable, Hashable {
    var enabled: Bool = false
    /// 门限：超过这条线的部分才按比率压
    var thresholdDB: Double = -18
    /// 压缩比。1.0 等于不压，4.0 表示超出部分压成 1/4
    var ratio: Double = 3.0

    static let thresholdRange: ClosedRange<Double> = -40 ... -6
    static let ratioRange: ClosedRange<Double> = 1.5 ... 8.0

    /// 启动 / 释放时间常数。口播固定这两档，不暴露给用户
    static let attackMs: Double = 8
    static let releaseMs: Double = 120
    /// 软膝宽度（dB）
    static let kneeDB: Double = 6

    /// 比率不到 1.05 时压了也听不出来，当成没开
    var isActive: Bool { enabled && ratio >= 1.05 }

    /// 带正负号的文案，用 U+2212 减号（和均衡、响度那几处一致）
    static func signed(_ value: Double, decimals: Int = 1) -> String {
        String(format: "%@%.\(decimals)f", value >= 0 ? "+" : "−", abs(value))
    }

    var summary: String {
        guard isActive else { return "关闭" }
        return String(format: "门限 %@ dBFS · %.1f:1",
                      CompressorSettings.signed(thresholdDB, decimals: 0), ratio)
    }
}

enum Compressor {

    struct Report: Equatable {
        var thresholdDB: Double
        var ratio: Double
        /// 最大压下去多少 dB（正数）
        var maxReductionDB: Double
        /// 自动补回来的增益（正数 dB）
        var makeupDB: Double
        /// 补偿后仍会超过天花板、被软膝限幅的样本数
        var limitedSamples: Int

        /// 一个都没超过门限时视为没触发
        var triggered: Bool { maxReductionDB > 0.05 }

        var summary: String {
            let base = String(format: "门限 %@ dBFS · %.1f:1",
                              CompressorSettings.signed(thresholdDB, decimals: 0),
                              ratio)
            guard triggered else { return base + " · 没有超过门限的片段" }
            var text = base + String(format: " · 最大压 %.1f dB · 补偿 +%.1f dB",
                                     maxReductionDB, makeupDB)
            if limitedSamples > 0 { text += "，峰值被限幅" }
            return text
        }
    }

    /// 补偿后允许的最高电平。和响度标准化用同一个天花板
    static let ceilingDB: Double = -1.0

    // MARK: - 主入口

    /// 就地压缩。没触发或没开时返回 nil（或者一份 triggered == false 的报告）
    static func process(_ samples: inout [Float],
                        channels: Int,
                        settings: CompressorSettings,
                        sampleRate: Double) -> Report? {
        guard settings.isActive else { return nil }

        let ch = max(1, channels)
        let frames = samples.count / ch
        guard frames > 0, sampleRate > 0 else { return nil }

        let threshold = settings.thresholdDB
        let ratio = max(1.0001, settings.ratio)
        let slope = 1 - 1 / ratio
        let knee = CompressorSettings.kneeDB

        // 电平检测用**瞬时峰值 + 慢释放**，不设上升时间常数。
        // 任何一阶跟随器都追不上波形峰：1 kHz 的半周期只有 0.5 ms，
        // 8 ms 的启动常数下包络稳定在峰值下方 0.9 dB，稳态压缩量会算少
        // 0.7 dB。峰值跟随没有这个问题——每个峰都把包络顶到当前值
        let levelRelease = 1 - exp(-1 / (0.05 * sampleRate))
        // 增益弹道：需要多压时 8 ms 到位，松开时 120 ms
        let gainAttack = 1 - exp(-1 / (CompressorSettings.attackMs / 1000 * sampleRate))
        let gainRelease = 1 - exp(-1 / (CompressorSettings.releaseMs / 1000 * sampleRate))

        // 第一遍只量不写：算出「典型压了多少」当补偿量。
        // 增益曲线是输入的函数，第二遍重算必然一模一样，所以不用把曲线存下来
        // （10 分钟素材存逐帧增益要一百多 MB）
        //
        // 用**中位数**而不是均值：释放尾巴上那几百毫秒的「半压缩帧」会把
        // 均值拉低——两段电平的素材能低 1.5 dB，补偿就不够，听着还是「只压不抬」。
        // 中位数落在真正被压的那一段上
        let binWidth = 0.1
        let binCount = 400                       // 0…40 dB，够覆盖任何门限
        var histogram = [Int](repeating: 0, count: binCount + 1)
        var activeFrames = 0
        var maxReduction = 0.0
        var env = 0.0
        var smoothedGR = 0.0

        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            env = 0
            smoothedGR = 0
            for i in 0..<frames {
                var level = 0.0
                for c in 0..<ch {
                    let v = abs(Double(base[i * ch + c]))
                    if v > level { level = v }
                }
                env = level > env ? level : env + (level - env) * levelRelease

                let target = gainReduction(levelDB: levelDB(env),
                                           threshold: threshold, slope: slope, knee: knee)
                // 更负 = 压得更多：往下走用启动常数，往上松用释放常数
                smoothedGR += (target - smoothedGR)
                    * (target < smoothedGR ? gainAttack : gainRelease)

                guard smoothedGR < -0.5 else { continue }
                let magnitude = min(-smoothedGR, Double(binCount) * binWidth)
                let bin = min(binCount, Int((magnitude / binWidth).rounded()))
                histogram[bin] += 1
                activeFrames += 1
                if smoothedGR < maxReduction { maxReduction = smoothedGR }
            }
        }

        var makeup = 0.0
        if activeFrames > 0 {
            let half = (activeFrames + 1) / 2
            var cumulative = 0
            for bin in 0...binCount {
                cumulative += histogram[bin]
                if cumulative >= half {
                    makeup = Double(bin) * binWidth
                    break
                }
            }
        }
        let report = Report(thresholdDB: threshold,
                            ratio: ratio,
                            maxReductionDB: -maxReduction,
                            makeupDB: makeup,
                            limitedSamples: 0)

        // 一个都没压到：原样返回，别白改一遍采样
        guard report.triggered else { return report }

        // 第二遍：同一条包络 + 增益曲线，乘上去。
        // 补偿量对「安静段」也生效，这是补偿增益的定义（不是只补响的地方）
        var peak = 0.0
        var limited = 0
        let ceiling = Float(pow(10, ceilingDB / 20))
        let kneeStart = ceiling * 0.841        // 膝点放在天花板下 1.5 dB
        let span = max(1e-6, ceiling - kneeStart)

        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            env = 0
            smoothedGR = 0
            peak = 0
            for i in 0..<frames {
                var level = 0.0
                for c in 0..<ch {
                    let v = abs(Double(base[i * ch + c]))
                    if v > level { level = v }
                }
                env = level > env ? level : env + (level - env) * levelRelease

                let target = gainReduction(levelDB: levelDB(env),
                                           threshold: threshold, slope: slope, knee: knee)
                smoothedGR += (target - smoothedGR)
                    * (target < smoothedGR ? gainAttack : gainRelease)

                // 10^((gr + makeup)/20) = exp2(x · log2(10)/20)
                let gain = Float(exp2((smoothedGR + makeup) * 0.16609640474436813))

                for c in 0..<ch {
                    let index = i * ch + c
                    var value = base[index] * gain
                    var magnitude = abs(value)

                    // 字头还没进包络时补偿量已经全额生效，可能冲过天花板。
                    // 不做前瞻延迟，直接在这里软膝压住——代价是极短的一瞬
                    // 被压扁，好处是任何素材都不会削波
                    if magnitude > kneeStart {
                        if magnitude > ceiling { limited += 1 }
                        let compressed = ceiling - span * exp(-(magnitude - kneeStart) / span)
                        value = value < 0 ? -compressed : compressed
                        magnitude = compressed
                    }

                    base[index] = value
                    if Double(magnitude) > peak { peak = Double(magnitude) }
                }
            }
        }

        return Report(thresholdDB: threshold,
                      ratio: ratio,
                      maxReductionDB: -maxReduction,
                      makeupDB: makeup,
                      limitedSamples: limited)
    }

    // MARK: - 曲线

    /// 静态曲线：给一个电平，返回要压多少 dB（≤ 0）
    ///
    /// 门限 ± 半个膝宽之内用二次曲线接上：
    /// 在 `over = −knee/2` 处增益为 0、斜率为 0；在 `over = +knee/2` 处
    /// 与硬折段的「值」和「斜率」都连续
    static func gainReduction(levelDB: Double,
                              threshold: Double,
                              slope: Double,
                              knee: Double) -> Double {
        let over = levelDB - threshold
        if over <= -knee / 2 { return 0 }
        if over >= knee / 2 { return -over * slope }
        let x = over + knee / 2
        return -slope * x * x / (2 * knee)
    }

    /// 线性幅度 → dBFS，下限 −180 dB 防止 log(0)
    private static func levelDB(_ level: Double) -> Double {
        level > 1e-9 ? 6.020599913279624 * log2(level) : -180
    }
}
