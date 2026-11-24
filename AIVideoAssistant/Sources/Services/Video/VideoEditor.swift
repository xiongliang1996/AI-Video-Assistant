//
//  VideoEditor.swift
//  基于 AVFoundation 的视频编辑引擎
//

import Foundation
import AVFoundation

enum VideoError: LocalizedError {
    case noVideoTrack
    case noAudioTrack
    case emptyTimeline
    case compositionFailed
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "未找到视频轨道"
        case .noAudioTrack: return "未找到音频轨道"
        case .emptyTimeline: return "时间线为空，请先添加素材"
        case .compositionFailed: return "视频合成失败"
        case .exportFailed(let msg): return "导出失败：\(msg)"
        case .cancelled: return "导出已取消"
        }
    }
}

final class VideoEditor {
    static let shared = VideoEditor()

    private init() {}

    // MARK: - 按时间线构建合成

    func buildComposition(items: [TimelineItem]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()

        let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid)

        let ordered = items.sorted { $0.startTime < $1.startTime }
        guard !ordered.isEmpty else { throw VideoError.emptyTimeline }

        for item in ordered {
            guard let url = item.assetURL else { continue }
            let asset = AVURLAsset(url: url)
            let start = CMTime(seconds: item.startTime, preferredTimescale: 600)
            let range = CMTimeRange(start: .zero,
                                    duration: CMTime(seconds: item.duration, preferredTimescale: 600))

            if let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first,
               let videoTrack {
                try? videoTrack.insertTimeRange(range, of: sourceVideo, at: start)
            }

            if let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first,
               let audioTrack {
                try? audioTrack.insertTimeRange(range, of: sourceAudio, at: start)
            }
        }

        if composition.tracks(withMediaType: .video).isEmpty {
            throw VideoError.noVideoTrack
        }
        return composition
    }

    // MARK: - 裁剪

    func trim(url: URL, start: Double, duration: Double, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first else {
            throw VideoError.noVideoTrack
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoError.compositionFailed
        }

        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                duration: CMTime(seconds: duration, preferredTimescale: 600))
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)

        if let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
        }

        try await export(composition, to: outputURL, fileType: .mp4)
    }

    // MARK: - 拼接

    func merge(urls: [URL], to outputURL: URL) async throws {
        guard !urls.isEmpty else { throw VideoError.emptyTimeline }

        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero

        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)

            if let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first,
               let videoTrack {
                try? videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            }
            if let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first,
               let audioTrack {
                try? audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }

        try await export(composition, to: outputURL, fileType: .mp4)
    }

    // MARK: - 变速

    func changeSpeed(url: URL, speed: Double, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first else {
            throw VideoError.noVideoTrack
        }
        guard let originalDuration = try? await asset.load(.duration) else {
            throw VideoError.compositionFailed
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoError.compositionFailed
        }

        let range = CMTimeRange(start: .zero, duration: originalDuration)
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)

        let scaled = CMTimeMultiplyByFloat64(originalDuration, multiplier: 1.0 / max(0.1, speed))
        videoTrack.scaleTimeRange(range, toDuration: scaled)

        try await export(composition, to: outputURL, fileType: .mp4)
    }

    // MARK: - 提取音频

    func extractAudio(from videoURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        guard let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw VideoError.noAudioTrack
        }
        guard let duration = try? await asset.load(.duration) else {
            throw VideoError.compositionFailed
        }

        let composition = AVMutableComposition()
        guard let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoError.compositionFailed
        }
        try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                       of: sourceAudio, at: .zero)

        try await export(composition, to: outputURL, fileType: .m4a)
    }

    // MARK: - 导出

    private func export(_ composition: AVMutableComposition,
                        to outputURL: URL,
                        fileType: AVFileType,
                        preset: String = AVAssetExportPresetHighestQuality) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw VideoError.exportFailed("无法创建导出会话")
        }

        session.outputURL = outputURL
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true

        await session.export()

        if session.status != .completed {
            throw VideoError.exportFailed(session.error?.localizedDescription ?? "未知错误")
        }
    }
}
