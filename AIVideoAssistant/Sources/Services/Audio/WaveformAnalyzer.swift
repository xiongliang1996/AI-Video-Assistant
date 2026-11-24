//
//  WaveformAnalyzer.swift
//  读取音频采样并计算峰值包络，供时间线片段与配音预览绘制真实波形
//
//  设计要点：
//  - 用 AVAudioFile 解码（m4a / mp3 / wav 都能读），逐桶取抽样峰值
//  - 结果按「文件路径 + 桶数」缓存，避免重复解码
//  - 解码放在串行后台队列，回调回主线程发布
//

import Foundation
import AVFoundation
import Combine

final class WaveformStore: ObservableObject {
    static let shared = WaveformStore()

    /// key = "path#buckets"
    @Published private(set) var cache: [String: [Float]] = [:]

    private var loading: Set<String> = []
    private let queue = DispatchQueue(label: "aiva.waveform", qos: .utility)

    private init() {}

    static func key(_ url: URL, buckets: Int) -> String {
        "\(url.path)#\(buckets)"
    }

    /// 纯查询，不触发加载
    func cachedPeaks(for url: URL, buckets: Int) -> [Float]? {
        cache[Self.key(url, buckets: buckets)]
    }

    func load(url: URL, buckets: Int) {
        let k = Self.key(url, buckets: buckets)
        guard cache[k] == nil, !loading.contains(k) else { return }
        loading.insert(k)

        queue.async { [weak self] in
            let result = Self.compute(url: url, buckets: buckets)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(k)
                if let result { self.cache[k] = result }
            }
        }
    }

    // MARK: - 计算

    static func compute(url: URL, buckets: Int) -> [Float]? {
        guard buckets > 0 else { return nil }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }

        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let total = file.length
        guard total > 0, channels > 0 else { return nil }

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
        return result
    }

    /// 占位波形（还在解码时显示），保证布局不跳
    static func placeholder(buckets: Int) -> [Float] {
        (0..<max(1, buckets)).map { index in
            let phase = Double(index) * 0.6
            return Float(0.16 + 0.12 * (sin(phase) * 0.5 + 0.5))
        }
    }
}
