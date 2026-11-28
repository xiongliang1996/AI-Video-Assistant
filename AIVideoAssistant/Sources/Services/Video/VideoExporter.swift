//
//  VideoExporter.swift
//  导出管线：合成 -> 渲染 -> 落盘
//
//  两条路径：
//  1. 没有字幕/文字 → AVAssetExportSession 硬件编码，最快
//  2. 有字幕/文字 → AVAssetReader(视频合成输出) + AVAssetWriter 逐帧绘制文字
//     （AVVideoCompositionCoreAnimationTool 在 macOS 26 上输出白屏，已弃用）
//

import Foundation
import AVFoundation
import CoreGraphics

/// 取消回调是 @Sendable 的，AVAssetExportSession 本身没标 Sendable，
/// 用一层盒子明确告诉编译器「这里只在主线程之外读一次引用」
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

final class VideoExporter {
    static let shared = VideoExporter()

    private init() {}

    func export(items: [TimelineItem],
                settings: ExportSettings,
                to outputURL: URL,
                progress: @escaping (Double, String) -> Void) async throws {

        guard !items.isEmpty else { throw VideoError.emptyTimeline }

        await MainActor.run { progress(0.05, "正在合成轨道…") }

        let renderSize = settings.resolution.size
        var build = try await CompositionBuilder.build(items: items,
                                                       renderSize: renderSize,
                                                       fps: settings.fps,
                                                       fillMode: settings.fillMode)

        // 均衡 + 降噪 + 压缩 + 响度标准化：改的是合成里的音频轨，两条导出路径都吃这一刀
        var tempAudio: URL?
        if settings.loudness != .off || settings.denoise != .off
            || settings.equalizer.isActive || settings.compressor.isActive {
            let result = try await AudioMastering.mastered(build: build,
                                                           target: settings.loudness,
                                                           denoise: settings.denoise,
                                                           noiseSample: settings.noiseSample,
                                                           equalizer: settings.equalizer,
                                                           compressor: settings.compressor) { value, message in
                progress(0.05 + value * 0.6, message)
            }
            build = result.build
            tempAudio = result.tempURL
            if let report = result.report {
                if settings.loudness != .off {
                    AppLog.info(.export, "响度标准化 · \(report.summary)")
                }
                if let equalizer = report.equalizer {
                    AppLog.info(.export, "均衡 · \(equalizer.summary)")
                }
                if let denoise = report.denoise {
                    AppLog.info(.export, "降噪（\(denoise.level.label)）· \(denoise.summary)")
                }
                if let compressor = report.compressor {
                    AppLog.info(.export, "压缩 · \(compressor.summary)")
                }
            }
        }
        defer {
            if let tempAudio { try? FileManager.default.removeItem(at: tempAudio) }
        }

        let overlay = SubtitleFrameRenderer(items: items, renderSize: renderSize)

        try? FileManager.default.removeItem(at: outputURL)

        // 没有字幕，或没有画面可烧（纯音频时间线）时走硬件导出
        if overlay.isEmpty || build.videoComposition == nil {
            try await exportPlain(build: build,
                                  settings: settings,
                                  to: outputURL,
                                  progress: progress)
        } else {
            try await exportWithOverlay(build: build,
                                        overlay: overlay,
                                        settings: settings,
                                        to: outputURL,
                                        progress: progress)
        }

        await MainActor.run { progress(1.0, "导出完成") }
    }

    // MARK: - 路径一：无字幕，直接硬件编码

    private func exportPlain(build: CompositionBuild,
                             settings: ExportSettings,
                             to outputURL: URL,
                             progress: @escaping (Double, String) -> Void) async throws {

        await MainActor.run { progress(0.2, "准备渲染参数…") }

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

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.25)
        timer.setEventHandler {
            let p = Double(session.progress)
            let overall = 0.25 + p * 0.7
            progress(overall, "正在编码 \(Int(overall * 100))%")
        }
        timer.resume()

