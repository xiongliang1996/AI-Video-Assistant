//
//  WhisperTranscript.swift
//  Whisper 识别结果：verbose_json（含词级时间戳）解析 + SRT 兜底
//
//  为什么不用 SRT：SRT 只有句级时间，一句 20 多字的口播烧到画面上就超出安全区，
//  想拆成两条只能按字数瞎猜时间。verbose_json 带 `words`（每个词的真实起止），
//  拆句之后每一条的时间都来自真实发音，不用估。
//

import Foundation

struct WhisperTranscript {
    struct Word: Equatable {
        var text: String
        var start: Double
        var end: Double

        var duration: Double { max(0, end - start) }
    }

    /// 整段文本
    var text: String = ""
    /// 句级段落（verbose_json 的 segments）
    var segments: [SubtitleEntry] = []
    /// 词级时间戳；服务端没给时为空
    var words: [Word] = []

    var isEmpty: Bool { segments.isEmpty && words.isEmpty }

    /// 解析服务端返回：先按 verbose_json 解，失败再当 SRT 处理
    static func parse(_ raw: String) -> WhisperTranscript {
        if let transcript = parseVerboseJSON(raw), !transcript.isEmpty {
            return transcript
        }
        var fallback = WhisperTranscript()
        fallback.segments = SubtitleParser.parseSRT(raw)
        fallback.text = fallback.segments.map(\.text).joined(separator: " ")
        return fallback
    }

    static func parseVerboseJSON(_ raw: String) -> WhisperTranscript? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else { return nil }

        var result = WhisperTranscript()
        result.text = (json["text"] as? String) ?? ""

        if let segments = json["segments"] as? [[String: Any]] {
            result.segments = segments.compactMap { item in
                guard let text = (item["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                let start = number(item["start"]) ?? 0
                let end = number(item["end"]) ?? start
                return SubtitleEntry(index: 0,
                                     startTime: max(0, start),
                                     endTime: max(max(0, start), end),
                                     text: text)
            }
        }

        if let words = json["words"] as? [[String: Any]] {
            result.words = words.compactMap { item in
                // 官方字段名是 word，个别兼容实现给 text
                guard let text = (item["word"] as? String) ?? (item["text"] as? String),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let start = number(item["start"]) ?? 0
                let end = number(item["end"]) ?? start
                return Word(text: text, start: max(0, start), end: max(max(0, start), end))
            }
        }
        return result
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
