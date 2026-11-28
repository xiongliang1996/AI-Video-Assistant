//
//  LoudnessMeter.swift
//  按 ITU-R BS.1770-4 / EBU R128 算积分响度（LUFS）与真峰值（dBTP）
//
//  设计要点：
//  - 纯函数 + 纯数据，不碰 AVFoundation，测试直接喂 Float 数组
//  - K 加权两级滤波（高架 + RLB 高通）用 biquad 手写：系数按采样率现算，
//    44.1k / 48k 都准，不像硬编码 48k 系数那样在 44.1k 上偏 0.1 dB
//  - 门限两级：绝对 -70 LUFS 先筛，再用「通过块的能量平均 - 10 LU」做相对门限。
//    注意最终响度是**能量平均再转 dB**，不是「dB 平均」——后者会把静音段
//    拉进来，同一段素材能差 3 dB
//  - 真峰值用 4 倍过采样（三次 Hermite）估，够防削波用，不追求 0.1 dB 精度
//

import Foundation

enum LoudnessMeter {

    /// 一次测量的结果
    struct Result: Equatable {
        /// 积分响度（LUFS）。全静音时是 -.infinity，调用方要自己兜底
        var integrated: Double
        /// 真峰值（dBFS，0 为满刻度）
        var truePeak: Double
        /// 参与计算的块数（门限之后），0 表示整段都在门限以下
        var gatedBlocks: Int
        /// 整段总块数
        var totalBlocks: Int

        var isSilent: Bool { !integrated.isFinite || gatedBlocks == 0 }

        var integratedText: String {
            isSilent ? "静音" : String(format: "%.1f LUFS", integrated)
        }

        var truePeakText: String {
            truePeak.isFinite ? String(format: "%.1f dBFS", truePeak) : "—"
        }
    }

    // MARK: - 常量

    /// 块长 400 ms，步长 100 ms（75% 重叠）
    static let blockDuration = 0.4
    static let hopDuration = 0.1
    /// 绝对门限
    static let absoluteGate: Double = -70
    /// 相对门限：低于「通过绝对门限后的平均响度 − 10 LU」的块不参与
    static let relativeGateOffset: Double = -10
    /// 立体声左右声道权重（BS.1770 表 1：L/R/C = 1.0，环绕 = 1.41）
    static let channelWeights: [Double] = [1.0, 1.0, 1.0, 1.41, 1.41]

    // MARK: - 主入口

    /// - Parameters:
    ///   - samples: **交织**采样，范围 -1...1，长度 = 帧数 × 通道数
    ///   - sampleRate: 采样率
    ///   - channels: 通道数（1 / 2）
    static func measure(samples: [Float],
                        sampleRate: Double,
                        channels: Int) -> Result {
        let ch = max(1, channels)
        let frames = samples.count / ch
        guard frames > 0, sampleRate > 0 else {
            return Result(integrated: -.infinity, truePeak: -.infinity,
                          gatedBlocks: 0, totalBlocks: 0)
        }

        let peak = truePeakDB(samples: samples, channels: ch)

        // 1. K 加权（逐通道滤波，结果按通道分开存）
        var weighted = [[Double]](repeating: [Double](repeating: 0, count: frames), count: ch)
        for c in 0..<ch {
            var shelf = Biquad.highShelf(sampleRate: sampleRate)
            var highPass = Biquad.highPass(sampleRate: sampleRate)
            for i in 0..<frames {
                let x = Double(samples[i * ch + c])
                weighted[c][i] = highPass.process(shelf.process(x))
            }
        }

        // 2. 分块求每通道均方
        let blockFrames = max(1, Int((blockDuration * sampleRate).rounded()))
        let hopFrames = max(1, Int((hopDuration * sampleRate).rounded()))
        guard frames >= blockFrames else {
            return Result(integrated: -.infinity, truePeak: peak,
                          gatedBlocks: 0, totalBlocks: 0)
        }

        var blocks: [(loudness: Double, energy: Double)] = []
        var start = 0
        while start + blockFrames <= frames {
            var energy = 0.0
            for c in 0..<ch {
                let weight = c < channelWeights.count ? channelWeights[c] : 1.0
                var sum = 0.0
                weighted[c].withUnsafeBufferPointer { buffer in
                    var i = start
                    let end = start + blockFrames
                    while i < end {
                        let v = buffer[i]
                        sum += v * v
                        i += 1
                    }
                }
                energy += weight * (sum / Double(blockFrames))
            }
            blocks.append((loudnessDB(energy), energy))
            start += hopFrames
        }

        let total = blocks.count
        guard total > 0 else {
            return Result(integrated: -.infinity, truePeak: peak,
                          gatedBlocks: 0, totalBlocks: 0)
        }

        // 3. 绝对门限
        let absolute = blocks.filter { $0.loudness > absoluteGate }
        guard !absolute.isEmpty else {
            return Result(integrated: -.infinity, truePeak: peak,
                          gatedBlocks: 0, totalBlocks: total)
        }

        // 4. 相对门限：用「通过绝对门限的块」的能量平均算基准
        let absoluteMean = absolute.reduce(0.0) { $0 + $1.energy } / Double(absolute.count)
        let relativeGate = loudnessDB(absoluteMean) + relativeGateOffset

        let gated = absolute.filter { $0.loudness > relativeGate }
        guard !gated.isEmpty else {
            return Result(integrated: loudnessDB(absoluteMean), truePeak: peak,
                          gatedBlocks: 0, totalBlocks: total)
        }

        let mean = gated.reduce(0.0) { $0 + $1.energy } / Double(gated.count)
        return Result(integrated: loudnessDB(mean),
                      truePeak: peak,
                      gatedBlocks: gated.count,
                      totalBlocks: total)
    }

