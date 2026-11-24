//
//  DataModels.swift
//  AI Video Assistant
//

import Foundation
import AppKit
import AVFoundation
import Combine

// MARK: - 视频项目

struct VideoProject: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var settings: ExportSettings

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.settings = ExportSettings()
    }
}

// MARK: - 导出设置

struct ExportSettings: Codable, Hashable {
    var resolution: ExportResolution = .r1080p
    var fps: Int = 30
    var format: ExportFormat = .mp4
    var quality: ExportQuality = .high
}

enum ExportResolution: String, Codable, CaseIterable, Hashable {
    case r720p = "720p"
    case r1080p = "1080p"
    case r1440p = "1440p"
    case r4k = "4K"

    var size: CGSize {
        switch self {
        case .r720p: return CGSize(width: 1280, height: 720)
        case .r1080p: return CGSize(width: 1920, height: 1080)
        case .r1440p: return CGSize(width: 2560, height: 1440)
        case .r4k: return CGSize(width: 3840, height: 2160)
        }
    }

    var label: String {
        switch self {
        case .r720p: return "1280×720"
        case .r1080p: return "1920×1080"
        case .r1440p: return "2560×1440"
        case .r4k: return "3840×2160"
        }
    }
}

enum ExportFormat: String, Codable, CaseIterable, Hashable {
    case mp4 = "MP4"
    case mov = "MOV"

    var fileExtension: String { self == .mp4 ? "mp4" : "mov" }
    var avFileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

enum ExportQuality: String, Codable, CaseIterable, Hashable {
    case medium = "中等"
    case high = "高"
    case best = "最佳"

    var preset: String {
        switch self {
        case .medium: return AVAssetExportPresetMediumQuality
        case .high: return AVAssetExportPresetHighestQuality
        case .best: return AVAssetExportPreset1920x1080
        }
    }
}

// MARK: - 媒体资产

enum MediaType: String, Codable {
    case video, audio, image

    static func detect(from url: URL) -> MediaType {
        switch url.pathExtension.lowercased() {
        case "mp3", "wav", "aac", "m4a", "flac", "ogg", "wma":
            return .audio
        case "jpg", "jpeg", "png", "gif", "bmp", "webp", "tiff", "heic":
            return .image
        default:
            return .video
        }
    }

    var icon: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        }
    }
}

final class MediaAsset: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let type: MediaType

    @Published var name: String
    @Published var duration: Double = 0
    @Published var resolution: CGSize = .zero
    @Published var thumbnail: NSImage?
    @Published var isLoading = false

    init(url: URL) {
        self.url = url
        self.type = MediaType.detect(from: url)
        self.name = url.lastPathComponent
    }

    var durationText: String {
        guard duration > 0 else { return "--:--" }
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%02d:%02d", m, s)
    }

    func loadMetadata() async {
        await MainActor.run { self.isLoading = true }
        let asset = AVURLAsset(url: url)

        var loadedDuration: Double = 0
        var loadedSize: CGSize = .zero

        if let d = try? await asset.load(.duration) {
            loadedDuration = CMTimeGetSeconds(d)
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            loadedSize = size
        }

        var image: NSImage?
        if type != .audio {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 270)
            if let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }

        let dur = loadedDuration
        let size = loadedSize
        let box = ImageBox(image: image)
        await MainActor.run {
            self.duration = dur
            self.resolution = size
            self.thumbnail = box.image
            self.isLoading = false
        }
    }
}

/// 用于跨 actor 传递 NSImage 的轻量包装（NSImage 本身非 Sendable）
private struct ImageBox: @unchecked Sendable {
    let image: NSImage?
}

// MARK: - 时间线

enum TimelineItemType: String, Codable, CaseIterable {
    case video, audio, text, subtitle, aiGenerated

    var label: String {
        switch self {
        case .video: return "视频"
        case .audio: return "音频"
        case .text: return "文字"
        case .subtitle: return "字幕"
        case .aiGenerated: return "AI 生成"
        }
    }

    var icon: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        case .text: return "textformat"
        case .subtitle: return "captions.bubble"
        case .aiGenerated: return "sparkles"
        }
    }
}

