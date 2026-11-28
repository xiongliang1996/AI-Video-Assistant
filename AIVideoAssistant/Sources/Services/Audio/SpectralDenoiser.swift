//
//  SpectralDenoiser.swift
//  谱减降噪：STFT → 逐频点噪声谱估计 → 维纳增益 → ISTFT 重叠相加
//
//  为什么自己写而不是挂一个降噪库：
//  - 上一版 AudioMastering 已经把整条混音渲染成 PCM 了，这里只是插一个纯函数步骤
//  - 谱减只要一份噪声谱估计，不依赖模型文件，打包体积一点不变
//
//  三个容易踩的点：
//  - sqrt-Hann 分析窗 × sqrt-Hann 合成窗 = Hann 窗，但重叠相加后每个采样点
//    覆盖到的窗和并不均匀（首尾不满、末端补零），所以按**实际累积的窗和**逐点
//    归一化，而不是除以常数 1.5。除以常数会让片头片尾音量掉下去
//  - 增益下限不能是 0。完全压零会让残留噪声在语音间隙「忽有忽无」，听感上
//    比噪声本身更烦。留 0.04–0.12 的底，残噪平稳就融进底噪了
//  - 噪声谱用**时间方向的低分位数**估，不是「前 N 秒当噪声」：口播素材常常
//    一开口就是人声，没有纯噪声段，取低分位数至少能落在停顿处
//

import Foundation

/// 降噪强度。数值越大越干净，但气声 / 齿音也越容易被削掉
enum DenoiseLevel: String, Codable, CaseIterable, Hashable {
    case off
    case light
    case medium
    case strong

    var label: String {
        switch self {
        case .off: return "关闭"
        case .light: return "轻度"
        case .medium: return "中等"
        case .strong: return "强力"
        }
    }

    var shortLabel: String { label }

    /// 过减因子：噪声谱乘多少再减。>1 更干净，但容易吃掉气声
    var overSubtraction: Double {
        switch self {
        case .off: return 1.0
        case .light: return 1.0
        case .medium: return 1.6
        case .strong: return 2.4
        }
    }

    /// 增益下限（线性幅度）。0.12 ≈ −18 dB，0.04 ≈ −28 dB
    var gainFloor: Double {
        switch self {
        case .off: return 1.0
        case .light: return 0.12
        case .medium: return 0.07
        case .strong: return 0.04
        }
    }

    var note: String {
        switch self {
        case .off: return "不动音频，保留原始底噪"
        case .light: return "只削明显底噪，气声和齿音基本不动"
        case .medium: return "口播常用，室内空调 / 风扇声能压下去"
        case .strong: return "底噪很重时用，人声会略微发闷"
        }
    }

    var isActive: Bool { self != .off }
}

enum SpectralDenoiser {

    /// 窗长 1024 @48k ≈ 21 ms，频率分辨率 47 Hz，够分辨人声与宽带噪声
    static let fftSize = 1024
    /// 75% 重叠：Hann 窗在这个重叠率下才满足 COLA
    static let hop = 256
    /// 估噪声谱时最多抽样这么多帧。噪声是平稳的，几百帧就够算分位数
    static let noiseSampleTarget = 1200
    /// 取时间方向的哪个分位当噪声。语音占空比通常 40–60%，20% 基本落在停顿
    static let noiseQuantile = 0.2

    /// 分位数 → 均值的偏置补偿。
    ///
    /// 平稳噪声的每个频点功率（|X|²）服从指数分布，取 q 分位只等于均值的
    /// `−ln(1−q)/2` 倍。q = 0.2 时是 0.11 倍，直接拿去减会系统性低估 9.5 dB，
    /// 结果就是「降噪几乎没效果」。乘回去才是真正的噪声均值。
    ///
    /// 补偿之后噪声谱偏保守（宁高勿低）：估高了顶多把气声压掉一点，
    /// 估低了等于没降噪，前者听感更容易接受。
    static var quantileBias: Double {
        2 / -log(1 - noiseQuantile)
    }

    struct Report: Equatable {
        /// 时域估的噪声底（dBFS）
        var noiseFloorDB: Double
        /// 整段 RMS 的衰减量（dB），0 表示几乎没动
        var reductionDB: Double
        /// 估噪声谱时实际算了几帧
        var sampledFrames: Int
        var level: DenoiseLevel

