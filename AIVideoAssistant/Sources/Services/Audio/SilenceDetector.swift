//
//  SilenceDetector.swift
//  分析音频里的语音 / 停顿分布，给「智能剪辑」提供切点
//
//  做法：按固定窗口（20 ms）算 RMS 转 dBFS，低于阈值判为静音，
//  再把连续同类窗口合并成段，最后按「最短停顿 / 最短语句」做二次判定：
//  - 太短的停顿当成语句的一部分（喘气、齿音不算停顿）
//  - 太短的语句当成停顿（咔哒声、口水音不算语句）
//

import Foundation
import AVFoundation

struct SpeechAnalysis: Equatable {
    /// 文件时长（秒）
    var duration: Double = 0
    /// 检测到的静音区间（文件时间）
    var silences: [ClosedRange<Double>] = []
    /// 检测到的语音区间（文件时间）
    var speech: [ClosedRange<Double>] = []

    var silenceDuration: Double {
        silences.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    var speechDuration: Double {
        speech.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// 停顿占全片比例
    var silenceRatio: Double {
        duration > 0 ? min(1, silenceDuration / duration) : 0
    }
}

enum SilenceDetector {
    /// 分析窗口长度（秒）
    private static let windowSeconds: Double = 0.02

    /// - Parameters:
    ///   - thresholdDB: 低于该电平判为静音（dBFS，-160…0）
    ///   - minSilence: 短于该长度的静音不算停顿
    ///   - minSpeech: 短于该长度的语音不算语句
    static func analyze(url: URL,
                        thresholdDB: Float = -34,
                        minSilence: Double = 0.35,
                        minSpeech: Double = 0.25) -> SpeechAnalysis? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }

        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let sampleRate = format.sampleRate
        let totalFrames = file.length
        guard totalFrames > 0, channels > 0, sampleRate > 0 else { return nil }

        let windowFrames = max(1, Int(windowSeconds * sampleRate))
        let chunkFrames: AVAudioFrameCount = 16384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            return nil
        }

        // 每个窗口一个 dB 值
        var levels: [Float] = []
        levels.reserveCapacity(Int(Double(totalFrames) / Double(windowFrames)) + 1)

        var windowSquare: Double = 0
        var windowCount = 0

        file.framePosition = 0
        while true {
            guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 else { break }
            guard let data = buffer.floatChannelData else { break }
            let count = Int(buffer.frameLength)

            for index in 0..<count {
                var peak: Float = 0
                for channel in 0..<channels {
                    peak = max(peak, abs(data[channel][index]))
                }
                windowSquare += Double(peak) * Double(peak)
                windowCount += 1

                if windowCount >= windowFrames {
                    levels.append(db(fromMeanSquare: windowSquare / Double(windowCount)))
                    windowSquare = 0
                    windowCount = 0
                }
            }
        }
        if windowCount > 0 {
            levels.append(db(fromMeanSquare: windowSquare / Double(windowCount)))
        }
        guard !levels.isEmpty else { return nil }

        // 逐窗口判定后合并成段
        var runs: [(isSilence: Bool, start: Double, end: Double)] = []
        var currentSilence = levels[0] < thresholdDB
        var runStart = 0.0
        for (index, level) in levels.enumerated() {
            let isSilence = level < thresholdDB
            if isSilence != currentSilence {
                runs.append((currentSilence, runStart, Double(index) * windowSeconds))
                runStart = Double(index) * windowSeconds
                currentSilence = isSilence
            }
        }
        runs.append((currentSilence, runStart, Double(levels.count) * windowSeconds))

        // 二次判定：太短的停顿并回语句，太短的语句并回停顿
        var refined: [(isSilence: Bool, start: Double, end: Double)] = []
        for run in runs {
            var run = run
            let length = run.end - run.start
            if run.isSilence && length < minSilence { run.isSilence = false }
            if !run.isSilence && length < minSpeech { run.isSilence = true }
            if let last = refined.last, last.isSilence == run.isSilence {
                refined[refined.count - 1].end = run.end
            } else {
                refined.append(run)
            }
        }

        let duration = Double(totalFrames) / sampleRate
        var analysis = SpeechAnalysis(duration: duration)
        for run in refined {
            let range = max(0, run.start)...min(duration, run.end)
            guard range.upperBound - range.lowerBound > 0.01 else { continue }
            if run.isSilence {
                analysis.silences.append(range)
            } else {
                analysis.speech.append(range)
            }
        }
        return analysis
    }

    /// 平均功率 → dBFS（-160 兜底，避免 log(0)）
    private static func db(fromMeanSquare meanSquare: Double) -> Float {
        guard meanSquare > 0 else { return -160 }
        return Float(10 * log10(meanSquare))
    }

    /// 静音区间的中点，作为切点
    static func cutPoints(from analysis: SpeechAnalysis) -> [Double] {
        analysis.silences.map { ($0.lowerBound + $0.upperBound) / 2 }
    }
}