/// 时间线轨道分类（决定片段落在哪条轨道上）
enum TimelineTrack: String, Codable, Hashable {
    case video, audio, subtitle
}

/// 转场类型：作用于片段入点，与前一个片段做过渡
enum TransitionType: String, Codable, CaseIterable, Hashable {
    case none
    case crossDissolve
    case fadeThroughBlack
    case slideLeft
    case zoomIn

    var label: String {
        switch self {
        case .none: return "无"
        case .crossDissolve: return "交叉溶解"
        case .fadeThroughBlack: return "黑场过渡"
        case .slideLeft: return "左滑推入"
        case .zoomIn: return "缩放推入"
        }
    }

    var icon: String {
        switch self {
        case .none: return "minus"
        case .crossDissolve: return "circle.lefthalf.filled"
        case .fadeThroughBlack: return "moon.fill"
        case .slideLeft: return "arrow.left.square"
        case .zoomIn: return "plus.magnifyingglass"
        }
    }
}

/// 一个关键帧：时间相对片段起点（秒），值为该属性的取值
struct Keyframe: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var time: Double
    var value: Double

    init(time: Double, value: Double) {
        self.time = max(0, time)
        self.value = value
    }
}

/// 支持关键帧动画的属性
enum AnimatableProperty: String, Codable, CaseIterable, Identifiable {
    case scale, opacity, volume

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scale: return "缩放"
        case .opacity: return "不透明度"
        case .volume: return "音量"
        }
    }

    var unit: String {
        switch self {
        case .scale: return "×"
        case .opacity: return ""
        case .volume: return "×"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .scale: return 0.2...3.0
        case .opacity: return 0...1
        case .volume: return 0...2
        }
    }

    /// 该属性在片段属性里的静态取值（没有关键帧时用它）
    func staticValue(_ p: ItemProperties) -> Double {
        switch self {
        case .scale: return p.scale
        case .opacity: return p.opacity
        case .volume: return p.volume
        }
    }
}

struct ItemProperties: Codable, Hashable {
    var scale: Double = 1.0
    var rotation: Double = 0
    var opacity: Double = 1.0
    var volume: Double = 1.0
    var speed: Double = 1.0
    var fadeIn: Double = 0.5
    var fadeOut: Double = 0.5
    var textContent: String = ""
    var fontSize: Int = 28

    // MARK: 字幕 / 文字样式（按 1080p 画布为基准，渲染时按比例缩放）
    /// 文字颜色 0xRRGGBB
    var textColorHex: Int = 0xFFFFFF
    /// 文字底衬不透明度，0 表示无底衬
    var textBoxOpacity: Double = 0.42
    /// 文字距画面底部的比例（0 贴底，1 顶部）
    var textOffsetY: Double = 0.12
    var textBold: Bool = true

    /// 关键帧：key = AnimatableProperty.rawValue，时间相对片段起点
    var keyframes: [String: [Keyframe]] = [:]

    init() {}

    // 手写解码：新增字段在旧存档里缺失时回落到默认值
    enum CodingKeys: String, CodingKey {
        case scale, rotation, opacity, volume, speed, fadeIn, fadeOut
        case textContent, fontSize
        case textColorHex, textBoxOpacity, textOffsetY, textBold
        case keyframes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0.5
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0.5
        textContent = try c.decodeIfPresent(String.self, forKey: .textContent) ?? ""
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? 28
        textColorHex = try c.decodeIfPresent(Int.self, forKey: .textColorHex) ?? 0xFFFFFF
        textBoxOpacity = try c.decodeIfPresent(Double.self, forKey: .textBoxOpacity) ?? 0.42
        textOffsetY = try c.decodeIfPresent(Double.self, forKey: .textOffsetY) ?? 0.12
        textBold = try c.decodeIfPresent(Bool.self, forKey: .textBold) ?? true
        keyframes = try c.decodeIfPresent([String: [Keyframe]].self, forKey: .keyframes) ?? [:]
    }

    // MARK: 关键帧

