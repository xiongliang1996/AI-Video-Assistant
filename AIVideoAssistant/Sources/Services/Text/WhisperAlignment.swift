//
//  WhisperAlignment.swift
//  Whisper 结果 → 字幕条
//
//  三件事，全部是纯函数，方便直接跑断言：
//  1. 词级时间戳 → 字幕条（整句 / 逐字两种粒度）
//  2. 没有词级时间戳时，把过长的句级段落重新断句，时间按发音权重分配
//  3. 文件内时间 → 时间线时间（片段被裁过 / 不在 0 秒）
//

import Foundation

enum WhisperAlignment {

    /// 分段粒度：整句（按标点 + 长度断）或逐字（一个词一条）
    enum Granularity {
        case sentence
        case word
    }

    struct Options {
        /// 单条最大视觉长度（约等于多少个汉字）
        var maxLength: Double = 18
        /// 到这个长度才值得在标点处断，太短断开会闪
        var softLength: Double = 6
        /// 单条最短显示时长
        var minDuration: Double = 0.1
        /// 单条最长显示时长
        var maxDuration: Double = 8

        static let `default` = Options()
    }

    // MARK: - 词级 → 字幕条

    static func cues(from words: [WhisperTranscript.Word],
                     granularity: Granularity,
                     options: Options = .default) -> [SubtitleEntry] {
        let usable = words.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usable.isEmpty else { return [] }

        let raw = granularity == .word
            ? wordCues(usable, options: options)
            : sentenceCues(usable, options: options)
        return normalize(raw, options: options)
    }