        var summary: String {
            guard noiseFloorDB.isFinite else { return "没有可估的噪声底，未处理" }
            return String(format: "噪声底 %.1f dBFS · 整体衰减 %.1f dB",
                          noiseFloorDB, max(0, reductionDB))
        }
    }

    // MARK: - 主入口

    /// 就地降噪。返回处理后的新数组与报告
    /// - Parameters:
    ///   - samples: 交织采样，范围 -1…1
    ///   - channels: 通道数
    static func denoise(samples: [Float],
                        channels: Int,
                        level: DenoiseLevel) -> (samples: [Float], report: Report?) {
        guard level.isActive, !samples.isEmpty else { return (samples, nil) }

        let ch = max(1, channels)
        let frames = samples.count / ch
        // 短于两窗的素材估不出噪声谱，原样返回
        guard frames > fftSize * 2 else { return (samples, nil) }

        let estimate = estimateNoise(samples, channels: ch, frames: frames)
        guard estimate.sampledFrames > 0,
              estimate.power.contains(where: { $0 > 0 }) else {
            return (samples, nil)
        }

        var output = [Float](repeating: 0, count: frames * ch)
        for c in 0..<ch {
            processChannel(samples, channel: c, channels: ch, frames: frames,
                           noise: estimate.power, level: level, into: &output)
        }

        let floorDB = noiseFloorDB(samples, channels: ch, frames: frames)
        let reduction = rmsReductionDB(before: samples, after: output, channels: ch, frames: frames)

        let report = Report(noiseFloorDB: floorDB,
                            reductionDB: reduction,
                            sampledFrames: estimate.sampledFrames,
                            level: level)
        return (output, report)
    }

    // MARK: - 噪声谱估计

    struct NoiseEstimate {
        /// 每个频点的噪声功率（单边，长度 = fftSize/2 + 1）
        var power: [Float]
        var sampledFrames: Int
    }

    /// 逐频点统计功率的时间分布，取低分位数当噪声谱。
    /// 用直方图而不是存全部帧：10 分钟素材有 11 万帧，全存下来是几百 MB
    static func estimateNoise(_ samples: [Float],
                              channels ch: Int,
                              frames: Int) -> NoiseEstimate {
        let n = fftSize
        let bins = n / 2 + 1
        let fft = RealFFT(n: n)
        let window = sqrtHann(n)
        let binsDB = 100          // −100…−1 dB，1 dB 一格

        let totalFrames = max(1, (frames - n) / hop + 1)
        // 向上取整：短素材也别全扫一遍，10 秒的片子有一千八百帧，没必要逐帧算
        let step = max(1, (totalFrames + noiseSampleTarget - 1) / noiseSampleTarget)

        var histogram = [Int32](repeating: 0, count: bins * binsDB)
        var sampled = 0

        var re = [Float](repeating: 0, count: n)
        var im = [Float](repeating: 0, count: n)
        var power = [Float](repeating: 0, count: bins)

        samples.withUnsafeBufferPointer { src in
            window.withUnsafeBufferPointer { win in
                power.withUnsafeMutableBufferPointer { powerBuf in
                    histogram.withUnsafeMutableBufferPointer { hist in
                        guard let srcP = src.baseAddress,
                              let winP = win.baseAddress,
                              let powerP = powerBuf.baseAddress,
                              let histP = hist.baseAddress else { return }
                        re.withUnsafeMutableBufferPointer { reBuf in
                            im.withUnsafeMutableBufferPointer { imBuf in
                                guard let reP = reBuf.baseAddress,
                                      let imP = imBuf.baseAddress else { return }
                                sampled = accumulateNoise(src: srcP, win: winP,
                                                          re: reP, im: imP,
                                                          power: powerP, histogram: histP,
                                                          fft: fft, channels: ch, frames: frames,
                                                          totalFrames: totalFrames, step: step)
                            }
                        }
                    }
                }
            }
        }

        var result = [Float](repeating: 0, count: bins)
        guard sampled > 0 else { return NoiseEstimate(power: result, sampledFrames: 0) }

        for k in 0..<bins {
            var total = 0
            for b in 0..<binsDB { total += Int(histogram[k * binsDB + b]) }
            guard total > 0 else { continue }
            let need = max(1, Int((Double(total) * noiseQuantile).rounded()))
            var acc = 0
            var picked = 0
            for b in 0..<binsDB {
                acc += Int(histogram[k * binsDB + b])
                if acc >= need { picked = b; break }
            }
            // 取格子的中点，避免系统性偏低 0.5 dB
            let db = Double(picked) - Double(binsDB) + 0.5
            result[k] = Float(pow(10, db / 10) * quantileBias)
        }

        // 频率方向 3 点平滑：单个频点估偏了会留下一个窄带的「洞」
        var smoothed = result
        for k in 1..<(bins - 1) {
            smoothed[k] = (result[k - 1] + 2 * result[k] + result[k + 1]) / 4
        }
        return NoiseEstimate(power: smoothed, sampledFrames: sampled)
    }

