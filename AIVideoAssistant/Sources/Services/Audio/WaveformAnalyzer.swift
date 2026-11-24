//
//  WaveformAnalyzer.swift
//  读取音频采样并计算峰值包络，供时间线片段与配音预览绘制真实波形
//
//  设计要点：
//  - 用 AVAudioFile 解码（m4a / mp3 / wav 都能读），逐桶取抽样峰值
//  - 每个文件只解码一次，固定分辨率存整段包络，再按需切片重采样
//    （这样裁剪片段后波形会跟着滑动，缓存也不会随片段宽度爆炸）
//  - 解码放在串行后台队列，回调回主线程发布
//

import Foundation
import AVFoundation
import Combine

/// 一个文件的整段包络
struct WaveformData: Equatable {
    /// 固定分辨率的峰值数组（0...1），整段文件
    var peaks: [Float]
    /// 文件时长（秒），用于把 sourceStart / duration 换算成下标
    var duration: Double
}

final class WaveformStore: ObservableObject {
    static let shared = WaveformStore()

    /// 固定分辨率：3 分钟音频约 0.18 s/桶，足够看清渐强渐弱，也不至于太占内存
    static let resolution = 1024

    /// key = 文件路径
    @Published private(set) var cache: [String: WaveformData] = [:]

    private var loading: Set<String> = []
    private let queue = DispatchQueue(label: "aiva.waveform", qos: .utility)

    private init() {}

    static func key(_ url: URL) -> String { url.path }

    /// 纯查询，不触发加载
    func cached(for url: URL) -> WaveformData? {
        cache[Self.key(url)]
    }

    func load(url: URL) {
        let k = Self.key(url)
        guard cache[k] == nil, !loading.contains(k) else { return }
        loading.insert(k)

        queue.async { [weak self] in
            let result = Self.computeFull(url: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(k)
                if let result { self.cache[k] = result }
            }
        }
    }

    // MARK: - 切片

    /// 从整段包络里切出 [sourceStart, sourceStart + duration) 这一段，重采样成 buckets 个桶
    /// - 取区间最大值而不是平均，瞬态（鼓点、爆破音）不会被平均掉
    static func slice(_ data: WaveformData,
                      sourceStart: Double,
                      duration: Double?,
                      buckets: Int) -> [Float] {
        let count = data.peaks.count
        guard buckets > 0, count > 0, data.duration > 0 else { return [] }

        let total = data.duration
        let start = min(max(0, sourceStart), total)
        let end = duration.map { min(total, start + max(0, $0)) } ?? total
        guard end > start else { return [Float](repeating: 0.02, count: buckets) }

        let i0 = min(count - 1, max(0, Int(start / total * Double(count))))
        var i1 = max(i0 + 1, Int((end / total * Double(count)).rounded()))
        i1 = min(count, i1)

        let span = Double(i1 - i0)
        var out = [Float](repeating: 0, count: buckets)
        for bucket in 0..<buckets {
            let from = i0 + Int(span * Double(bucket) / Double(buckets))
            var to = i0 + Int(span * Double(bucket + 1) / Double(buckets))
            if to <= from { to = min(i1, from + 1) }
            var peak: Float = 0
            for index in from..<to { peak = max(peak, data.peaks[index]) }
            out[bucket] = peak
        }
        return out
    }

    // MARK: - 计算

    /// 整段文件包络（固定分辨率）
    static func computeFull(url: URL) -> WaveformData? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }

        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let total = file.length
        guard total > 0, channels > 0 else { return nil }

        let buckets = resolution
        // 分块流式读取：长音频也不会一次性吃掉上百 MB
        let chunkFrames: AVAudioFrameCount = 16384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            return nil
        }

        var peaks = [Float](repeating: 0, count: buckets)
        var squares = [Double](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)

        let framesPerBucket = max(1.0, Double(total) / Double(buckets))
        var consumed: Double = 0

        file.framePosition = 0
        while true {
            guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 else { break }
            guard let data = buffer.floatChannelData else { break }
            let count = Int(buffer.frameLength)

            for index in 0..<count {
                let bucket = min(buckets - 1, Int((consumed + Double(index)) / framesPerBucket))
                var value: Float = 0
                for channel in 0..<channels {
                    value = max(value, abs(data[channel][index]))
                }
                if value > peaks[bucket] { peaks[bucket] = value }
                squares[bucket] += Double(value) * Double(value)
                counts[bucket] += 1
            }

            consumed += Double(count)
            if consumed >= Double(total) { break }
        }

        guard consumed > 0 else { return nil }

        // 峰值 + RMS 混合：纯峰值会把平滑信号压平，纯 RMS 又看不出瞬态
        var result = [Float](repeating: 0, count: buckets)
        for bucket in 0..<buckets {
            let rms = counts[bucket] > 0 ? sqrt(squares[bucket] / Double(counts[bucket])) : 0
            result[bucket] = Float(Double(peaks[bucket]) * 0.55 + rms * 0.45)
        }

        // 归一化，安静素材也能看清轮廓
        if let maxValue = result.max(), maxValue > 0.0005 {
            result = result.map { min(1, $0 / maxValue) }
        } else {
            result = result.map { _ in 0.04 }
        }

        let seconds = Double(total) / format.sampleRate
        return WaveformData(peaks: result, duration: seconds)
    }

    /// 整段文件的 N 桶包络（测试与快速预览用）
    static func compute(url: URL, buckets: Int) -> [Float]? {
        guard let data = computeFull(url: url) else { return nil }
        return slice(data, sourceStart: 0, duration: nil, buckets: buckets)
    }

    /// 占位波形（还在解码时显示），保证布局不跳
    static func placeholder(buckets: Int) -> [Float] {
        (0..<max(1, buckets)).map { index in
            let phase = Double(index) * 0.6
            return Float(0.16 + 0.12 * (sin(phase) * 0.5 + 0.5))
        }
    }
}
