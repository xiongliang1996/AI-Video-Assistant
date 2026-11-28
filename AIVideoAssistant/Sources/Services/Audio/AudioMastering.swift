//
//  AudioMastering.swift
//  把整条时间线的混音渲染成 PCM，按目标响度加增益，再作为唯一音轨塞回合成
//
//  为什么要绕这一圈：
//  - `AVAudioMix` 的 volume 只接受 0…1，只能衰减不能提升。想让安静的口播
//    达到 -14 LUFS 必须自己动 PCM
//  - 两条导出路径（ExportSession / AssetWriter 逐帧）都吃同一个 composition，
//    所以「换掉音频轨」这一刀切下去两边同时生效，不用改渲染逻辑
//
//  顺序：读（带 audioMix，音量/淡入淡出/闪避包络都已应用）→ 测响度 →
//        算增益 → 就地乘 + 软膝限幅 → 写临时 WAV → 替换音频轨
//

import Foundation
import AVFoundation

/// 响度目标。数值是积分响度（LUFS）
enum LoudnessTarget: String, Codable, CaseIterable, Hashable {
    case off
    case streaming
    case podcast
    case broadcast

    var lufs: Double? {
        switch self {
        case .off: return nil
        case .streaming: return -14
        case .podcast: return -16
        case .broadcast: return -23
        }
    }

    var label: String {
        switch self {
        case .off: return "关闭"
        case .streaming: return "网络 −14 LUFS"
        case .podcast: return "播客 −16 LUFS"
        case .broadcast: return "广播 −23 LUFS"
        }
    }

    var shortLabel: String {
        switch self {
        case .off: return "关闭"
        case .streaming: return "−14"
        case .podcast: return "−16"
        case .broadcast: return "−23"
        }
    }

    var note: String {
        switch self {
        case .off: return "保持原样，不做任何增益"
        case .streaming: return "YouTube / B站 / 抖音 会把响度往 −14 拉，先对齐就不容易被压"
        case .podcast: return "播客常用 −16，人声留一点余量，长时间听不累"
        case .broadcast: return "EBU R128 广播标准 −23，动态留得最多"
        }
    }
}

enum AudioMastering {

    /// 一次标准化的结果，给日志和界面用
    struct Report: Equatable {
        var measured: LoudnessMeter.Result
        var gain: Double
        var limitedByPeak: Bool
        var target: LoudnessTarget
        var clippedSamples: Int
        /// 降噪这一步的结果，没开降噪时是 nil
        var denoise: SpectralDenoiser.Report?
        /// 均衡这一步的结果，没开均衡时是 nil
        var equalizer: Equalizer.Report?
        /// 压缩这一步的结果，没开压缩时是 nil
        var compressor: Compressor.Report?

        /// 一行摘要：−18.3 LUFS → −14.0（+4.3 dB）
        var summary: String {
            guard !measured.isSilent else { return "整段接近静音，未做标准化" }
            // 只做前处理、不调响度时别显示「→ 同一个数」
            guard target.lufs != nil else {
                var parts: [String] = []
                if let equalizer { parts.append("均衡 · \(equalizer.summary)") }
                if let denoise { parts.append("降噪 · \(denoise.summary)") }
                if let compressor { parts.append("压缩 · \(compressor.summary)") }
                return parts.isEmpty ? "未做处理" : parts.joined(separator: " ｜ ")
            }
            let sign = gain >= 0 ? "+" : "−"
            let text = String(format: "%.1f LUFS → %.1f LUFS（%@%.1f dB）",
                              measured.integrated,
                              measured.integrated + gain,
                              sign,
                              abs(gain))
            return limitedByPeak ? text + "，受峰值限制" : text
        }
    }

    /// 目标真峰值上限。−1 dBFS 是编码器（AAC / MP3）留的余量
    static let peakCeiling: Double = -1.0
    /// 统一按 48 kHz 立体声处理：AAC 本来就在这附近，省一次重采样
    static let sampleRate: Double = 48000
    static let channels: Int = 2

    // MARK: - 只测不改

    /// 测整条时间线的混音响度（不写文件、不改合成）
    static func measure(build: CompositionBuild) async throws -> LoudnessMeter.Result? {
        guard let pcm = try await renderPCM(composition: build.composition,
                                            audioMix: build.audioMix) else { return nil }
        return LoudnessMeter.measure(samples: pcm.samples,
                                     sampleRate: pcm.sampleRate,
                                     channels: pcm.channels)
    }

    // MARK: - 标准化

