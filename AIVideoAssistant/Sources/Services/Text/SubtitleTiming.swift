//
//  SubtitleTiming.swift
//  字幕条的时间微调：整体平移 / 改起点 / 改结尾 / 边界夹取
//
//  全部纯函数，不碰 SwiftUI。所有改动都守三条硬规则：
//  1. 不早于 0，不越过总时长（总时长为 0 时视为不限）
//  2. 不压到前一条的结尾，也不盖住后一条的开头
//  3. 单条时长不短于 minDuration
//
//  规则 2 是「互斥」的前提：字幕一叠就是两行字糊在一起，比时间略偏更难看。
//

import Foundation

enum SubtitleTiming {

    /// 一条字幕的最短显示时长，再短就只是闪一下
    static let minDuration: Double = 0.1
    /// 微调按钮的步长
    static let step: Double = 0.1
    /// 拖动时每个点对应多少秒
    static let secondsPerPoint: Double = 0.02

    // MARK: - 基础量

    static func duration(_ entry: SubtitleEntry) -> Double {
        max(0, entry.endTime - entry.startTime)
    }

    /// 这一条可以活动的区间：前一条结尾 ~ 后一条开头（没有邻居就用 0 / 总时长）
    static func bounds(_ entries: [SubtitleEntry], at index: Int, total: Double) -> ClosedRange<Double> {
        guard entries.indices.contains(index) else { return 0...0 }
        let lower = index > 0 ? entries[index - 1].endTime : 0
        let upper: Double
        if index + 1 < entries.count {
            upper = entries[index + 1].startTime
        } else if total > 0 {
            upper = total
        } else {
            upper = .greatestFiniteMagnitude
        }
        return lower...max(lower, upper)
    }

    // MARK: - 三种改动

    /// 整体平移：起止一起动，时长不变
    static func shift(_ entries: [SubtitleEntry],
                      at index: Int,
                      by delta: Double,
                      total: Double) -> [SubtitleEntry] {
        guard entries.indices.contains(index), delta != 0, delta.isFinite else { return entries }
        let entry = entries[index]
        let length = duration(entry)
        guard length > 0 else { return entries }

        let room = bounds(entries, at: index, total: total)
        var upper = room.upperBound - length
        if total > 0 { upper = min(upper, max(0, total - length)) }
        if upper < room.lowerBound { upper = room.lowerBound }

        let start = min(max(entry.startTime + delta, room.lowerBound), upper)
        guard abs(start - entry.startTime) > 0.0005 else { return entries }

        var result = entries
        result[index].startTime = start
        result[index].endTime = start + length
        return result
    }

    /// 只动结尾（拉长 / 缩短），起点不变
    static func resizeEnd(_ entries: [SubtitleEntry],
                          at index: Int,
                          by delta: Double,
                          total: Double) -> [SubtitleEntry] {
        guard entries.indices.contains(index), delta != 0, delta.isFinite else { return entries }
        let entry = entries[index]
        let room = bounds(entries, at: index, total: total)
        var limit = room.upperBound
        if total > 0 { limit = min(limit, total) }

        let lower = entry.startTime + minDuration
        let end = min(max(entry.endTime + delta, lower), max(lower, limit))
        guard abs(end - entry.endTime) > 0.0005 else { return entries }

        var result = entries
        result[index].endTime = end
        return result
    }

    /// 只动起点（往后推 / 往前拉），结尾不变
    static func resizeStart(_ entries: [SubtitleEntry],
                            at index: Int,
                            by delta: Double,
                            total: Double) -> [SubtitleEntry] {
        guard entries.indices.contains(index), delta != 0, delta.isFinite else { return entries }
        let entry = entries[index]
        let room = bounds(entries, at: index, total: total)

        let upper = entry.endTime - minDuration
        let lower = min(room.lowerBound, upper)
        let start = min(max(entry.startTime + delta, lower), max(lower, upper))
        guard abs(start - entry.startTime) > 0.0005 else { return entries }

        var result = entries
        result[index].startTime = start
        return result
    }

