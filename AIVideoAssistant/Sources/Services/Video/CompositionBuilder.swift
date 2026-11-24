//
//  CompositionBuilder.swift
//  把时间线数据编译成可渲染的 AVFoundation 合成
//
//  设计要点：
//  - 视频片段交替落在 A/B 两条视频轨道上，转场时两条轨道同时有画面
//  - 转场取前一个片段的「尾部余量」：前片源素材还有余量时向后延展 t 秒，
//    后片从自己的入点正常开始，两段在 [后片入点, 后片入点 + t] 重叠
//  - 合成指令按时间顺序铺满整条时间线（空隙补黑场），否则导出会失败
//

import Foundation
import AVFoundation
import CoreGraphics

struct CompositionBuild {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition?
    let audioMix: AVAudioMix?
    let duration: Double
}

enum CompositionBuilder {

    // MARK: - 内部计划

    private struct ClipPlan {
        let item: TimelineItem
        let asset: AVURLAsset
        let videoTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let speed: Double
        let sourceIn: Double
        let sourceAvailable: Double
        let timelineDuration: Double
        var extraTail: Double = 0
        var inTransition: Double = 0
        var trackSlot: Int = 0
    }

    // MARK: - 构建

    static func build(items: [TimelineItem],
                      renderSize: CGSize,
                      fps: Int) async throws -> CompositionBuild {

        let videoItems = items
            .filter { ($0.type == .video || $0.type == .aiGenerated) && $0.assetURL != nil }
            .sorted { $0.startTime < $1.startTime }
        let audioItems = items
            .filter { $0.type == .audio && $0.assetURL != nil }
            .sorted { $0.startTime < $1.startTime }

        guard !videoItems.isEmpty || !audioItems.isEmpty else { throw VideoError.emptyTimeline }

        // 1. 读取素材元数据
        var plans: [ClipPlan] = []
        for item in videoItems {
            guard let url = item.assetURL else { continue }
            let asset = AVURLAsset(url: url)
            guard let vTrack = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration) else { continue }

            let assetDuration = CMTimeGetSeconds(duration)
            let naturalSize = (try? await vTrack.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
            let transform = (try? await vTrack.load(.preferredTransform)) ?? .identity
            let aTrack = try? await asset.loadTracks(withMediaType: .audio).first

            let speed = min(max(item.properties.speed, 0.1), 4.0)
            let sourceIn = max(0, item.sourceStart)
            let available = assetDuration - sourceIn
            guard available > 0.05 else { continue }

            let timelineDuration = min(item.duration, available / speed)
            guard timelineDuration > 0.05 else { continue }

            plans.append(ClipPlan(item: item,
                                  asset: asset,
                                  videoTrack: vTrack,
                                  audioTrack: aTrack,
                                  naturalSize: naturalSize,
                                  preferredTransform: transform,
                                  speed: speed,
                                  sourceIn: sourceIn,
                                  sourceAvailable: available,
                                  timelineDuration: timelineDuration))
        }

        // 2. 计算转场重叠量
        if plans.count > 1 {
            for i in 1..<plans.count {
                let cur = plans[i]
                let prevIndex = i - 1
                let prev = plans[prevIndex]
                guard cur.item.transition != .none else { continue }

                let contiguous = abs((prev.item.startTime + prev.timelineDuration) - cur.item.startTime) < 0.06
                guard contiguous else { continue }

                let consumedSource = prev.timelineDuration * prev.speed
                let extraSource = prev.sourceAvailable - consumedSource
                guard extraSource > 0.02 else { continue }

                var t = min(cur.item.transitionDuration,
                            cur.timelineDuration * 0.5,
                            prev.timelineDuration * 0.5)
                t = min(t, extraSource / prev.speed)
                t = min(t, 1.5)
                guard t >= 0.12 else { continue }

                plans[prevIndex].extraTail = t
                plans[i].inTransition = t
            }
        }

        // 3. 建轨道并插入
        let composition = AVMutableComposition()
        var videoTracks: [AVMutableCompositionTrack] = []
        for _ in 0..<2 {
            if let track = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) {
                videoTracks.append(track)
            }
        }
        var clipAudioTracks: [AVMutableCompositionTrack] = []
        var videoAudioTracks: [AVMutableCompositionTrack] = []
        var audioParams: [AVMutableAudioMixInputParameters] = []

