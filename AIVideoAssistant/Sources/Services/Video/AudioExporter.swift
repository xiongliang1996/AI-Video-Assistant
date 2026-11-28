//
//  AudioExporter.swift
//  只导出音频（M4A）
//
//  播客 / 口播交付经常只要声音：视频那套逐帧烧字幕的路径完全用不上，
//  直接把合成的音轨交给 AVAssetExportSession 的 AppleM4A 预设就行。
//

import Foundation
import AVFoundation

private final class AudioSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

enum AudioExporter {
    /// - Parameter items: 时间线快照。视频片段自带的音轨也会被混进去
    /// - Parameter loudness: 响度标准化目标，只导出音频时同样生效
    static func export(items: [TimelineItem],
                       to outputURL: URL,
                       loudness: LoudnessTarget = .off,
                       progress: @escaping (Double, String) -> Void) async throws {
        guard !items.isEmpty else { throw VideoError.emptyTimeline }
        // 只有字幕 / 文字时先拦下来，别让它一路走到「时间线为空」那种误导性报错
        guard items.contains(where: { $0.type != .subtitle && $0.type != .text }) else {
            throw VideoError.noAudioTrack
        }

        await MainActor.run { progress(0.05, "正在合成音频…") }

        // 画面参数随便给：这一步只是为了让音轨的裁剪 / 变速 / 音量包络都算出来
        var build = try await CompositionBuilder.build(items: items,
                                                       renderSize: CGSize(width: 1280, height: 720),
                                                       fps: 30)

        var tempAudio: URL?
        if loudness != .off {
            let result = try await AudioMastering.mastered(build: build, target: loudness) { value, message in
                progress(0.05 + value * 0.5, message)
            }
            build = result.build
            tempAudio = result.tempURL
            if let report = result.report {
                AppLog.info(.export, "响度标准化 · \(report.summary)")
            }
        }
        defer {
            if let tempAudio { try? FileManager.default.removeItem(at: tempAudio) }
        }

        let tracks = (try? await build.composition.loadTracks(withMediaType: .audio)) ?? []
        guard !tracks.isEmpty else { throw VideoError.noAudioTrack }

        try? FileManager.default.removeItem(at: outputURL)

        guard let session = AVAssetExportSession(asset: build.composition,
                                                 presetName: AVAssetExportPresetAppleM4A) else {
            throw VideoError.exportFailed("系统不支持 M4A 导出")
        }
        session.outputURL = outputURL
        session.outputFileType = .m4a
        if let audioMix = build.audioMix {
            session.audioMix = audioMix
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.25)
        timer.setEventHandler {
            let overall = 0.15 + Double(session.progress) * 0.8
            progress(overall, "正在混音 \(Int(overall * 100))%")
        }
        timer.resume()

        let box = AudioSessionBox(session)
        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            box.session.cancelExport()
        }

        timer.cancel()

        if session.status == .cancelled || Task.isCancelled {
            try? FileManager.default.removeItem(at: outputURL)
            throw VideoError.cancelled
        }
        if session.status != .completed {
            throw VideoError.exportFailed(session.error?.localizedDescription ?? "未知错误")
        }

        await MainActor.run { progress(1.0, "导出完成") }
    }
}