    /// 逐字：一个词一条。纯标点不单独成条，挂到上一条并把它结尾拉长。
    private static func wordCues(_ words: [WhisperTranscript.Word],
                                 options: Options) -> [SubtitleEntry] {
        var entries: [SubtitleEntry] = []
        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isPunctuationOnly(text), !entries.isEmpty {
                let last = entries.count - 1
                entries[last].text += text
                entries[last].endTime = max(entries[last].endTime, word.end)
                continue
            }
            entries.append(SubtitleEntry(index: entries.count + 1,
                                         startTime: word.start,
                                         endTime: max(word.end, word.start + options.minDuration),
                                         text: text))
        }
        return entries
    }

    /// 整句：攒词，放不下或碰到句末标点就收一条。
    /// 英文的词自带前导空格，拼的时候要原样接上，只在收尾时 trim。
    private static func sentenceCues(_ words: [WhisperTranscript.Word],
                                     options: Options) -> [SubtitleEntry] {
        var entries: [SubtitleEntry] = []
        var buffer = ""
        var start = 0.0
        var end = 0.0
        var hasContent = false

        func flush() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                entries.append(SubtitleEntry(index: entries.count + 1,
                                             startTime: start,
                                             endTime: max(end, start + options.minDuration),
                                             text: text))
            }
            buffer = ""
            hasContent = false
        }

        for word in words {
            let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if !hasContent {
                buffer = trimmed
                start = word.start
                end = word.end
                hasContent = true
            } else if SubtitleBreaker.visualLength((buffer + word.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)) > options.maxLength {
                // 放不下了：先把上一条收掉，本词另起一条
                flush()
                buffer = trimmed
                start = word.start
                end = word.end
                hasContent = true
            } else {
                buffer += word.text
                end = max(end, word.end)
            }

            if endsSentence(trimmed),
               SubtitleBreaker.visualLength(buffer.trimmingCharacters(in: .whitespacesAndNewlines)) >= options.softLength {
                flush()
            }
        }
        flush()
        return entries
    }

    // MARK: - 句级兜底：重新断句

    /// 没有词级时间戳时用：把过长的段落按视觉长度重新断句，
    /// 时间按发音权重在原区间里分配（比按字数平均准，英文单词权重更高）。
    static func refine(_ cues: [SubtitleEntry], options: Options = .default) -> [SubtitleEntry] {
        var result: [SubtitleEntry] = []
        let breakerOptions = SubtitleBreaker.Options(maxLength: options.maxLength,
                                                     minLength: options.softLength,
                                                     hardBreakOnNewline: true)

        for cue in cues.sorted(by: { $0.startTime < $1.startTime }) {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let span = max(0, cue.endTime - cue.startTime)
            let lines = SubtitleBreaker.breakText(text, options: breakerOptions)
            if lines.count <= 1 || span <= 0 {
                result.append(SubtitleEntry(index: 0,
                                            startTime: cue.startTime,
                                            endTime: max(cue.endTime, cue.startTime + options.minDuration),
                                            text: text))
                continue
            }
            result.append(contentsOf: distribute(lines, from: cue.startTime, span: span))
        }
        return normalize(result, options: options)
    }

    /// 按发音权重把 `[start, start + span]` 分给若干行
    static func distribute(_ lines: [String], from start: Double, span: Double) -> [SubtitleEntry] {
        let weights = lines.map { SubtitleBreaker.weight($0) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }

        var entries: [SubtitleEntry] = []
        var cursor = 0.0
        for (offset, line) in lines.enumerated() {
            let begin = start + span * (cursor / total)
            cursor += weights[offset]
            let finish = start + span * (cursor / total)
            entries.append(SubtitleEntry(index: offset + 1,
                                         startTime: begin,
                                         endTime: max(finish, begin + 0.01),
                                         text: line))
        }
        return entries
    }

    // MARK: - 文件时间 → 时间线时间

    /// 只保留片段窗口 `[sourceStart, sourceStart + duration)` 内的字幕，
    /// 再整体平移到片段在时间线上的位置。被裁掉的头部 / 尾部不该有字幕。
    static func remap(_ cues: [SubtitleEntry],
                      clipStart: Double,
                      sourceStart: Double,
                      duration: Double) -> [SubtitleEntry] {
        let length = max(0, duration)
        guard length > 0 else { return [] }
        let origin = max(0, sourceStart)
        let upper = origin + length
        let base = max(0, clipStart)

        var result: [SubtitleEntry] = []
        for cue in cues {
            let from = max(cue.startTime, origin)
            let to = min(cue.endTime, upper)
            guard to - from > 0.05 else { continue }
            result.append(SubtitleEntry(index: result.count + 1,
                                        startTime: base + (from - origin),
                                        endTime: base + (to - origin),
                                        text: cue.text))
        }
        return result
    }

    // MARK: - 后处理

    /// 排序 + 不重叠 + 时长夹取。
    /// 和上一条叠了就把上一条收在本条起点；起点几乎重合、腾不出空间的，
    /// 上一条直接丢掉——留着只会叠在一起，反而更难看。
    static func normalize(_ entries: [SubtitleEntry], options: Options = .default) -> [SubtitleEntry] {
        let sorted = entries.sorted { $0.startTime < $1.startTime }
        var result: [SubtitleEntry] = []

        for var entry in sorted {
            entry.startTime = max(0, entry.startTime)
            while let last = result.last, entry.startTime < last.endTime {
                if entry.startTime > last.startTime + 0.005 {
                    result[result.count - 1].endTime = entry.startTime
                } else {
                    result.removeLast()
                }
            }
            var end = max(entry.endTime, entry.startTime + options.minDuration)
            end = min(end, entry.startTime + options.maxDuration)
            if end - entry.startTime < 0.01 { end = entry.startTime + 0.01 }
            entry.endTime = end
            result.append(entry)
        }
        // 中间可能丢过条，序号统一重排
        for offset in result.indices { result[offset].index = offset + 1 }
        return result
    }

    // MARK: - 判定

    private static let sentenceEnders: Set<Character> = [
        "。", "！", "？", "!", "?", ".", "…", "；", ";", "，", ",", "、", "：", ":"
    ]

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return sentenceEnders.contains(last)
    }

    static func isPunctuationOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        for scalar in trimmed.unicodeScalars {
            let isPunctuation = CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
                || SubtitleBreaker.isCJK(scalar)
                    && CharacterSet(charactersIn: "，。、；：！？…—「」『』（）《》").contains(scalar)
            if !isPunctuation { return false }
        }
        return true
    }
}
