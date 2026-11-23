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
    let id: UUID
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
}

struct TimelineItem: Identifiable, Hashable {
    let id: UUID
    var assetID: UUID?
    var type: TimelineItemType
    var name: String
    var startTime: Double
    var duration: Double
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
        self.properties = ItemProperties()
    }

    var endTime: Double { startTime + duration }
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

func formatTimecode(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return String(format: "%02d:%02d", m, s)
}