    // MARK: - 拖拽

    /// 拖了多少点 → 多少秒，按 step 取整（避免出现 1.7300000000000002 这种时间码）
    static func delta(pixels: Double,
                      secondsPerPoint: Double = SubtitleTiming.secondsPerPoint,
                      step: Double = SubtitleTiming.step) -> Double {
        guard pixels.isFinite, secondsPerPoint > 0, step > 0 else { return 0 }
        return (pixels * secondsPerPoint / step).rounded() * step
    }

    // MARK: - 兜底

    /// 理顺顺序：不早于 0、不与前一条重叠、结尾不早于起点，且不越过总时长。
    /// 只往前推，不重新排序——顺序就是列表顺序，改顺序会让用户找不到刚才那条。
    static func sanitized(_ entries: [SubtitleEntry], total: Double) -> [SubtitleEntry] {
        var result = entries
        for index in result.indices {
            var start = max(0, result[index].startTime)
            if index > 0 { start = max(start, result[index - 1].endTime) }
            if total > 0 { start = min(start, max(0, total - 0.01)) }
            var end = max(result[index].endTime, start + 0.01)
            if total > 0 { end = min(end, max(start + 0.01, total)) }
            result[index].startTime = start
            result[index].endTime = end
        }
        return result
    }

    /// 把时间恢复成 baseline 里的样子（文本保持当前编辑结果），按 id 配对
    static func restoreTimes(_ entries: [SubtitleEntry],
                             from baseline: [SubtitleEntry]) -> [SubtitleEntry] {
        guard !baseline.isEmpty else { return entries }
        var byID: [UUID: SubtitleEntry] = [:]
        for entry in baseline { byID[entry.id] = entry }
        return entries.map { entry in
            guard let original = byID[entry.id] else { return entry }
            var copy = entry
            copy.startTime = original.startTime
            copy.endTime = original.endTime
            return copy
        }
    }

    /// 有没有被手动改过时间（用来决定「复原对齐」按钮是否可点）
    static func isModified(_ entries: [SubtitleEntry], from baseline: [SubtitleEntry]) -> Bool {
        guard !baseline.isEmpty, entries.count == baseline.count else { return !baseline.isEmpty }
        var byID: [UUID: SubtitleEntry] = [:]
        for entry in baseline { byID[entry.id] = entry }
        for entry in entries {
            guard let original = byID[entry.id] else { return true }
            if abs(original.startTime - entry.startTime) > 0.001 { return true }
            if abs(original.endTime - entry.endTime) > 0.001 { return true }
        }
        return false
    }

    // MARK: - 显示

    /// 紧凑时间码：00:01.5
    static func compact(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        let minutes = tenths / 600
        let secs = (tenths % 600) / 10
        return String(format: "%02d:%02d.%d", minutes, secs, tenths % 10)
    }

    /// 列表里一行显示：00:01.5 → 00:03.2
    static func label(_ entry: SubtitleEntry) -> String {
        "\(compact(entry.startTime)) → \(compact(entry.endTime))"
    }

    /// 前后还剩多少空隙，微调时心里有数：前 0.4s · 后 1.2s
    static func roomLabel(_ entries: [SubtitleEntry], at index: Int, total: Double) -> String {
        guard entries.indices.contains(index) else { return "" }
        let entry = entries[index]
        let before = index > 0
            ? max(0, entry.startTime - entries[index - 1].endTime)
            : max(0, entry.startTime)
        let after: Double
        if index + 1 < entries.count {
            after = max(0, entries[index + 1].startTime - entry.endTime)
        } else if total > 0 {
            after = max(0, total - entry.endTime)
        } else {
            return "前 \(compactShort(before)) · 后面不限"
        }
        return "前 \(compactShort(before)) · 后 \(compactShort(after))"
    }

    /// 只有零点几秒时用「0.4s」这种短写法，超过一分钟才带分钟
    static func compactShort(_ seconds: Double) -> String {
        let value = max(0, seconds)
        if value < 60 { return String(format: "%.1fs", value) }
        return compact(value)
    }
}