    /// - Parameters:
    ///   - noiseSample: 手动框定的噪声区间（时间线秒）。nil 时自动估计
    /// - Returns: 新合成（音频轨已被替换）+ 报告 + 临时 WAV 地址（调用方负责删）
    static func mastered(build: CompositionBuild,
                         target: LoudnessTarget,
                         denoise: DenoiseLevel = .off,
                         noiseSample: NoiseSample? = nil,
                         equalizer: EqualizerSettings = EqualizerSettings(),
                         compressor: CompressorSettings = CompressorSettings(),
                         progress: @escaping (Double, String) -> Void) async throws
        -> (build: CompositionBuild, report: Report?, tempURL: URL?) {

        guard target.lufs != nil || denoise.isActive
                || equalizer.isActive || compressor.isActive else {
            return (build, nil, nil)
        }

        await MainActor.run {
            progress(0.06, denoise.isActive ? "正在分析噪声…" : "正在分析响度…")
        }

        guard let pcm = try await renderPCM(composition: build.composition,
                                            audioMix: build.audioMix) else {
            // 没有音轨：原样返回，不算失败
            return (build, nil, nil)
        }

        var samples = pcm.samples
        var denoiseReport: SpectralDenoiser.Report?
        var equalizerReport: Equalizer.Report?
        var compressorReport: Compressor.Report?

        // 均衡排在降噪前面：低切先把 60–120 Hz 的隆隆声去掉，
        // 降噪不用再费劲估那一段的噪声谱；提升频段也会被降噪一并考虑进去
        if equalizer.isActive {
            await MainActor.run { progress(0.07, "正在均衡…") }
            equalizerReport = Equalizer.process(&samples,
                                                channels: pcm.channels,
                                                settings: equalizer,
                                                sampleRate: pcm.sampleRate)
        }

        // 降噪必须在测响度之前：降噪会削掉一部分能量，
        // 先测后降会让最终响度整体偏高（目标 −14 出成 −12）
        if denoise.isActive {
            await MainActor.run { progress(0.08, "正在降噪…") }
            let range = noiseFrameRange(sample: noiseSample,
                                        sampleRate: pcm.sampleRate,
                                        channels: pcm.channels,
                                        sampleCount: samples.count)
            let outcome = SpectralDenoiser.denoise(samples: samples,
                                                   channels: pcm.channels,
                                                   level: denoise,
                                                   noiseRange: range)
            samples = outcome.samples
            denoiseReport = outcome.report
        }

        // 压缩排在降噪之后：先清掉底噪，否则补偿增益会把底噪一起抬起来。
        // 又必须在测响度之前：压缩改变了动态范围，先测后压会让目标响度算偏
        if compressor.isActive {
            await MainActor.run { progress(0.09, "正在压缩动态…") }
            compressorReport = Compressor.process(&samples,
                                                  channels: pcm.channels,
                                                  settings: compressor,
                                                  sampleRate: pcm.sampleRate)
        }

        let measured = LoudnessMeter.measure(samples: samples,
                                             sampleRate: pcm.sampleRate,
                                             channels: pcm.channels)

        var gain = 0.0
        var limitedByPeak = false
        var clipped = 0

        // 全静音不折腾：增益只会把噪声底抬起来
        if let lufs = target.lufs, !measured.isSilent {
            let decision = LoudnessMeter.gain(measured: measured,
                                              target: lufs,
                                              peakCeiling: peakCeiling)
            // 小于 0.05 dB 就别动了，省一次全片重写
            if abs(decision.gain) >= 0.05 {
                await MainActor.run { progress(0.12, "正在调整响度…") }
                clipped = LoudnessMeter.applyGain(&samples,
                                                  gainDB: decision.gain,
                                                  ceilingDB: peakCeiling)
                gain = decision.gain
                limitedByPeak = decision.limitedByPeak
            }
        }

        let report = Report(measured: measured,
                            gain: gain,
                            limitedByPeak: limitedByPeak,
                            target: target,
                            clippedSamples: clipped,
                            denoise: denoiseReport,
                            equalizer: equalizerReport,
                            compressor: compressorReport)

        // 前处理没跑成、响度也不需要动：原样返回，别白写一遍整条音轨
        let compressorChanged = compressorReport?.triggered == true
        guard denoiseReport != nil || equalizerReport != nil
                || compressorChanged || abs(gain) > 0 else {
            return (build, report, nil)
        }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiva-master-\(UUID().uuidString).wav")
        try writeWAV(samples: samples, sampleRate: pcm.sampleRate,
                     channels: pcm.channels, to: temp)

        await MainActor.run { progress(0.18, "正在替换音轨…") }

        let composition = build.composition
        try await replaceAudio(in: composition, with: temp)

        let rebuilt = CompositionBuild(composition: composition,
                                       videoComposition: build.videoComposition,
                                       // 音量包络已经烘进 PCM，再挂一次会叠两遍
                                       audioMix: nil,
                                       duration: build.duration)
        return (rebuilt, report, temp)
    }