    func keyframes(for property: AnimatableProperty) -> [Keyframe] {
        (keyframes[property.rawValue] ?? []).sorted { $0.time < $1.time }
    }

    mutating func setKeyframes(_ list: [Keyframe], for property: AnimatableProperty) {
        if list.isEmpty {
            keyframes[property.rawValue] = nil
        } else {
            keyframes[property.rawValue] = list.sorted { $0.time < $1.time }
        }
    }

    var hasAnyKeyframes: Bool {
        keyframes.values.contains { !$0.isEmpty }
    }

    /// 采样：没有关键帧时返回静态值；有则按时间线性插值（两端保持端点值）
    func animatedValue(_ property: AnimatableProperty, at time: Double) -> Double {
        let list = keyframes(for: property)
        guard let first = list.first, let last = list.last else {
            return property.staticValue(self)
        }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        for index in 1..<list.count {
            let a = list[index - 1]
            let b = list[index]
            if time >= a.time && time <= b.time {
                let span = b.time - a.time
                guard span > 0.0001 else { return b.value }
                let ratio = (time - a.time) / span
                return a.value + (b.value - a.value) * ratio
            }
        }
        return last.value
    }

    /// 生成渲染用的采样点：片段起点、每个关键帧、片段终点（去重后按时间排序）
    /// - Returns: [(相对片段时间, 值)]
    func animationSamples(_ property: AnimatableProperty, duration: Double) -> [(time: Double, value: Double)] {
        let list = keyframes(for: property).filter { $0.time <= duration + 0.001 }
        guard !list.isEmpty else { return [] }
        var points: [(time: Double, value: Double)] = [(0, animatedValue(property, at: 0))]
        for frame in list where frame.time > 0.001 && frame.time < duration - 0.001 {
            points.append((frame.time, frame.value))
        }
        points.append((duration, animatedValue(property, at: duration)))
        return points
    }
}

struct TimelineItem: Identifiable, Hashable, Codable {
    var id: UUID
    var assetID: UUID?
    var type: TimelineItemType
    var name: String
    var startTime: Double
    var duration: Double
    /// 素材内的入点（裁剪左边界时递增）
    var sourceStart: Double
    /// 入点转场
    var transition: TransitionType
    var transitionDuration: Double
    /// 同类轨道内的层号（音频 A1 / A2 …），0 为第一层
    var trackLane: Int
    var properties: ItemProperties
    var assetURL: URL?

    init(type: TimelineItemType,
         name: String,
         startTime: Double,
         duration: Double,
         assetID: UUID? = nil,
         assetURL: URL? = nil) {
        self.id = UUID()
        self.type = type
        self.name = name
        self.startTime = startTime
        self.duration = duration
        self.assetID = assetID
        self.assetURL = assetURL
        self.sourceStart = 0
        self.transition = .none
        self.transitionDuration = 0.6
        self.trackLane = 0
        self.properties = ItemProperties()
    }

    var endTime: Double { startTime + duration }

    var trackKind: TimelineTrack {
        switch type {
        case .video, .aiGenerated: return .video
        case .audio: return .audio
        case .subtitle, .text: return .subtitle
        }
    }

    /// 该类型轨道最多支持几层
    static func laneCount(for kind: TimelineTrack) -> Int {
        switch kind {
        case .video: return 1
        case .audio: return 2
        case .subtitle: return 1
        }
    }

    // MARK: Codable（对旧版本文件保持容错）

    enum CodingKeys: String, CodingKey {
        case id, assetID, type, name, startTime, duration
        case sourceStart, transition, transitionDuration, trackLane, properties, assetURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        assetID = try c.decodeIfPresent(UUID.self, forKey: .assetID)
        type = try c.decode(TimelineItemType.self, forKey: .type)
        name = try c.decode(String.self, forKey: .name)
        startTime = try c.decode(Double.self, forKey: .startTime)
        duration = try c.decode(Double.self, forKey: .duration)
        sourceStart = try c.decodeIfPresent(Double.self, forKey: .sourceStart) ?? 0
        transition = try c.decodeIfPresent(TransitionType.self, forKey: .transition) ?? .none
        transitionDuration = try c.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? 0.6
        trackLane = try c.decodeIfPresent(Int.self, forKey: .trackLane) ?? 0
        properties = try c.decodeIfPresent(ItemProperties.self, forKey: .properties) ?? ItemProperties()
        assetURL = try c.decodeIfPresent(URL.self, forKey: .assetURL)
    }
}

