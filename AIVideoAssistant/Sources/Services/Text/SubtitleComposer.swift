//
//  SubtitleComposer.swift
//  文稿 → 字幕：自动断句 + 按语音停顿对齐时间轴
//
//  全部是纯函数，不碰 SwiftUI、不碰 AppState，方便直接跑断言。
//  断句和时长估算都按「视觉长度」算：一个汉字算 1，一个 ASCII 字符算 0.55，
//  这样一个英文单词不会因为字母多就被判成超长。
//

import Foundation

// MARK: - 断句

enum SubtitleBreaker {

    struct Options {
        /// 单条最大视觉长度（约等于多少个汉字）
        var maxLength: Double = 18
        /// 单条最小视觉长度，太短的会尽量并到相邻条
        var minLength: Double = 6
        /// 用户手动换行视为强制分段
        var hardBreakOnNewline: Bool = true

        static let `default` = Options()
    }

    /// 句末标点：在这些字符之后断句
    private static let sentenceEnders: Set<Character> = ["。", "！", "？", "!", "?", "…", "；", ";"]
    /// 句中标点：句子太长时优先在这些位置断开。
    /// 破折号也算：它本身就是语义停顿，比硬切好得多，而且能避免把「——」劈成两半。
    private static let clauseEnders: Set<Character> = ["，", ",", "、", "：", ":", "—", "–"]
    /// 不能出现在行首的标点
    private static let noLineStart: Set<Character> = [
        "，", "。", "、", "；", "：", "！", "？", ",", ".", ";", ":", "!", "?",
        "…", "」", "』", "】", "）", "》", "”", "’", "·"
    ]
    /// 不能出现在行尾的标点
    private static let noLineEnd: Set<Character> = ["（", "「", "『", "【", "《", "“", "‘"]