    /// 时间线秒 → 采样帧区间。
    ///
    /// 这里不做「时间线时间 → 合成时间」的换算：`renderPCM` 读的是整条合成，
    /// 输出起点就是合成起点，两者本来就对齐。区间越界或太短时返回 nil，
    /// 让降噪器退回自动估计。
    static func noiseFrameRange(sample: NoiseSample?,
                                sampleRate: Double,
                                channels: Int,
                                sampleCount: Int) -> Range<Int>? {
        guard let sample else { return nil }
        let ch = max(1, channels)
        let frames = sampleCount / ch
        guard frames > 0 else { return nil }

        let a = Int((sample.start * sampleRate).rounded())
        let b = Int((sample.end * sampleRate).rounded())
        let lo = max(0, min(min(a, b), frames))
        let hi = max(0, min(max(a, b), frames))
        // 少于一个 FFT 窗估不出谱，交给自动路径
        guard hi - lo >= SpectralDenoiser.fftSize else { return nil }
        return lo..<hi
    }

    // MARK: - 读 PCM

    struct PCM {
        var samples: [Float]
        var sampleRate: Double
        var channels: Int
    }

    static func renderPCM(composition: AVComposition,
                          audioMix: AVAudioMix?) async throws -> PCM? {
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }

        let reader = try AVAssetReader(asset: composition)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.audioMix = audioMix
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw VideoError.exportFailed("无法读取音轨")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw VideoError.exportFailed(reader.error?.localizedDescription ?? "音频解码启动失败")
        }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(buffer) }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }

            var pointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(block,
                                                     atOffset: 0,
                                                     lengthAtOffsetOut: nil,
                                                     totalLengthOut: nil,
                                                     dataPointerOut: &pointer)
            guard status == kCMBlockBufferNoErr, let pointer else { continue }

            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { rebound in
                samples.append(contentsOf: UnsafeBufferPointer(start: rebound, count: count))
            }
        }

        if reader.status == .failed {
            throw VideoError.exportFailed(reader.error?.localizedDescription ?? "音频读取失败")
        }
        guard !samples.isEmpty else { return nil }
        return PCM(samples: samples, sampleRate: sampleRate, channels: channels)
    }

    // MARK: - 写 WAV

    /// 32 位 IEEE float 交织 WAV。手写头比 ExtAudioFile 省事，也能精确控制字节序
    static func writeWAV(samples: [Float],
                         sampleRate: Double,
                         channels: Int,
                         to url: URL) throws {
        let ch = max(1, channels)
        let rate = UInt32(sampleRate.rounded())
        let dataSize = UInt32(samples.count * MemoryLayout<Float>.size)
        let byteRate = rate * UInt32(ch) * 4
        let blockAlign = UInt16(ch * 4)

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(36 + dataSize)
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(3)              // 3 = IEEE float
        append16(UInt16(ch))
        append32(rate)
        append32(byteRate)
        append16(blockAlign)
        append16(32)
        append("data")
        append32(dataSize)
        samples.withUnsafeBufferPointer { buffer in
            data.append(UnsafeBufferPointer(start: UnsafeRawPointer(buffer.baseAddress)?
                .assumingMemoryBound(to: UInt8.self), count: buffer.count * 4))
        }

        try data.write(to: url, options: .atomic)
    }

    // MARK: - 替换音轨

    /// 把合成里的音频轨全删掉，换成这一条
    static func replaceAudio(in composition: AVMutableComposition, with url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let source = sourceTracks.first else {
            throw VideoError.noAudioTrack
        }
        let duration = try await asset.load(.duration)
        guard duration > .zero else { throw VideoError.noAudioTrack }

        // 先加新轨再删旧轨：万一中途失败，原有音轨还在
        guard let destination = composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoError.exportFailed("无法新建音频轨")
        }
        try destination.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                        of: source,
                                        at: .zero)

        for track in composition.tracks(withMediaType: .audio) where track != destination {
            composition.removeTrack(track)
        }
    }
}