// MARK: - AI 配置

struct AIConfig: Codable, Hashable {
    var openAIKey: String = ""
    var openAIBaseURL: String = "https://api.openai.com/v1"
    var imageModel: String = "dall-e-3"
    var whisperModel: String = "whisper-1"

    var ttsProvider: TTSProvider = .openAI
    var azureKey: String = ""
    var azureRegion: String = "eastasia"
    var xfyunAppID: String = ""
    var xfyunAPIKey: String = ""
    var xfyunAPISecret: String = ""
}

enum TTSProvider: String, Codable, CaseIterable, Hashable {
    case openAI = "OpenAI"
    case azure = "Azure"
    case xfyun = "讯飞"

    var summary: String {
        switch self {
        case .openAI: return "OpenAI TTS，简洁易用，音色自然"
        case .azure: return "微软 Azure，音色丰富，中英文优秀"
        case .xfyun: return "讯飞语音，中文效果好，支持情感语音"
        }
    }
}

// MARK: - 字幕

struct SubtitleEntry: Identifiable, Hashable {
    let id = UUID()
    var index: Int
    var startTime: Double
    var endTime: Double
    var text: String

    var timecode: String {
        SubtitleParser.formatSRTTime(startTime)
    }
}

enum SubtitleParser {
    static func parseSRT(_ srt: String) -> [SubtitleEntry] {
        var entries: [SubtitleEntry] = []
        let normalized = srt.replacingOccurrences(of: "\r\n", with: "\n")
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
            guard lines.count >= 2 else { continue }
            let index = Int(lines[0]) ?? entries.count + 1
            let times = lines[1].components(separatedBy: "-->")
            guard times.count == 2 else { continue }
            let start = parseTime(times[0])
            let end = parseTime(times[1])
            let text = lines.dropFirst(2).joined(separator: " ")
            guard !text.isEmpty else { continue }
            entries.append(SubtitleEntry(index: index, startTime: start, endTime: end, text: text))
        }
        return entries
    }

    static func toSRT(_ entries: [SubtitleEntry]) -> String {
        entries.enumerated().map { offset, entry in
            "\(offset + 1)\n\(formatSRTTime(entry.startTime)) --> \(formatSRTTime(entry.endTime))\n\(entry.text)\n"
        }.joined(separator: "\n")
    }

    static func parseTime(_ raw: String) -> Double {
        let cleaned = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.components(separatedBy: ":")
        guard parts.count == 3 else { return 0 }
        return (Double(parts[0]) ?? 0) * 3600
            + (Double(parts[1]) ?? 0) * 60
            + (Double(parts[2]) ?? 0)
    }

    static func formatSRTTime(_ time: Double) -> String {
        let h = Int(time) / 3600
        let m = Int(time) % 3600 / 60
        let s = Int(time) % 60
        let ms = Int((time - Double(Int(time))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}

// MARK: - 通用工具

/// 时间线排布计算（纯函数，便于单测）
enum TimelineLayout {
    /// 从期望位置开始，找一段不与已有片段重叠的起点。
    /// 冲突时把起点推到冲突片段的末尾，继续往后找。
    static func freeStart(existing: [TimelineItem], desired: Double, duration: Double) -> Double {
        guard duration > 0 else { return max(0, desired) }
        var start = max(0, desired)
        let sorted = existing.sorted { $0.startTime < $1.startTime }

        var moved = true
        var guardCount = 0
        while moved && guardCount < 200 {
            moved = false
            guardCount += 1
            for clip in sorted {
                let overlaps = start < clip.endTime - 0.001 && start + duration > clip.startTime + 0.001
                if overlaps {
                    start = clip.endTime
                    moved = true
                }
            }
        }
        return start
    }

    /// 两个时间区间是否重叠
    static func overlaps(_ aStart: Double, _ aEnd: Double, _ bStart: Double, _ bEnd: Double) -> Bool {
        aStart < bEnd - 0.001 && aEnd > bStart + 0.001
    }

    // MARK: 智能剪辑用到的纯函数

    /// 合并重叠 / 相邻的时间区间，并按起点排序
    static func mergeRanges(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        let sorted = ranges
            .map { max(0, $0.lowerBound)...max(0, $0.upperBound) }
            .filter { $0.upperBound - $0.lowerBound > 0.001 }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound + 0.001 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// 某时刻之前一共被删掉了多少秒
    static func removedBefore(_ time: Double, ranges: [ClosedRange<Double>]) -> Double {
        var total: Double = 0
        for range in ranges {
            if range.upperBound <= time {
                total += range.upperBound - range.lowerBound
            } else if range.lowerBound < time {
                total += time - range.lowerBound
            }
        }
        return total
    }

    /// 区间 [start, end) 减去要删掉的部分，返回保留下来的若干段
    static func subtract(_ start: Double, _ end: Double,
                         ranges: [ClosedRange<Double>]) -> [(start: Double, end: Double)] {
        guard end > start else { return [] }
        var kept: [(start: Double, end: Double)] = []
        var cursor = start
        for range in ranges where range.upperBound > start && range.lowerBound < end {
            if range.lowerBound > cursor {
                kept.append((cursor, min(end, range.lowerBound)))
            }
            cursor = max(cursor, range.upperBound)
            if cursor >= end { break }
        }
        if cursor < end { kept.append((cursor, end)) }
        return kept.filter { $0.end - $0.start > 0.05 }
    }

    /// 在若干时间点把片段切开（时间点须落在片段内部）
    static func split(_ item: TimelineItem, at times: [Double]) -> [TimelineItem] {
        let points = times
            .filter { $0 > item.startTime + 0.05 && $0 < item.endTime - 0.05 }
            .sorted()
        guard !points.isEmpty else { return [item] }

        let speed = max(0.1, item.properties.speed)
        var pieces: [TimelineItem] = []
        var cursor = item.startTime
        for point in points + [item.endTime] {
            guard point > cursor + 0.01 else { continue }
            var piece = item
            piece.id = UUID()
            piece.startTime = cursor
            piece.duration = point - cursor
            piece.sourceStart = item.sourceStart + (cursor - item.startTime) * speed
            piece.transition = .none
            pieces.append(piece)
            cursor = point
        }
        return pieces.isEmpty ? [item] : pieces
    }

    /// 波纹删除：删掉若干时间区间，并把后面的内容整体前移
    /// - 完全落在区间内的片段会被丢弃，被截断的片段会拆成多段
    static func rippleDelete(items: [TimelineItem], ranges: [ClosedRange<Double>]) -> [TimelineItem] {
        let cuts = mergeRanges(ranges)
        guard !cuts.isEmpty else { return items }

        var result: [TimelineItem] = []
        for item in items {
            let speed = max(0.1, item.properties.speed)
            let kept = subtract(item.startTime, item.endTime, ranges: cuts)
            guard !kept.isEmpty else { continue }

            if kept.count == 1,
               abs(kept[0].start - item.startTime) < 0.001,
               abs(kept[0].end - item.endTime) < 0.001 {
                // 完全没被切到，只需整体前移
                var moved = item
                moved.startTime = max(0, item.startTime - removedBefore(item.startTime, ranges: cuts))
                result.append(moved)
                continue
            }

            for part in kept {
                var piece = item
                piece.id = UUID()
                piece.startTime = max(0, part.start - removedBefore(part.start, ranges: cuts))
                piece.duration = part.end - part.start
                piece.sourceStart = item.sourceStart + (part.start - item.startTime) * speed
                piece.transition = .none
                result.append(piece)
            }
        }
        return result.sorted { $0.startTime < $1.startTime }
    }
}

func formatTimecode(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return String(format: "%02d:%02d", m, s)
}