    // MARK: 长度估算

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x3040...0x30FF, 0xAC00...0xD7AF, 0x3000...0x303F, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }

    /// 视觉长度：汉字 1，ASCII 0.55
    static func visualLength(_ text: String) -> Double {
        var length = 0.0
        for scalar in text.unicodeScalars {
            length += isCJK(scalar) ? 1 : 0.55
        }
        return length
    }

    /// 发音权重：汉字 1，一个英文单词约 1.6（音节感）
    static func weight(_ text: String) -> Double {
        var result = 0.0
        var inLatinWord = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                result += 1
                inLatinWord = false
            } else if scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)) {
                if !inLatinWord {
                    result += 1.6
                    inLatinWord = true
                }
            } else {
                inLatinWord = false
            }
        }
        return max(1, result)
    }

    // MARK: 主入口

    static func breakText(_ text: String, options: Options = .default) -> [String] {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return [] }

        var lines: [String] = []
        // 手动换行 / 空行都当成强制分段
        let paragraphs = options.hardBreakOnNewline
            ? normalized.components(separatedBy: "\n")
            : [normalized]

        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            for sentence in splitKeeping(trimmed, separators: sentenceEnders) {
                for piece in packSentence(sentence, options: options) {
                    lines.append(piece)
                }
            }
        }

        lines = mergeShort(lines, options: options)
        lines = fixLineEdges(lines)
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: 归一化

    static func normalize(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // 全角空格当普通空格，连续空白压成一个
        result = result.replacingOccurrences(of: "\u{3000}", with: " ")
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按分隔符切分，标点留在前一段末尾；紧随其后的同类标点一起吞掉（如「……」「？！」）
    static func splitKeeping(_ text: String, separators: Set<Character>) -> [String] {
        let chars = Array(text)
        var result: [String] = []
        var current = ""
        var index = 0
        while index < chars.count {
            current.append(chars[index])
            if separators.contains(chars[index]) {
                while index + 1 < chars.count, separators.contains(chars[index + 1]) {
                    index += 1
                    current.append(chars[index])
                }
                result.append(current)
                current = ""
            }
            index += 1
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(current) }
        return result
    }

    // MARK: 装箱

    /// 一句 → 若干条：优先在句中标点处断，单段过长再硬切
    static func packSentence(_ sentence: String, options: Options) -> [String] {
        let clauses = splitKeeping(sentence, separators: clauseEnders)
        var lines: [String] = []
        var current = ""

        for clause in clauses {
            let clauseLength = visualLength(clause)
            // 只比上限长一点点（通常是标点）就留着，强行切比略超更难读
            if clauseLength > options.maxLength * Self.hardSplitThreshold {
                if !current.isEmpty {
                    lines.append(current)
                    current = ""
                }
                lines.append(contentsOf: hardSplit(clause, maxLength: options.maxLength))
                continue
            }
            if current.isEmpty {
                current = clause
            } else if visualLength(current) + clauseLength <= options.maxLength {
                current += clause
            } else {
                lines.append(current)
                current = clause
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 超过上限多少倍才值得硬切。中文没有空格，硬切必然切断词语，
    /// 所以宁可略超也不要为了两三个字把一句话劈开。
    private static let hardSplitThreshold: Double = 1.2

    /// 没有标点可依的超长文本：**均匀**切分。
    /// 不能切满一段再把剩下的两三个字甩成一条，那样最后一条会短得没法看。
    static func hardSplit(_ text: String, maxLength: Double) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let total = visualLength(trimmed)
        let parts = max(1, Int((total / maxLength).rounded(.up)))
        guard parts > 1 else { return [trimmed] }

        let target = total / Double(parts)
        var buffer = Array(trimmed)
        var result: [String] = []

        for _ in 0..<(parts - 1) {
            guard !buffer.isEmpty else { break }
            var take = 0
            var length = 0.0
            while take < buffer.count, length < target {
                length += visualLength(String(buffer[take]))
                take += 1
            }
            take = min(max(1, take), buffer.count)
            // 切在英文单词中间就退到最近的空格
            if take < buffer.count, buffer[take].isLetter, buffer[take - 1].isLetter,
               let space = buffer[0..<take].lastIndex(of: " "), space > 0 {
                take = space
            }
            let piece = String(buffer[0..<take]).trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { result.append(piece) }
            buffer.removeFirst(take)
            while buffer.first == " " { buffer.removeFirst() }
        }
        if !buffer.isEmpty {
            let tail = String(buffer).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { result.append(tail) }
        }
        return result
    }

    // MARK: 后处理

    /// 太短的条并到相邻条，避免一两个字单独成行。
    /// 合并后的长度要贴着上限，不能为了合并又撑出一大条。
    static func mergeShort(_ lines: [String], options: Options) -> [String] {
        var result = lines
        let softLimit = options.maxLength * 1.05
        var index = 0
        while index < result.count, result.count > 1 {
            if visualLength(result[index]) < options.minLength {
                if index + 1 < result.count,
                   visualLength(result[index] + result[index + 1]) <= softLimit {
                    result[index] += result[index + 1]
                    result.remove(at: index + 1)
                    continue
                }
                if index > 0,
                   visualLength(result[index - 1] + result[index]) <= softLimit {
                    result[index - 1] += result[index]
                    result.remove(at: index)
                    continue
                }
            }
            index += 1
        }
        return result
    }

    /// 避头尾：标点不能出现在行首，开引号 / 开括号不能留在行尾
    static func fixLineEdges(_ lines: [String]) -> [String] {
        guard lines.count > 1 else { return lines }
        var result = lines
        for index in 1..<result.count {
            while let first = result[index].first, noLineStart.contains(first) {
                result[index - 1].append(first)
                result[index].removeFirst()
            }
            while let last = result[index - 1].last, noLineEnd.contains(last),
                  !result[index].isEmpty {
                result[index].insert(last, at: result[index].startIndex)
                result[index - 1].removeLast()
            }
        }
        return result.filter { !$0.isEmpty }
    }
}

// MARK: - 时间轴对齐

enum SubtitleAligner {

    struct Options {
        /// 单条最短显示时长
        var minDuration: Double = 0.6
        /// 单条最长显示时长，超过就截断（长句靠多条表达）
        var maxDuration: Double = 8
        /// 相邻两条之间的空隙小于这个值就补上，避免字幕闪一下
        var gapBridge: Double = 0.3
        /// 整体时间偏移，用户微调用
        var offset: Double = 0

        static let `default` = Options()
    }

    /// 把断好的句子铺到语音区间上
    static func align(lines: [String],
                      analysis: SpeechAnalysis,
                      options: Options = .default) -> [SubtitleEntry] {
        guard !lines.isEmpty else { return [] }
        let duration = max(analysis.duration, 0.1)
        let speech = analysis.speech.filter { $0.upperBound - $0.lowerBound > 0.02 }

        var entries: [SubtitleEntry]
        if speech.isEmpty {
            // 分析不出语音（纯音乐 / 解析失败）：按时长均分，至少给个可调的初稿
            entries = evenSplit(lines, duration: duration, options: options)
        } else if speech.count == lines.count {
            // 一句一停是最理想的情况，直接一一对应
            entries = oneToOne(lines, speech: speech, options: options)
        } else {
            // 句数和语音段数不一致：按发音权重铺在「压缩后的语音时间轴」上
            entries = proportional(lines, speech: speech, options: options)
        }

        bridgeGaps(&entries, options: options)
        normalize(&entries, duration: duration, options: options)
        return entries
    }

    // MARK: 三种铺法

    private static func oneToOne(_ lines: [String],
                                 speech: [ClosedRange<Double>],
                                 options: Options) -> [SubtitleEntry] {
        lines.enumerated().map { index, text in
            let range = speech[index]
            let start = range.lowerBound
            let end = min(range.upperBound, start + options.maxDuration)
            return SubtitleEntry(index: index + 1, startTime: start, endTime: end, text: text)
        }
    }

    private static func proportional(_ lines: [String],
                                     speech: [ClosedRange<Double>],
                                     options: Options) -> [SubtitleEntry] {
        let totalSpeech = speech.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        guard totalSpeech > 0 else {
            return evenSplit(lines, duration: max(speech.last?.upperBound ?? 1, 0.1), options: options)
        }
        let weights = lines.map { SubtitleBreaker.weight($0) }
        let totalWeight = weights.reduce(0, +)

        var entries: [SubtitleEntry] = []
        var cursor = 0.0
        for (index, text) in lines.enumerated() {
            let from = cursor / totalWeight * totalSpeech
            cursor += weights[index]
            let to = cursor / totalWeight * totalSpeech
            let start = realTime(from, in: speech)
            let end = realTime(to, in: speech)
            entries.append(SubtitleEntry(index: index + 1,
                                         startTime: start,
                                         endTime: max(end, start + 0.05),
                                         text: text))
        }
        return entries
    }

    private static func evenSplit(_ lines: [String],
                                  duration: Double,
                                  options: Options) -> [SubtitleEntry] {
        let step = duration / Double(lines.count)
        return lines.enumerated().map { index, text in
            let start = Double(index) * step
            let end = min(start + min(step, options.maxDuration), duration)
            return SubtitleEntry(index: index + 1, startTime: start, endTime: end, text: text)
        }
    }

    // MARK: 压缩轴 → 真实时间

    /// x 是「把所有语音区间首尾相接」后的坐标，映射回真实时间
    static func realTime(_ x: Double, in speech: [ClosedRange<Double>]) -> Double {
        guard let last = speech.last else { return 0 }
        var accumulated = 0.0
        for range in speech {
            let length = range.upperBound - range.lowerBound
            if x <= accumulated + length {
                return range.lowerBound + (x - accumulated)
            }
            accumulated += length
        }
        return last.upperBound
    }

    // MARK: 后处理

    /// 相邻字幕之间的小空隙补上，避免在停顿处闪一下
    private static func bridgeGaps(_ entries: inout [SubtitleEntry], options: Options) {
        guard entries.count > 1 else { return }
        for index in 0..<(entries.count - 1) {
            let gap = entries[index + 1].startTime - entries[index].endTime
            if gap > 0, gap <= options.gapBridge {
                entries[index].endTime = entries[index + 1].startTime
            }
        }
    }

    /// 保证：起始递增、不重叠、时长落在 [minDuration, maxDuration]、不超出总时长
    private static func normalize(_ entries: inout [SubtitleEntry],
                                  duration: Double,
                                  options: Options) {
        for index in entries.indices {
            var start = entries[index].startTime + options.offset
            var end = entries[index].endTime + options.offset

            if index > 0 {
                start = max(start, entries[index - 1].endTime)
            }
            start = max(0, start)
            end = max(end, start + options.minDuration)
            end = min(end, start + options.maxDuration)
            if index + 1 < entries.count {
                // 给下一条留出位置，实在挤不下就允许略短
                end = min(end, max(entries[index + 1].startTime + options.offset, start + 0.01))
            }
            entries[index].startTime = min(start, duration)
            entries[index].endTime = min(max(end, entries[index].startTime + 0.01), duration)
        }
    }

    /// 给「对齐结果」做个体检，界面上直接告诉用户靠不靠谱
    struct Report {
        var count = 0
        var totalSpeech = 0.0
        var coveredRatio = 0.0
        var averageDuration = 0.0
        var oneToOne = false
        var warnings: [String] = []
    }

    static func report(lines: [String],
                       entries: [SubtitleEntry],
                       analysis: SpeechAnalysis) -> Report {
        var report = Report()
        report.count = entries.count
        report.totalSpeech = analysis.speechDuration
        report.oneToOne = !analysis.speech.isEmpty && analysis.speech.count == lines.count
        guard !entries.isEmpty else { return report }

        let covered = entries.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
        report.coveredRatio = analysis.duration > 0 ? min(1, covered / analysis.duration) : 0
        report.averageDuration = covered / Double(entries.count)

        if analysis.speech.isEmpty {
            report.warnings.append("没检测到语音段，时间轴是按总时长均分的，需要手动调")
        }
        if !analysis.speech.isEmpty, analysis.speech.count != lines.count {
            report.warnings.append("语音有 \(analysis.speech.count) 段、文稿有 \(lines.count) 条，按字数比例分配，可能有偏差")
        }
        if report.averageDuration < 0.8 {
            report.warnings.append("平均每条不到 0.8 秒，可能断得太碎")
        }
        if report.averageDuration > 5 {
            report.warnings.append("平均每条超过 5 秒，可能断得太长")
        }
        return report
    }
}