        func params(for track: AVMutableCompositionTrack) -> AVMutableAudioMixInputParameters {
            if let existing = audioParams.first(where: { $0.trackID == track.trackID }) {
                return existing
            }
            let p = AVMutableAudioMixInputParameters(track: track)
            audioParams.append(p)
            return p
        }

        func audioTrack(from pool: inout [AVMutableCompositionTrack], slot: Int) -> AVMutableCompositionTrack? {
            while pool.count <= slot {
                guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) else { break }
                pool.append(track)
            }
            return slot < pool.count ? pool[slot] : nil
        }

        var endCursor: Double = 0

        for index in plans.indices {
            guard !videoTracks.isEmpty else { break }
            let slot = index % videoTracks.count
            plans[index].trackSlot = slot
            let track = videoTracks[slot]

            let plan = plans[index]
            let startSeconds = plan.item.startTime
            let start = CMTime(seconds: startSeconds, preferredTimescale: 600)
            let wantedSource = (plan.timelineDuration + plan.extraTail) * plan.speed
            let take = min(wantedSource, plan.sourceAvailable)
            guard take > 0.05 else { continue }

            let range = CMTimeRange(start: CMTime(seconds: plan.sourceIn, preferredTimescale: 600),
                                    duration: CMTime(seconds: take, preferredTimescale: 600))

            do {
                try track.insertTimeRange(range, of: plan.videoTrack, at: start)
                let insertedRange = CMTimeRange(start: start, duration: range.duration)
                let target = take / plan.speed
                if abs(target - take) > 0.01 {
                    track.scaleTimeRange(insertedRange, toDuration: CMTime(seconds: target, preferredTimescale: 600))
                }
            } catch {
                continue
            }

            let playDuration = min(take / plan.speed, plan.timelineDuration + plan.extraTail)
            endCursor = max(endCursor, startSeconds + playDuration)

            // 片段自带的音频
            if let sourceAudio = plan.audioTrack,
               let dest = audioTrack(from: &videoAudioTracks, slot: slot) {
                do {
                    try dest.insertTimeRange(range, of: sourceAudio, at: start)
                    let insertedRange = CMTimeRange(start: start, duration: range.duration)
                    if abs(playDuration - take) > 0.01 {
                        dest.scaleTimeRange(insertedRange,
                                            toDuration: CMTime(seconds: playDuration, preferredTimescale: 600))
                    }
                    applyVolume(params(for: dest),
                                volume: plan.item.properties.volume,
                                start: startSeconds,
                                end: startSeconds + playDuration,
                                fadeIn: plan.item.properties.fadeIn,
                                fadeOut: plan.item.properties.fadeOut)
                } catch {
                    // 音频插入失败不影响画面
                }
            }
        }

        // 4. 独立音频轨（配音 / 音乐）
        //    尊重用户指定的层号；同一层时间段冲突时顺延到下一层
        var laneRanges: [Int: [(Double, Double)]] = [:]

        func isFree(_ lane: Int, _ start: Double, _ end: Double) -> Bool {
            guard let ranges = laneRanges[lane] else { return true }
            return !ranges.contains { start < $0.1 - 0.01 && end > $0.0 + 0.01 }
        }

        for item in audioItems {
            guard let url = item.assetURL else { continue }
            let asset = AVURLAsset(url: url)
            guard let aTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration) else { continue }

            let assetDuration = CMTimeGetSeconds(duration)
            let sourceIn = max(0, item.sourceStart)
            let available = assetDuration - sourceIn
            guard available > 0.05 else { continue }

            let take = min(item.duration, available)
            let startSeconds = item.startTime
            let endSeconds = startSeconds + take

            var lane = max(0, item.trackLane)
            var guardCount = 0
            while !isFree(lane, startSeconds, endSeconds) && guardCount < 4 {
                lane += 1
                guardCount += 1
            }

            let start = CMTime(seconds: startSeconds, preferredTimescale: 600)
            let range = CMTimeRange(start: CMTime(seconds: sourceIn, preferredTimescale: 600),
                                    duration: CMTime(seconds: take, preferredTimescale: 600))

            guard let dest = audioTrack(from: &clipAudioTracks, slot: lane) else { continue }
            do {
                try dest.insertTimeRange(range, of: aTrack, at: start)
                laneRanges[lane, default: []].append((startSeconds, endSeconds))
                applyVolume(params(for: dest),
                            volume: item.properties.volume,
                            start: startSeconds,
                            end: endSeconds,
                            fadeIn: item.properties.fadeIn,
                            fadeOut: item.properties.fadeOut)
                endCursor = max(endCursor, endSeconds)
            } catch {
                continue
            }
        }

        let hasVideo = videoTracks.contains { !$0.segments.isEmpty }
        guard hasVideo || !clipAudioTracks.isEmpty else { throw VideoError.noVideoTrack }

        let videoComposition = hasVideo
            ? makeVideoComposition(plans: plans,
                                   videoTracks: videoTracks,
                                   renderSize: renderSize,
                                   fps: fps,
                                   totalDuration: endCursor)
            : nil


        let audioMix: AVAudioMix? = audioParams.isEmpty
            ? nil
            : {
                let mix = AVMutableAudioMix()
                mix.inputParameters = audioParams
                return mix
            }()

        return CompositionBuild(composition: composition,
                                videoComposition: videoComposition,
                                audioMix: audioMix,
                                duration: endCursor)
    }

    // MARK: - 音量

    private static func applyVolume(_ params: AVMutableAudioMixInputParameters,
                                    volume: Double,
                                    start: Double,
                                    end: Double,
                                    fadeIn: Double,
                                    fadeOut: Double) {
        let level = Float(min(max(volume, 0), 2))
        let full = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                               duration: CMTime(seconds: max(0.01, end - start), preferredTimescale: 600))
        params.setVolumeRamp(fromStartVolume: level, toEndVolume: level, timeRange: full)

        let inLength = min(max(0, fadeIn), (end - start) * 0.5)
        if inLength > 0.02 {
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: level,
                                 timeRange: CMTimeRange(start: full.start,
                                                        duration: CMTime(seconds: inLength, preferredTimescale: 600)))
        }
        let outLength = min(max(0, fadeOut), (end - start) * 0.5)
        if outLength > 0.02 {
            let outStart = end - outLength
            params.setVolumeRamp(fromStartVolume: level, toEndVolume: 0,
                                 timeRange: CMTimeRange(start: CMTime(seconds: outStart, preferredTimescale: 600),
                                                        duration: CMTime(seconds: outLength, preferredTimescale: 600)))
        }
    }

    // MARK: - 视频合成

    private static func makeVideoComposition(plans: [ClipPlan],
                                             videoTracks: [AVMutableCompositionTrack],
                                             renderSize: CGSize,
                                             fps: Int,
                                             totalDuration: Double) -> AVMutableVideoComposition {
        let vc = AVMutableVideoComposition()
        vc.renderSize = renderSize
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))

        var instructions: [AVVideoCompositionInstructionProtocol] = []
        var cursor: Double = 0

        for plan in plans {
            let start = plan.item.startTime
            let end = start + plan.timelineDuration
            guard plan.trackSlot < videoTracks.count else { continue }

            // 与上一段重叠（说明指令已经覆盖），跳过
            if start < cursor - 0.01 { continue }

            if start > cursor + 0.01 {
                instructions.append(blankInstruction(from: cursor, to: start))
            }

            let track = videoTracks[plan.trackSlot]
            let t = plan.inTransition
            if t > 0, let prev = plans.last(where: {
                abs(($0.item.startTime + $0.timelineDuration) - start) < 0.06 && $0.item.id != plan.item.id
            }), prev.trackSlot < videoTracks.count {
                let prevTrack = videoTracks[prev.trackSlot]
                instructions.append(transitionInstruction(prev: prev,
                                                          prevTrack: prevTrack,
                                                          cur: plan,
                                                          curTrack: track,
                                                          duration: t,
                                                          renderSize: renderSize))
                instructions.append(singleInstruction(plan: plan,
                                                      track: track,
                                                      from: start + t,
                                                      to: end,
                                                      renderSize: renderSize))
            } else {
                instructions.append(singleInstruction(plan: plan,
                                                      track: track,
                                                      from: start,
                                                      to: end,
                                                      renderSize: renderSize))
            }
            cursor = max(cursor, end)
        }

        if totalDuration > cursor + 0.01 {
            instructions.append(blankInstruction(from: cursor, to: totalDuration))
        }

        vc.instructions = instructions
        return vc
    }

    private static func blankInstruction(from: Double, to: Double) -> AVMutableVideoCompositionInstruction {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                            duration: CMTime(seconds: max(0.01, to - from), preferredTimescale: 600))
        instruction.layerInstructions = []
        return instruction
    }

    private static func singleInstruction(plan: ClipPlan,
                                          track: AVMutableCompositionTrack,
                                          from: Double,
                                          to: Double,
                                          renderSize: CGSize) -> AVMutableVideoCompositionInstruction {
        let instruction = AVMutableVideoCompositionInstruction()
        let range = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                duration: CMTime(seconds: max(0.01, to - from), preferredTimescale: 600))
        instruction.timeRange = range
        instruction.layerInstructions = [layerInstruction(plan: plan,
                                                          track: track,
                                                          renderSize: renderSize,
                                                          range: range)]
        return instruction
    }

    private static func layerInstruction(plan: ClipPlan,
                                         track: AVMutableCompositionTrack,
                                         renderSize: CGSize,
                                         range: CMTimeRange) -> AVMutableVideoCompositionLayerInstruction {
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let base = baseTransform(plan: plan, renderSize: renderSize)
        layer.setTransform(base, at: range.start)

        let start = CMTimeGetSeconds(range.start)
        let opacity = Float(min(max(plan.item.properties.opacity, 0), 1))
        layer.setOpacity(opacity, at: range.start)

        // 入场淡入（有转场时由转场指令接管）
        if plan.inTransition <= 0 {
            let fadeIn = min(plan.item.properties.fadeIn, plan.timelineDuration * 0.5)
            if fadeIn > 0.02 {
                layer.setOpacityRamp(fromStartOpacity: 0,
                                     toEndOpacity: opacity,
                                     timeRange: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                                            duration: CMTime(seconds: fadeIn, preferredTimescale: 600)))
            }
        }

        let fadeOut = min(plan.item.properties.fadeOut, plan.timelineDuration * 0.5)
        if fadeOut > 0.02 {
            let outStart = plan.item.startTime + plan.timelineDuration - fadeOut
            layer.setOpacityRamp(fromStartOpacity: opacity,
                                 toEndOpacity: 0,
                                 timeRange: CMTimeRange(start: CMTime(seconds: outStart, preferredTimescale: 600),
                                                        duration: CMTime(seconds: fadeOut, preferredTimescale: 600)))
        }
        return layer
    }

    private static func transitionInstruction(prev: ClipPlan,
                                              prevTrack: AVMutableCompositionTrack,
                                              cur: ClipPlan,
                                              curTrack: AVMutableCompositionTrack,
                                              duration: Double,
                                              renderSize: CGSize) -> AVMutableVideoCompositionInstruction {
        let instruction = AVMutableVideoCompositionInstruction()
        let startSeconds = cur.item.startTime
        let range = CMTimeRange(start: CMTime(seconds: startSeconds, preferredTimescale: 600),
                                duration: CMTime(seconds: duration, preferredTimescale: 600))
        instruction.timeRange = range

        let outLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: prevTrack)
        let inLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: curTrack)
        let outBase = baseTransform(plan: prev, renderSize: renderSize)
        let inBase = baseTransform(plan: cur, renderSize: renderSize)
        outLayer.setTransform(outBase, at: range.start)
        inLayer.setTransform(inBase, at: range.start)

        let outOpacity = Float(min(max(prev.item.properties.opacity, 0), 1))
        let inOpacity = Float(min(max(cur.item.properties.opacity, 0), 1))
        outLayer.setOpacity(outOpacity, at: range.start)
        inLayer.setOpacity(0, at: range.start)

        switch cur.item.transition {
        case .none:
            break

        case .crossDissolve:
            outLayer.setOpacityRamp(fromStartOpacity: outOpacity, toEndOpacity: 0, timeRange: range)
            inLayer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: inOpacity, timeRange: range)

        case .fadeThroughBlack:
            let half = duration / 2
            outLayer.setOpacityRamp(fromStartOpacity: outOpacity, toEndOpacity: 0,
                                    timeRange: CMTimeRange(start: range.start,
                                                           duration: CMTime(seconds: half, preferredTimescale: 600)))
            inLayer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: inOpacity,
                                   timeRange: CMTimeRange(start: CMTime(seconds: startSeconds + half, preferredTimescale: 600),
                                                          duration: CMTime(seconds: half, preferredTimescale: 600)))

        case .slideLeft:
            let dx = renderSize.width
            outLayer.setTransformRamp(fromStart: outBase,
                                      toEnd: outBase.translatedBy(x: -dx, y: 0),
                                      timeRange: range)
            inLayer.setTransformRamp(fromStart: inBase.translatedBy(x: dx, y: 0),
                                     toEnd: inBase,
                                     timeRange: range)
            inLayer.setOpacityRamp(fromStartOpacity: inOpacity, toEndOpacity: inOpacity, timeRange: range)

        case .zoomIn:
            let center = CGPoint(x: renderSize.width / 2, y: renderSize.height / 2)
            outLayer.setOpacityRamp(fromStartOpacity: outOpacity, toEndOpacity: 0, timeRange: range)
            inLayer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: inOpacity, timeRange: range)
            inLayer.setTransformRamp(fromStart: inBase.concatenating(scaleAbout(0.86, center: center)),
                                     toEnd: inBase,
                                     timeRange: range)
        }

        // 层顺序：前 → 后
        if cur.item.transition == .slideLeft {
            instruction.layerInstructions = [inLayer, outLayer]
        } else {
            instruction.layerInstructions = [outLayer, inLayer]
        }
        return instruction
    }

    // MARK: - 变换

    private static func baseTransform(plan: ClipPlan, renderSize: CGSize) -> CGAffineTransform {
        let raw = CGRect(origin: .zero, size: plan.naturalSize).applying(plan.preferredTransform)
        let width = abs(raw.width)
        let height = abs(raw.height)
        guard width > 1, height > 1 else { return .identity }

        let rect = CGRect(x: raw.minX, y: raw.minY, width: width, height: height)
        let fit = min(renderSize.width / width, renderSize.height / height)
        let userScale = max(0.01, plan.item.properties.scale)
        let scale = fit * userScale

        var transform = plan.preferredTransform
        transform = transform.concatenating(CGAffineTransform(translationX: -rect.midX, y: -rect.midY))
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))

        let angle = plan.item.properties.rotation * .pi / 180
        if abs(angle) > 0.0001 {
            transform = transform.concatenating(CGAffineTransform(rotationAngle: angle))
        }
        transform = transform.concatenating(CGAffineTransform(translationX: renderSize.width / 2,
                                                              y: renderSize.height / 2))
        return transform
    }

    private static func scaleAbout(_ scale: CGFloat, center: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -center.x, y: -center.y)
    }
}