    /// 能量 → LUFS（BS.1770 的 -0.691 偏移就是 0 dBFS 满幅正弦的响度）
    static func loudnessDB(_ energy: Double) -> Double {
        guard energy > 0 else { return -.infinity }
        return -0.691 + 10 * log10(energy)
    }

    // MARK: - 增益

    /// 把测到的响度拉到目标需要多少 dB，同时保证真峰值不超过 ceiling
    /// - Returns: (增益 dB, 是否被峰值卡住)
    static func gain(measured: Result,
                     target: Double,
                     peakCeiling: Double = -1.0) -> (gain: Double, limitedByPeak: Bool) {
        guard !measured.isSilent else { return (0, false) }
        let wanted = target - measured.integrated
        guard measured.truePeak.isFinite else { return (wanted, false) }
        let allowed = peakCeiling - measured.truePeak
        if wanted > allowed {
            return (allowed, true)
        }
        return (wanted, false)
    }

    // MARK: - 真峰值

    /// 4 倍过采样后的峰值（dBFS）
    ///
    /// 插值核用 8 点 Hann 窗 sinc，不用三次 Hermite：Catmull-Rom 在
    /// 归一化频率 0.25（48k 下的 12 kHz）已经衰减 1 dB，测高频素材时
    /// 真峰值会偏低整整 1 dB —— 而我们靠它算削波余量，1 dB 就是致命的。
    /// 窗 sinc 在同一点衰减 < 0.05 dB。
    ///
    /// 只对「超过样本峰值 70%」的样本做插值：语音里这类样本不到一半，
    /// 10 分钟素材也只要几百毫秒。
    static func truePeakDB(samples: [Float], channels: Int) -> Double {
        let ch = max(1, channels)
        let frames = samples.count / ch
        guard frames > 1 else { return -.infinity }

        var samplePeak = 0.0
        for i in 0..<samples.count {
            let v = abs(Double(samples[i]))
            if v > samplePeak { samplePeak = v }
        }
        guard samplePeak > 0 else { return -.infinity }

        let threshold = samplePeak * 0.7
        var peak = samplePeak

        for c in 0..<ch {
            for i in 0..<frames {
                let value = abs(Double(samples[i * ch + c]))
                if value < threshold { continue }
                // 峰可能落在样本 i 与 i±1 之间，两侧都要看
                for from in [i - 1, i] {
                    guard from >= 0, from + 1 < frames else { continue }
                    for step in 1...3 {
                        let pos = Double(from) + Double(step) / 4
                        let interpolated = abs(interpolate(samples, ch: ch, channel: c, at: pos))
                        if interpolated > peak { peak = interpolated }
                    }
                }
            }
        }

        return 20 * log10(peak)
    }

