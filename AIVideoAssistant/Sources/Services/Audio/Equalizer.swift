//
//  Equalizer.swift
//  三段均衡：低切（二阶高通）+ 中频峰值 + 高架
//
//  为什么是这三段而不是十段参量：
//  - 口播调音真正用到的就三件事——切掉低频隆隆声、把 2.5 kHz 提一点让字更清楚、
//    高架压一下齿音或提一下空气感。十段参量在这个场景里只是参数更多，不是更好听
//  - 每段都是 RBJ cookbook 的标准 biquad，系数有闭式解，不需要迭代拟合
//
//  两个容易踩的点：
//  - 必须用**转置直接型 II**（TDF-II）：直接型 I 在高 Q / 低频时中间变量会溢出，
//    Float 精度下能听到「咔」的爆音
//  - 低切的 Q 取 0.707（Butterworth），在 f0 处正好 −3 dB。Q 取 1.0 会在 f0
//    附近鼓一个包，听感上像「低频反而变厚了」
//

import Foundation

/// 三段均衡的设置。数值单位：Hz / dB
struct EqualizerSettings: Codable, Hashable {
    var enabled: Bool = false
    /// 低切频率，0 表示不切
    var lowCutHz: Double = 80
    /// 中频峰值增益，0 表示不动
    var midGainDB: Double = 0
    /// 高架增益，0 表示不动
    var highGainDB: Double = 0

    /// 中频峰值的中心频率。2.5 kHz 是辅音（s / t / k）的主要能量区，
    /// 提这里字会变清楚，提 5 kHz 以上只会变刺
    static let midHz: Double = 2500
    /// 峰值带宽：Q = 1.0 约 1.4 个八度，覆盖 1.2–5 kHz，不会碰到低频
    static let midQ: Double = 1.0
    /// 高架拐点。8 kHz 以上是齿音与「空气感」的分界
    static let highShelfHz: Double = 8000
    /// 低切档位。0 是关闭
    static let lowCutOptions: [Double] = [0, 60, 80, 100, 120]
    static let gainRange: ClosedRange<Double> = -6...6

    /// 参数改到 0.1 dB 以内视同不动，避免「开了均衡但其实什么都没做」
    var isActive: Bool {
        enabled && (lowCutHz > 0
                    || abs(midGainDB) >= 0.1
                    || abs(highGainDB) >= 0.1)
    }

    var lowCutLabel: String {
        lowCutHz <= 0 ? "关闭" : String(format: "%.0f Hz", lowCutHz)
    }

    /// 带正负号的增益文案。用 U+2212 减号而不是 ASCII 的 `-`：
    /// 界面上等宽数字里 `−1.5` 比 `-1.5` 更接近排版惯例，也和响度那几处一致
    static func signed(_ value: Double) -> String {
        String(format: "%@%.1f", value >= 0 ? "+" : "−", abs(value))
    }

    var summary: String {
        guard isActive else { return "关闭" }
        var parts: [String] = []
        if lowCutHz > 0 { parts.append("低切 \(lowCutLabel)") }
        if abs(midGainDB) >= 0.1 {
            parts.append("中频 \(EqualizerSettings.signed(midGainDB)) dB")
        }
        if abs(highGainDB) >= 0.1 {
            parts.append("高架 \(EqualizerSettings.signed(highGainDB)) dB")
        }
        return parts.joined(separator: " · ")
    }
}

enum Equalizer {

    struct Report: Equatable {
        /// 实际生效的段，按处理顺序
        var bands: [String]

        var summary: String {
            bands.isEmpty ? "未做处理" : bands.joined(separator: " · ")
        }
    }

    // MARK: - 主入口

    /// 就地均衡。返回报告，没生效时返回 nil
    static func process(_ samples: inout [Float],
                        channels: Int,
                        settings: EqualizerSettings,
                        sampleRate: Double) -> Report? {
        guard settings.isActive else { return nil }

        let ch = max(1, channels)
        let frames = samples.count / ch
        guard frames > 0 else { return nil }

        var stages: [Biquad] = []
        var bands: [String] = []

        if settings.lowCutHz > 0 {
            // 截止频率不能超过 Nyquist 的 1/8：再高就变成「把中频也切了」
            let hz = min(settings.lowCutHz, sampleRate / 8)
            stages.append(.highPass(hz: hz, sampleRate: sampleRate, q: 0.707))
            bands.append(String(format: "低切 %.0f Hz", hz))
        }
        if abs(settings.midGainDB) >= 0.1 {
            stages.append(.peaking(hz: EqualizerSettings.midHz,
                                   gainDB: settings.midGainDB,
                                   sampleRate: sampleRate,
                                   q: EqualizerSettings.midQ))
            bands.append("中频 \(EqualizerSettings.signed(settings.midGainDB)) dB")
        }
        if abs(settings.highGainDB) >= 0.1 {
            let hz = min(EqualizerSettings.highShelfHz, sampleRate / 4)
            stages.append(.highShelf(hz: hz, gainDB: settings.highGainDB,
                                     sampleRate: sampleRate))
            bands.append("高架 \(EqualizerSettings.signed(settings.highGainDB)) dB")
        }

        guard !stages.isEmpty else { return nil }

        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for c in 0..<ch {
                runStages(stages, base: base, channel: c, channels: ch, frames: frames)
            }
        }