    /// 抽样扫描，把每帧功率落进直方图
    private static func accumulateNoise(src: UnsafePointer<Float>,
                                        win: UnsafePointer<Float>,
                                        re: UnsafeMutablePointer<Float>,
                                        im: UnsafeMutablePointer<Float>,
                                        power: UnsafeMutablePointer<Float>,
                                        histogram: UnsafeMutablePointer<Int32>,
                                        fft: RealFFT,
                                        channels ch: Int,
                                        frames: Int,
                                        totalFrames: Int,
                                        step: Int) -> Int {
        let n = fftSize
        let bins = n / 2 + 1
        let binsDB = 100
        let inv = 1 / Float(ch)
        var sampled = 0

        var frameIndex = 0
        while frameIndex < totalFrames {
            let position = frameIndex * hop
            for k in 0..<bins { power[k] = 0 }

            for c in 0..<ch {
                let available = min(n, frames - position)
                for i in 0..<available {
                    re[i] = src[(position + i) * ch + c] * win[i]
                    im[i] = 0
                }
                for i in available..<n {
                    re[i] = 0
                    im[i] = 0
                }
                fft.forward(re: re, im: im)
                // 各通道功率相加，最后再平均：共用一个噪声谱
                for k in 0..<bins {
                    power[k] += re[k] * re[k] + im[k] * im[k]
                }
            }

            for k in 0..<bins {
                let p = power[k] * inv
                guard p > 0 else { continue }
                let db = 10 * log10(p)
                var slot = Int(db.rounded(.down)) + binsDB
                if slot < 0 { slot = 0 }
                if slot >= binsDB { slot = binsDB - 1 }
                histogram[k * binsDB + slot] += 1
            }
            sampled += 1
            frameIndex += step
        }
        return sampled
    }

    // MARK: - 逐通道处理