    /// 8 点 Hann 窗 sinc 插值，抽头 k ∈ −3…4
    private static func interpolate(_ samples: [Float],
                                    ch: Int,
                                    channel: Int,
                                    at position: Double) -> Double {
        let frames = samples.count / ch
        let base = Int(position.rounded(.down))
        let frac = position - Double(base)
        var sum = 0.0
        for k in -3...4 {
            let index = base + k
            guard index >= 0, index < frames else { continue }
            let x = frac - Double(k)
            // Hann 窗，半宽 4 个样本
            let window = 0.5 + 0.5 * cos(.pi * x / 4)
            let sinc = abs(x) < 1e-9 ? 1.0 : sin(.pi * x) / (.pi * x)
            sum += Double(samples[index * ch + channel]) * sinc * window
        }
        return sum
    }

    // MARK: - 增益落地

    /// 就地乘增益，并把超过 ceiling 的样本压下来（软膝限幅）
    /// - Returns: 本来会削波的样本数（限幅之后都不会真的超），0 表示完全没碰到天花板
    @discardableResult
    static func applyGain(_ samples: inout [Float],
                          gainDB: Double,
                          ceilingDB: Double = -1.0) -> Int {
        guard samples.count > 0 else { return 0 }
        let gain = Float(pow(10, gainDB / 20))
        let ceiling = Float(pow(10, ceilingDB / 20))
        // 膝点放在天花板下 1.5 dB：再低就成了「压限」，安静素材提上来会被压扁
        let kneeStart = ceiling * 0.841
        let span = max(1e-6, ceiling - kneeStart)
        var clipped = 0

        for i in 0..<samples.count {
            var value = samples[i] * gain
            let magnitude = abs(value)
            guard magnitude > kneeStart else {
                samples[i] = value
                continue
            }
            if magnitude > ceiling { clipped += 1 }

            // 软膝：out = ceiling − span·e^(−(in−knee)/span)
            // 在膝点处斜率为 1（和未压缩段平滑接上），往天花板方向渐近于 0。
            // 不用 tanh 归一化：那样膝点处斜率是 1.65，会把信号放大
            let compressed = ceiling - span * exp(-(magnitude - kneeStart) / span)
            value = value < 0 ? -compressed : compressed
            samples[i] = value
        }
        return clipped
    }
}

// MARK: - Biquad

/// 转置直接 II 型 biquad。K 加权两级都用它，只是系数不同
struct Biquad {
    var b0: Double = 1
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0
    private var z1: Double = 0
    private var z2: Double = 0

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() {
        z1 = 0
        z2 = 0
    }

    /// 第一级：高架滤波，+4 dB @ 1.5 kHz（BS.1770 的「头部相关」补偿）
    static func highShelf(sampleRate: Double) -> Biquad {
        let f0 = 1681.974450955533
        let gainDB = 3.999843853973347
        let q = 0.7071752369554196
        let k = tan(.pi * f0 / sampleRate)
        let vh = pow(10, gainDB / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return Biquad(b0: (vh + vb * k / q + k * k) / a0,
                      b1: 2 * (k * k - vh) / a0,
                      b2: (vh - vb * k / q + k * k) / a0,
                      a1: 2 * (k * k - 1) / a0,
                      a2: (1 - k / q + k * k) / a0)
    }

    /// 第二级：RLB 高通 38 Hz，去次声与直流
    static func highPass(sampleRate: Double) -> Biquad {
        let f0 = 38.13547087602444
        let q = 0.5003270373238773
        let k = tan(.pi * f0 / sampleRate)
        let denom = 1 + k / q + k * k
        return Biquad(b0: 1,
                      b1: -2,
                      b2: 1,
                      a1: 2 * (k * k - 1) / denom,
                      a2: (1 - k / q + k * k) / denom)
    }
}