        // 取消时立刻让 AVAssetExportSession 停下，别等它跑完整条时间线
        let box = ExportSessionBox(session)
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
    }

    // MARK: - 路径二：逐帧绘制字幕

    private func exportWithOverlay(build: CompositionBuild,
                                   overlay: SubtitleFrameRenderer,
                                   settings: ExportSettings,
                                   to outputURL: URL,
                                   progress: @escaping (Double, String) -> Void) async throws {

        await MainActor.run { progress(0.15, "准备逐帧渲染…") }

        let renderSize = settings.resolution.size
        let totalDuration = max(0.1, build.duration)
        let composition = build.composition

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: composition)
        } catch {
            throw VideoError.exportFailed("无法读取合成结果：\(error.localizedDescription)")
        }
        reader.timeRange = CMTimeRange(start: .zero,
                                       duration: CMTime(seconds: totalDuration, preferredTimescale: 600))

        let videoTracks = composition.tracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw VideoError.noVideoTrack }

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(renderSize.width),
                kCVPixelBufferHeightKey as String: Int(renderSize.height)
            ]
        )
        videoOutput.videoComposition = build.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw VideoError.exportFailed("无法建立视频读取通道")
        }
        reader.add(videoOutput)

        let audioTracks = composition.tracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks,
                                                     audioSettings: [
                                                        AVFormatIDKey: kAudioFormatLinearPCM,
                                                        AVSampleRateKey: 44100.0,
                                                        AVNumberOfChannelsKey: 2,
                                                        AVLinearPCMBitDepthKey: 16,
                                                        AVLinearPCMIsFloatKey: false,
                                                        AVLinearPCMIsBigEndianKey: false,
                                                        AVLinearPCMIsNonInterleaved: false
                                                     ])
            output.audioMix = build.audioMix
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: settings.format.avFileType)
        } catch {
            throw VideoError.exportFailed("无法创建输出文件：\(error.localizedDescription)")
        }

        let bitrate = Self.bitrate(for: settings.quality, renderSize: renderSize, fps: settings.fps)
        let videoInput = AVAssetWriterInput(mediaType: .video,
                                            outputSettings: [
                                                AVVideoCodecKey: AVVideoCodecType.h264,
                                                AVVideoWidthKey: Int(renderSize.width),
                                                AVVideoHeightKey: Int(renderSize.height),
                                                AVVideoCompressionPropertiesKey: [
                                                    AVVideoAverageBitRateKey: bitrate,
                                                    AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,
                                                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                                                ]
                                            ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw VideoError.exportFailed("无法建立视频写入通道")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio,
                                           outputSettings: [
                                            AVFormatIDKey: kAudioFormatMPEG4AAC,
                                            AVSampleRateKey: 44100.0,
                                            AVNumberOfChannelsKey: 2,
                                            AVEncoderBitRateKey: 160_000
                                           ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading() else {
            throw VideoError.exportFailed(reader.error?.localizedDescription ?? "读取失败")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw VideoError.exportFailed(writer.error?.localizedDescription ?? "写入失败")
        }
        writer.startSession(atSourceTime: .zero)

        let totalSeconds = totalDuration

        do {
            try await pumpSamples(writer: writer,
                                  videoOutput: videoOutput,
                                  videoInput: videoInput,
                                  audioOutput: audioOutput,
                                  audioInput: audioInput,
                                  overlay: overlay,
                                  totalSeconds: totalSeconds,
                                  progress: progress)
        } catch {
            // 取消或出错都要把写了一半的文件清掉，避免留下坏片
            writer.cancelWriting()
            reader.cancelReading()
            try? FileManager.default.removeItem(at: outputURL)
            if Task.isCancelled { throw VideoError.cancelled }
            throw error
        }

        if Task.isCancelled {
            writer.cancelWriting()
            reader.cancelReading()
            try? FileManager.default.removeItem(at: outputURL)
            throw VideoError.cancelled
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw VideoError.exportFailed(reader.error?.localizedDescription ?? "读取失败")
        }

        await writer.finishWriting()

        if writer.status != .completed {
            throw VideoError.exportFailed(writer.error?.localizedDescription ?? "编码未完成")
        }
    }

    // MARK: 逐帧搬运（可取消）

    private func pumpSamples(writer: AVAssetWriter,
                             videoOutput: AVAssetReaderVideoCompositionOutput,
                             videoInput: AVAssetWriterInput,
                             audioOutput: AVAssetReaderAudioMixOutput?,
                             audioInput: AVAssetWriterInput?,
                             overlay: SubtitleFrameRenderer,
                             totalSeconds: Double,
                             progress: @escaping (Double, String) -> Void) async throws {

        try await withThrowingTaskGroup(of: Void.self) { (group: inout ThrowingTaskGroup<Void, Error>) in
            try Task.checkCancellation()
            group.addTask {
                while let sample = videoOutput.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    while !videoInput.isReadyForMoreMediaData {
                        if writer.status != .writing {
                            throw VideoError.exportFailed(writer.error?.localizedDescription ?? "写入中断")
                        }
                        try await Task.sleep(nanoseconds: 2_000_000)
                    }
                    if let buffer = CMSampleBufferGetImageBuffer(sample) {
                        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                        if time.isFinite {
                            overlay.draw(into: buffer, at: time)
                        }
                    }
                    if !videoInput.append(sample) {
                        throw VideoError.exportFailed(writer.error?.localizedDescription ?? "视频写入失败")
                    }
                    let done = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                    let ratio = totalSeconds > 0 ? min(1, max(0, done / totalSeconds)) : 0
                    let overall = 0.2 + ratio * 0.7
                    await MainActor.run {
                        progress(overall, "正在渲染 \(Int(overall * 100))%")
                    }
                }
                videoInput.markAsFinished()
            }

            if let audioOutput, let audioInput {
                group.addTask {
                    while let sample = audioOutput.copyNextSampleBuffer() {
                        try Task.checkCancellation()
                        while !audioInput.isReadyForMoreMediaData {
                            if writer.status != .writing {
                                throw VideoError.exportFailed(writer.error?.localizedDescription ?? "写入中断")
                            }
                            try await Task.sleep(nanoseconds: 2_000_000)
                        }
                        if !audioInput.append(sample) {
                            throw VideoError.exportFailed(writer.error?.localizedDescription ?? "音频写入失败")
                        }
                    }
                    audioInput.markAsFinished()
                }
            }
        }
    }

    // MARK: - 码率

    private static func bitrate(for quality: ExportQuality,
                                renderSize: CGSize,
                                fps: Int) -> Int {
        let pixels = max(1.0, renderSize.width * renderSize.height)
        let base: Double
        switch quality {
        case .medium: base = 6_000_000
        case .high: base = 12_000_000
        case .best: base = 22_000_000
        }
        let scale = pixels / (1920 * 1080)
        let fpsScale = max(0.6, min(2.0, Double(fps) / 30.0))
        return Int(base * scale * fpsScale)
    }
}