    private static func processChannel(_ samples: [Float],
                                       channel c: Int,
                                       channels ch: Int,
                                       frames: Int,
                                       noise: [Float],
                                       level: DenoiseLevel,
                                       into output: inout [Float]) {
        let window = sqrtHann(fftSize)
        var accumulated = [Float](repeating: 0, count: frames)
        var windowSum = [Float](repeating: 0, count: frames)

        samples.withUnsafeBufferPointer { src in
            window.withUnsafeBufferPointer { win in
                noise.withUnsafeBufferPointer { noiseBuf in
                    accumulated.withUnsafeMutableBufferPointer { acc in
                        windowSum.withUnsafeMutableBufferPointer { wsum in
                            output.withUnsafeMutableBufferPointer { dst in
                                guard let srcP = src.baseAddress,
                                      let winP = win.baseAddress,
                                      let noiseP = noiseBuf.baseAddress,
                                      let accP = acc.baseAddress,
                                      let wsumP = wsum.baseAddress,
                                      let dstP = dst.baseAddress else { return }
                                processFrames(src: srcP, win: winP, noise: noiseP,
                                              acc: accP, wsum: wsumP, dst: dstP,
                                              channel: c, channels: ch, frames: frames,
                                              level: level)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 真正的逐帧循环。全用裸指针：10 秒立体声有七千多次 FFT，
    /// Array 下标的边界检查在这里是主要开销（实测慢 3 倍）
    private static func processFrames(src: UnsafePointer<Float>,
                                      win: UnsafePointer<Float>,
                                      noise: UnsafePointer<Float>,
                                      acc: UnsafeMutablePointer<Float>,
                                      wsum: UnsafeMutablePointer<Float>,
                                      dst: UnsafeMutablePointer<Float>,
                                      channel c: Int,
                                      channels ch: Int,
                                      frames: Int,
                                      level: DenoiseLevel) {
        let n = fftSize
        let bins = n / 2 + 1
        let fft = RealFFT(n: n)

        let re = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let im = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let gain = UnsafeMutablePointer<Float>.allocate(capacity: bins)
        let smoothed = UnsafeMutablePointer<Float>.allocate(capacity: bins)
        let prevGain = UnsafeMutablePointer<Float>.allocate(capacity: bins)
        defer {
            re.deallocate()
            im.deallocate()
            gain.deallocate()
            smoothed.deallocate()
            prevGain.deallocate()
        }
        for k in 0..<bins { prevGain[k] = 1 }

        let overSub = Float(level.overSubtraction)
        let floorGain = Float(level.gainFloor)

        var position = 0
        while position < frames {
            // 装载一帧。尾部不够就补零
            let available = min(n, frames - position)
            for i in 0..<available {
                re[i] = src[(position + i) * ch + c] * win[i]
                im[i] = 0
            }
            for i in available..<n {
                re[i] = 0
                im[i] = 0
            }
            fft.forward(re: re, im: im)

            // 维纳增益：G = sqrt((P − αN) / P)，再夹到 [floor, 1]
            for k in 0..<bins {
                let p = re[k] * re[k] + im[k] * im[k]
                let noisePower = noise[k] * overSub
                var g: Float
                if p > 1e-20 {
                    g = sqrt(max(0, (p - noisePower) / p))
                } else {
                    g = noisePower > 0 ? 0 : 1
                }
                if g < floorGain { g = floorGain }
                if g > 1 { g = 1 }
                gain[k] = g
            }

            // 频率方向 3 点平滑
            smoothed[0] = gain[0]
            smoothed[bins - 1] = gain[bins - 1]
            if bins > 2 {
                for k in 1..<(bins - 1) {
                    smoothed[k] = (gain[k - 1] + 2 * gain[k] + gain[k + 1]) / 4
                }
            }

            // 时间方向：上升快、下降慢。下降太快会让残留噪声跟着音节跳，
            // 也就是常说的「音乐噪声」
            for k in 0..<bins {
                let g = smoothed[k]
                let previous = prevGain[k]
                let blended: Float
                if g > previous {
                    blended = previous * 0.35 + g * 0.65
                } else {
                    blended = previous * 0.80 + g * 0.20
                }
                smoothed[k] = blended
                prevGain[k] = blended
            }

            // 应用增益。0 和 Nyquist 是实数，中间频点要连带共轭一起乘
            for k in 0..<bins {
                let g = smoothed[k]
                re[k] *= g
                im[k] *= g
            }
            if bins > 2 {
                for k in 1..<(n / 2) {
                    let g = smoothed[k]
                    re[n - k] *= g
                    im[n - k] *= g
                }
            }

            fft.inverse(re: re, im: im)

            // 重叠相加。合成窗与分析窗相同，乘积是 Hann
            for i in 0..<available {
                acc[position + i] += re[i] * win[i]
                wsum[position + i] += win[i] * win[i]
            }
            position += hop
        }

        for i in 0..<frames {
            let w = wsum[i]
            dst[i * ch + c] = w > 1e-6 ? acc[i] / w : 0
        }
    }

    // MARK: - 辅助

    /// sqrt-Hann。分析窗与合成窗都用它，乘积正好是 Hann
    static func sqrtHann(_ n: Int) -> [Float] {
        var window = [Float](repeating: 0, count: n)
        for i in 0..<n {
            window[i] = sqrt(max(0, 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(n))))
        }
        return window
    }

    /// 时域噪声底：切成 100 ms 块，取能量最低 20% 的块算 RMS
    static func noiseFloorDB(_ samples: [Float], channels ch: Int, frames: Int) -> Double {
        let blockFrames = 4800   // 100 ms @48k
        guard frames >= blockFrames else { return -.infinity }

        var energies: [Double] = []
        energies.reserveCapacity(frames / blockFrames + 1)
        var start = 0
        while start + blockFrames <= frames {
            var sum = 0.0
            for c in 0..<ch {
                var channelSum = 0.0
                for i in start..<(start + blockFrames) {
                    let v = Double(samples[i * ch + c])
                    channelSum += v * v
                }
                sum += channelSum / Double(blockFrames)
            }
            energies.append(sum / Double(ch))
            start += blockFrames
        }
        guard !energies.isEmpty else { return -.infinity }

        let sorted = energies.sorted()
        let count = max(1, Int((Double(sorted.count) * noiseQuantile).rounded()))
        let mean = sorted.prefix(count).reduce(0, +) / Double(count)
        guard mean > 0 else { return -.infinity }
        return 10 * log10(mean)
    }

    private static func rmsReductionDB(before: [Float],
                                       after: [Float],
                                       channels ch: Int,
                                       frames: Int) -> Double {
        var beforeEnergy = 0.0
        var afterEnergy = 0.0
        let total = frames * ch
        for i in 0..<total {
            let a = Double(before[i])
            let b = Double(after[i])
            beforeEnergy += a * a
            afterEnergy += b * b
        }
        guard beforeEnergy > 0, afterEnergy > 0 else { return 0 }
        return 10 * log10(beforeEnergy / afterEnergy)
    }
}

// MARK: - FFT

/// 定长 radix-2 复数 FFT。旋转因子与位反转表预计算，逐帧复用
struct RealFFT {
    let n: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let reverse: [Int]

    init(n: Int) {
        precondition(n >= 4 && n & (n - 1) == 0, "FFT 长度必须是 2 的幂")
        self.n = n

        let half = n / 2
        var c = [Float](repeating: 0, count: half)
        var s = [Float](repeating: 0, count: half)
        for i in 0..<half {
            let angle = -2 * Float.pi * Float(i) / Float(n)
            c[i] = cos(angle)
            s[i] = sin(angle)
        }
        cosTable = c
        sinTable = s

        var rev = [Int](repeating: 0, count: n)
        var j = 0
        for i in 0..<n {
            rev[i] = j
            var m = n >> 1
            while m >= 1, j >= m {
                j -= m
                m >>= 1
            }
            j += m
        }
        reverse = rev
    }

    func forward(_ re: inout [Float], _ im: inout [Float]) {
        re.withUnsafeMutableBufferPointer { reBuf in
            im.withUnsafeMutableBufferPointer { imBuf in
                guard let reP = reBuf.baseAddress, let imP = imBuf.baseAddress else { return }
                forward(re: reP, im: imP)
            }
        }
    }

    /// 指针版本，给逐帧循环用：省掉每帧的数组绑定与边界检查
    func forward(re reP: UnsafeMutablePointer<Float>, im imP: UnsafeMutablePointer<Float>) {
        let n = self.n
        // 蝶形循环是热点：用裸指针跑，Array 下标的边界检查在这里能吃掉一半时间
        cosTable.withUnsafeBufferPointer { cosBuf in
            sinTable.withUnsafeBufferPointer { sinBuf in
                reverse.withUnsafeBufferPointer { revBuf in
                    guard let cosP = cosBuf.baseAddress,
                          let sinP = sinBuf.baseAddress,
                          let revP = revBuf.baseAddress else { return }
                    transform(re: reP, im: imP, cos: cosP, sin: sinP, rev: revP, n: n)
                }
            }
        }
    }

    func inverse(_ re: inout [Float], _ im: inout [Float]) {
        for i in 0..<n { im[i] = -im[i] }
        forward(&re, &im)
        let scale = 1 / Float(n)
        for i in 0..<n {
            re[i] *= scale
            im[i] = -im[i] * scale
        }
    }

    func inverse(re reP: UnsafeMutablePointer<Float>, im imP: UnsafeMutablePointer<Float>) {
        for i in 0..<n { imP[i] = -imP[i] }
        forward(re: reP, im: imP)
        let scale = 1 / Float(n)
        for i in 0..<n {
            reP[i] *= scale
            imP[i] = -imP[i] * scale
        }
    }

    private func transform(re reP: UnsafeMutablePointer<Float>,
                           im imP: UnsafeMutablePointer<Float>,
                           cos cosP: UnsafePointer<Float>,
                           sin sinP: UnsafePointer<Float>,
                           rev revP: UnsafePointer<Int>,
                           n: Int) {
        for i in 0..<n {
            let j = revP[i]
            if j > i {
                let tr = reP[i]; reP[i] = reP[j]; reP[j] = tr
                let ti = imP[i]; imP[i] = imP[j]; imP[j] = ti
            }
        }

        var size = 2
        while size <= n {
            let half = size >> 1
            let step = n / size
            var start = 0
            while start < n {
                var k = 0
                var j = start
                let end = start + half
                while j < end {
                    let c = cosP[k]
                    let s = sinP[k]
                    let l = j + half
                    let tre = reP[l] * c - imP[l] * s
                    let tim = reP[l] * s + imP[l] * c
                    reP[l] = reP[j] - tre
                    imP[l] = imP[j] - tim
                    reP[j] += tre
                    imP[j] += tim
                    k += step
                    j += 1
                }
                start += size
            }
            size <<= 1
        }
    }
}
