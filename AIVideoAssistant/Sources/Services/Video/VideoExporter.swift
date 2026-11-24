//
//  VideoExporter.swift
//  导出管线：合成 -> 渲染 -> 落盘
//

import Foundation
import AVFoundation

final class VideoExporter {
    static let shared = VideoExporter()

    private init() {}

    func export(items: [TimelineItem],
                settings: ExportSettings,
                to outputURL: URL,
                progress: @escaping (Double, String) -> Void) async throws {

        guard !items.isEmpty else { throw VideoError.emptyTimeline }

        await MainActor.run { progress(0.05, "正在合成轨道…") }

        let build = try await CompositionBuilder.build(items: items,
                                                       renderSize: settings.resolution.size,
                                                       fps: settings.fps)

        await MainActor.run { progress(0.2, "准备渲染参数…") }

        try? FileManager.default.removeItem(at: outputURL)

        guard let session = AVAssetExportSession(asset: build.composition,
                                                 presetName: settings.quality.preset) else {
            throw VideoError.exportFailed("无法创建导出会话")
        }

        session.outputURL = outputURL
        session.outputFileType = settings.format.avFileType
        session.shouldOptimizeForNetworkUse = true
        if let videoComposition = build.videoComposition {
            session.videoComposition = videoComposition
        }
        if let audioMix = build.audioMix {
            session.audioMix = audioMix
        }

        // 进度轮询
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.25)
        timer.setEventHandler {
            let p = Double(session.progress)
            progress(0.25 + p * 0.7, "正在编码 \(Int(p * 100))%")
        }
        timer.resume()

        await session.export()

        timer.cancel()

        if session.status != .completed {
            throw VideoError.exportFailed(session.error?.localizedDescription ?? "未知错误")
        }

        await MainActor.run { progress(1.0, "导出完成") }
    }
}