        return Report(bands: bands)
    }

    /// 单通道串完所有级。状态变量每通道每级独立，不能跨通道共用
    private static func runStages(_ stages: [Biquad],
                                  base: UnsafeMutablePointer<Float>,
                                  channel c: Int,
                                  channels ch: Int,
                                  frames: Int) {
        var z1 = [Float](repeating: 0, count: stages.count)
        var z2 = [Float](repeating: 0, count: stages.count)

        z1.withUnsafeMutableBufferPointer { z1Buf in
            z2.withUnsafeMutableBufferPointer { z2Buf in
                guard let z1P = z1Buf.baseAddress, let z2P = z2Buf.baseAddress else { return }

                for i in 0..<frames {
                    var x = base[i * ch + c]
                    for s in 0..<stages.count {
                        let stage = stages[s]
                        // 转置直接型 II：y = b0·x + z1；z1 = b1·x − a1·y + z2；z2 = b2·x − a2·y
                        let y = stage.b0 * x + z1P[s]
                        z1P[s] = stage.b1 * x - stage.a1 * y + z2P[s]
                        z2P[s] = stage.b2 * x - stage.a2 * y
                        x = y
                    }
                    base[i * ch + c] = x
                }
            }
        }
    }

    // MARK: - 双二阶

    /// 系数已按 a0 归一化，处理时只剩 5 次乘加
    struct Biquad {
        var b0: Float
        var b1: Float
        var b2: Float
        var a1: Float
        var a2: Float

        /// RBJ cookbook：二阶高通，Q = 0.707 时 f0 处 −3 dB
        static func highPass(hz: Double, sampleRate: Double, q: Double) -> Biquad {
            let w0 = 2 * Double.pi * hz / sampleRate
            let cosW = cos(w0)
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha
            return Biquad(b0: Float((1 + cosW) / 2 / a0),
                          b1: Float(-(1 + cosW) / a0),
                          b2: Float((1 + cosW) / 2 / a0),
                          a1: Float(-2 * cosW / a0),
                          a2: Float((1 - alpha) / a0))
        }

        /// RBJ cookbook：峰值（bell）
        static func peaking(hz: Double, gainDB: Double, sampleRate: Double, q: Double) -> Biquad {
            let A = pow(10, gainDB / 40)
            let w0 = 2 * Double.pi * hz / sampleRate
            let cosW = cos(w0)
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha / A
            return Biquad(b0: Float((1 + alpha * A) / a0),
                          b1: Float(-2 * cosW / a0),
                          b2: Float((1 - alpha * A) / a0),
                          a1: Float(-2 * cosW / a0),
                          a2: Float((1 - alpha / A) / a0))
        }

        /// RBJ cookbook：高架
        static func highShelf(hz: Double, gainDB: Double, sampleRate: Double) -> Biquad {
            let A = pow(10, gainDB / 40)
            let w0 = 2 * Double.pi * hz / sampleRate
            let cosW = cos(w0)
            let sinW = sin(w0)
            let alpha = sinW / 2 * sqrt(2)      // S = 1 时的标准斜率
            let beta = 2 * sqrt(A) * alpha

            let a0 = (A + 1) - (A - 1) * cosW + beta
            return Biquad(b0: Float(A * ((A + 1) + (A - 1) * cosW + beta) / a0),
                          b1: Float(-2 * A * ((A - 1) + (A + 1) * cosW) / a0),
                          b2: Float(A * ((A + 1) + (A - 1) * cosW - beta) / a0),
                          a1: Float(2 * ((A - 1) - (A + 1) * cosW) / a0),
                          a2: Float(((A + 1) - (A - 1) * cosW - beta) / a0))
        }

        /// 幅频响应的解析解（dB），测试用：直接代 z = e^{jw}
        func magnitudeDB(atHz hz: Double, sampleRate: Double) -> Double {
            let w = 2 * Double.pi * hz / sampleRate
            let cos1 = cos(w), sin1 = sin(w)
            let cos2 = cos(2 * w), sin2 = sin(2 * w)
            let numRe = Double(b0) + Double(b1) * cos1 + Double(b2) * cos2
            let numIm = -(Double(b1) * sin1 + Double(b2) * sin2)
            let denRe = 1 + Double(a1) * cos1 + Double(a2) * cos2
            let denIm = -(Double(a1) * sin1 + Double(a2) * sin2)
            let num = sqrt(numRe * numRe + numIm * numIm)
            let den = sqrt(denRe * denRe + denIm * denIm)
            guard den > 0 else { return 0 }
            return 20 * log10(num / den)
        }
    }
}
