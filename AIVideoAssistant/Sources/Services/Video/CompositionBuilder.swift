//
//  CompositionBuilder.swift
//  把时间线数据编译成可渲染的 AVFoundation 合成
//
//  设计要点：
//  - 视频片段交替落在 A/B 两条视频轨道上，转场时两条轨道同时有画面
//  - 转场取前一个片段的「尾部余量」：前片源素材还有余量时向后延展 t 秒，
//    后片从自己的入点正常开始，两段在 [后片入点, 后片入点 + t] 重叠
//  - 合成指令按时间顺序铺满整条时间线（空隙补黑场），否则导出会失败
//  - 画中画（V2 层）单独占轨道，以「图层叠在指令最前面」的方式合成。
//    它的不透明度在自身区间外一律压到 0 —— AVFoundation 在 track 断流后
//    会把末帧一直 hold 到指令结束，不归零的话画中画会一路糊到片尾。
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
        /// 画幅填充方式（全局一致，放在计划里省得一路传参）
        var fillMode: ExportFillMode = .fit

        /// V2 层上的画中画
        var isOverlay: Bool { item.isOverlay }
    }

    // MARK: - 构建

    static func build(items: [TimelineItem],
                      renderSize: CGSize,
                      fps: Int,
                      fillMode: ExportFillMode = .fit) async throws -> CompositionBuild {

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
                                  timelineDuration: timelineDuration,
                                  fillMode: fillMode))
        }

        // 2. 拆层：V1 是主画面，V2 是画中画
        //    转场只在主画面层之间算 —— 画中画不做转场，它只是「浮在上面」，
        //    给它做交叉溶解没有视觉意义，还会把主画面的指令切碎。
        var mainPlans = plans.filter { !$0.isOverlay }
        let overlayPlans = plans.filter { $0.isOverlay }

        if mainPlans.count > 1 {
            for i in 1..<mainPlans.count {
                let cur = mainPlans[i]
                let prevIndex = i - 1
                let prev = mainPlans[prevIndex]
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

                mainPlans[prevIndex].extraTail = t
                mainPlans[i].inTransition = t
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

        /// 画中画轨道：V2 层同一时间只允许一段，但历史数据 / 多选操作也可能
        /// 造出重叠，所以按「空出来就用」的方式复用轨道，实在挤不下再新开一条。
        var overlayTracks: [AVMutableCompositionTrack] = []
        var overlayBusy: [[(Double, Double)]] = []

        func overlayTrack(for start: Double, end: Double) -> Int? {
            for (index, busy) in overlayBusy.enumerated() {
                let clash = busy.contains { start < $0.1 - 0.01 && end > $0.0 + 0.01 }
                if !clash { return index }
            }
            guard let track = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return nil }
            overlayTracks.append(track)
            overlayBusy.append([])
            return overlayTracks.count - 1
        }

        /// 把一段视频插进指定轨道（含变速），失败返回 false
        @discardableResult
        func insertVideo(_ plan: ClipPlan, into track: AVMutableCompositionTrack) -> Double? {
            let startSeconds = plan.item.startTime
            let start = cmt(startSeconds)
            let wantedSource = (plan.timelineDuration + plan.extraTail) * plan.speed
            let take = min(wantedSource, plan.sourceAvailable)
            guard take > 0.05 else { return nil }

            let range = CMTimeRange(start: cmt(plan.sourceIn), duration: cmt(take))
            do {
                try track.insertTimeRange(range, of: plan.videoTrack, at: start)
                let insertedRange = CMTimeRange(start: start, duration: range.duration)
                let target = take / plan.speed
                if abs(target - take) > 0.01 {
                    track.scaleTimeRange(insertedRange, toDuration: cmt(target))
                }
            } catch {
                return nil
            }

            let playDuration = min(take / plan.speed, plan.timelineDuration + plan.extraTail)

            // 片段自带的音频
            // 画中画的音频层号从 videoTracks.count 起算，免得和主画面的两条
            // 音轨撞在一起（撞上会让两条片段的声音互相截断）
            let audioSlot = plan.isOverlay ? videoTracks.count + plan.trackSlot : plan.trackSlot
            if let sourceAudio = plan.audioTrack,
               let dest = audioTrack(from: &videoAudioTracks, slot: audioSlot) {
                do {
                    try dest.insertTimeRange(range, of: sourceAudio, at: start)
                    let insertedRange = CMTimeRange(start: start, duration: range.duration)
                    if abs(playDuration - take) > 0.01 {
                        dest.scaleTimeRange(insertedRange, toDuration: cmt(playDuration))
                    }
                    applyVolume(params(for: dest),
                                properties: plan.item.properties,
                                start: startSeconds,
                                end: startSeconds + playDuration)
                } catch {
                    // 音频插入失败不影响画面
                }
            }
            return playDuration
        }

        // 主画面：A/B 交替，转场靠两条轨同时有画面
        if !videoTracks.isEmpty {
            for index in mainPlans.indices {
                let slot = index % videoTracks.count
                mainPlans[index].trackSlot = slot
                guard let played = insertVideo(mainPlans[index], into: videoTracks[slot]) else { continue }
                endCursor = max(endCursor, mainPlans[index].item.startTime + played)
            }
        }

        // 画中画：各自找一条不冲突的轨道
        var placedOverlays: [ClipPlan] = []
        for index in overlayPlans.indices {
            var plan = overlayPlans[index]
            let start = plan.item.startTime
            let end = start + plan.timelineDuration
            guard let slot = overlayTrack(for: start, end: end) else { continue }
            plan.trackSlot = slot
            guard let played = insertVideo(plan, into: overlayTracks[slot]) else { continue }
            overlayBusy[slot].append((start, end))
            endCursor = max(endCursor, start + played)
            placedOverlays.append(plan)
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

            let start = cmt(startSeconds)
            let range = CMTimeRange(start: cmt(sourceIn),
                                    duration: cmt(take))

            guard let dest = audioTrack(from: &clipAudioTracks, slot: lane) else { continue }
            do {
                try dest.insertTimeRange(range, of: aTrack, at: start)
                laneRanges[lane, default: []].append((startSeconds, endSeconds))
                applyVolume(params(for: dest),
                            properties: item.properties,
                            start: startSeconds,
                            end: endSeconds)
                endCursor = max(endCursor, endSeconds)
            } catch {
                continue
            }
        }

        let hasVideo = videoTracks.contains { !$0.segments.isEmpty }
            || overlayTracks.contains { !$0.segments.isEmpty }
        guard hasVideo || !clipAudioTracks.isEmpty else { throw VideoError.noVideoTrack }

        // 黑底轨：AVFoundation 的合成器不会清空未覆盖区域，
        // 时间线空隙和「适应」画幅的黑边会拿到未初始化内存，编出来是绿色（YUV 0,0,0）。
        // 垫一条铺满全片的黑色轨，留白才是真黑。
        //
        // 长度直接取「垫之前」的合成时长：这样底轨插进来不会把总时长撑长，
        // 也不会因为浮点取整比真正的结尾短一格，末帧掉回没底的黑洞。
        var backdropTrack: AVMutableCompositionTrack?
        if hasVideo {
            let realEnd = CMTimeGetSeconds(composition.duration)
            backdropTrack = makeBackdropTrack(in: composition,
                                              renderSize: renderSize,
                                              totalDuration: max(0.1, realEnd.isFinite ? realEnd : endCursor))
        }

        // 用合成自己的时长做指令终点，而不是浮点的 endCursor：
        // 两者差一个 tick 就会让指令铺不满整片，导出直接报 -11841
        let exactDuration = composition.duration

        let videoComposition = hasVideo
            ? makeVideoComposition(plans: mainPlans,
                                   videoTracks: videoTracks,
                                   overlays: placedOverlays,
                                   overlayTracks: overlayTracks,
                                   renderSize: renderSize,
                                   fps: fps,
                                   totalDuration: exactDuration > .zero ? exactDuration : cmt(endCursor),
                                   backdrop: backdropTrack)
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
                                    properties: ItemProperties,
                                    start: Double,
                                    end: Double) {
        let volume = properties.volume
        let fadeIn = properties.fadeIn
        let fadeOut = properties.fadeOut
        let level = Float(min(max(volume, 0), 2))

        // 有关键帧时用逐段 ramp 覆盖整段，淡入淡出交给关键帧表达
        let samples = properties.animationSamples(.volume, duration: end - start)
        if samples.count > 1 {
            for index in 1..<samples.count {
                let a = samples[index - 1]
                let b = samples[index]
                guard b.time - a.time > 0.001,
                      let ramp = timeRange(from: start + a.time, to: start + b.time) else { continue }
                params.setVolumeRamp(fromStartVolume: Float(min(max(a.value, 0), 2)),
                                     toEndVolume: Float(min(max(b.value, 0), 2)),
                                     timeRange: ramp)
            }
            return
        }
        guard let full = timeRange(from: start, to: end) else { return }
        params.setVolumeRamp(fromStartVolume: level, toEndVolume: level, timeRange: full)

        let inLength = min(max(0, fadeIn), (end - start) * 0.5)
        if inLength > 0.02, let ramp = timeRange(from: start, to: start + inLength) {
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: level, timeRange: ramp)
        }
        let outLength = min(max(0, fadeOut), (end - start) * 0.5)
        if outLength > 0.02, let ramp = timeRange(from: end - outLength, to: end) {
            params.setVolumeRamp(fromStartVolume: level, toEndVolume: 0, timeRange: ramp)
        }
    }

    // MARK: - 时间区间

    /// 时间线精度：1/600 秒。所有边界都落在这一格上。
    static let timescale: CMTimeScale = 600

    /// 秒 → CMTime，**四舍五入**到最近的 tick。
    ///
    /// 不能用 `CMTime(seconds:preferredTimescale:)`：它是截断的，
    /// 3.01 秒 × 600 = 1805.9999… 会被截成 1805，于是底轨、指令、合成时长
    /// 各差一格。指令没铺满整片，导出就报 -11841。
    static func cmt(_ seconds: Double) -> CMTime {
        let ticks = (seconds * Double(timescale)).rounded()
        return CMTime(value: CMTimeValue(ticks.isFinite ? ticks : 0), timescale: timescale)
    }

    /// 把两个「秒」边界转成一个 CMTimeRange，长度由两端相减得出。
    ///
    /// 为什么不能直接 `CMTime(seconds: to - from)`：起止各自取整一次、
    /// 长度再取整一次，三次独立取整会在相邻区间之间漏出或叠出 1 个 tick。
    /// 漏出 → 指令没铺满整片，导出报 -11841（The video could not be composed）；
    /// 叠出 → 同一图层两条 opacity ramp 相交，直接抛 NSInvalidArgumentException。
    /// 两端的 tick 都是确定的，长度用减法就严丝合缝。
    private static func timeRange(from: Double, to: Double) -> CMTimeRange? {
        let start = cmt(from)
        let end = cmt(to)
        guard end > start else { return nil }
        return CMTimeRange(start: start, duration: CMTimeSubtract(end, start))
    }

    // MARK: - 视频合成

    private static func makeVideoComposition(plans: [ClipPlan],
                                             videoTracks: [AVMutableCompositionTrack],
                                             overlays: [ClipPlan] = [],
                                             overlayTracks: [AVMutableCompositionTrack] = [],
                                             renderSize: CGSize,
                                             fps: Int,
                                             totalDuration: CMTime,
                                             backdrop: AVMutableCompositionTrack?) -> AVMutableVideoComposition {
        let vc = AVMutableVideoComposition()
        vc.renderSize = renderSize
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor: Double = 0

        /// 逐条铺砖：新指令必须从上一条的结尾开始，缝隙补黑场、重叠裁掉。
        /// AVFoundation 要求指令严格铺满整片且互不重叠，差一个 tick 就 -11841。
        func append(_ instruction: AVMutableVideoCompositionInstruction?) {
            guard var ins = instruction else { return }
            let start = ins.timeRange.start
            let end = ins.timeRange.end
            if let prevEnd = instructions.last?.timeRange.end {
                if start > prevEnd {
                    instructions.append(blank(from: prevEnd, to: start))
                } else if start < prevEnd {
                    guard end > prevEnd else { return }
                    ins.timeRange = CMTimeRange(start: prevEnd,
                                                duration: CMTimeSubtract(end, prevEnd))
                }
            } else if start > .zero {
                // 开头空出来的部分也要铺上，否则第一帧没指令
                instructions.append(blank(from: .zero, to: start))
            }
            guard ins.timeRange.duration > .zero else { return }
            instructions.append(ins)
        }

        for plan in plans {
            let start = plan.item.startTime
            let end = start + plan.timelineDuration
            guard plan.trackSlot < videoTracks.count else { continue }

            // 与上一段重叠（说明指令已经覆盖），跳过
            if start < cursor - 0.01 { continue }

            let track = videoTracks[plan.trackSlot]
            let t = plan.inTransition
            if t > 0, let prev = plans.last(where: {
                abs(($0.item.startTime + $0.timelineDuration) - start) < 0.06 && $0.item.id != plan.item.id
            }), prev.trackSlot < videoTracks.count {
                let prevTrack = videoTracks[prev.trackSlot]
                append(transitionInstruction(prev: prev,
                                             prevTrack: prevTrack,
                                             cur: plan,
                                             curTrack: track,
                                             duration: t,
                                             renderSize: renderSize))
                append(singleInstruction(plan: plan,
                                         track: track,
                                         from: start + t,
                                         to: end,
                                         renderSize: renderSize))
            } else {
                append(singleInstruction(plan: plan,
                                         track: track,
                                         from: start,
                                         to: end,
                                         renderSize: renderSize))
            }
            cursor = max(cursor, end)
        }

        // 一条主画面都没有（时间线上只放了画中画）时，上面一条指令都不会生成。
        // 合成器要求指令铺满整片，这里先补一条全黑底，画中画才有地方落脚，
        // 否则导出直接报 -11841。
        if instructions.isEmpty, totalDuration > .zero {
            instructions.append(blank(from: .zero, to: totalDuration))
        }

        // 收尾：尾巴补齐，越界的裁掉，保证终点正好等于合成时长
        if let lastEnd = instructions.last?.timeRange.end {
            if lastEnd < totalDuration {
                append(blank(from: lastEnd, to: totalDuration))
            } else if lastEnd > totalDuration, let last = instructions.last {
                let start = last.timeRange.start
                if totalDuration > start {
                    last.timeRange = CMTimeRange(start: start,
                                                 duration: CMTimeSubtract(totalDuration, start))
                } else {
                    instructions.removeLast()
                }
            }
        }

        // 画中画：叠在每条「与它区间相交」的指令最前面（layerInstructions 第一个是最前）
        //
        // 这里**不切指令**，而是让画中画图层的 opacity 在自身区间外归零。
        // 原因：AVFoundation 对「track 已经断流」的处理是把末帧一直 hold 到指令结束，
        // 单靠 track 边界隔离不住，画中画会一路糊到片尾。归零之后 hold 的是透明帧，
        // 视觉上干净，而主画面的指令、转场、关键帧全都不用改。
        if !overlays.isEmpty, !overlayTracks.isEmpty {
            for instruction in instructions {
                let lo = CMTimeGetSeconds(instruction.timeRange.start)
                let hi = CMTimeGetSeconds(instruction.timeRange.end)
                var overlayLayers: [AVMutableVideoCompositionLayerInstruction] = []
                for plan in overlays {
                    guard plan.trackSlot < overlayTracks.count else { continue }
                    let a = plan.item.startTime
                    let b = a + plan.timelineDuration
                    // 半开区间相交判定：刚好贴在边上的指令不算，避免多发一条空图层
                    guard b > lo + 0.0005, a < hi - 0.0005 else { continue }

                    let layer = AVMutableVideoCompositionLayerInstruction(
                        assetTrack: overlayTracks[plan.trackSlot])
                    applyOverlay(layer,
                                 plan: plan,
                                 renderSize: renderSize,
                                 clipTo: lo,
                                 hi: hi)
                    overlayLayers.append(layer)
                }
                guard !overlayLayers.isEmpty else { continue }
                instruction.layerInstructions = overlayLayers + instruction.layerInstructions
            }
        }

        // 黑底轨垫在每条指令的最底层（layerInstructions 第一个是最前面，所以追加在末尾）
        if let backdrop {
            for instruction in instructions {
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: backdrop)
                layer.setTransform(.identity, at: instruction.timeRange.start)
                instruction.layerInstructions = instruction.layerInstructions + [layer]
            }
        }

        // 画中画设了圆角 / 描边、或有片段调了色时换成自绘合成器：
        // 系统合成器的 layerInstruction 只有变换和不透明度，既没有遮罩、
        // 也没有调色。没设这些的项目继续走系统合成器，一行不改。
        let needsCustom = (plans + overlays).contains { $0.item.properties.needsCustomCompositor }
        if needsCustom {
            vc.customVideoCompositorClass = DecorationCompositor.self
            vc.instructions = makeCompositeInstructions(instructions,
                                                        plans: plans,
                                                        videoTracks: videoTracks,
                                                        overlays: overlays,
                                                        overlayTracks: overlayTracks,
                                                        renderSize: renderSize)
        } else {
            vc.instructions = instructions
        }
        return vc
    }

    /// 空指令（只有黑底）：用来填时间线空隙和首尾没被片段盖住的区间
    private static func blank(from: CMTime, to: CMTime) -> AVMutableVideoCompositionInstruction {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: from, duration: CMTimeSubtract(to, from))
        instruction.layerInstructions = []
        return instruction
    }

    // MARK: - 黑底轨

    /// 造一条覆盖整段时长的黑色视频轨。一帧黑色画面按总时长拉伸，
    /// 比逐帧插入便宜得多（60 秒的时间线也只插一次）。
    private static func makeBackdropTrack(in composition: AVMutableComposition,
                                          renderSize: CGSize,
                                          totalDuration: Double) -> AVMutableCompositionTrack? {
        guard let asset = blackFrameAsset(renderSize: renderSize),
              let source = asset.tracks(withMediaType: .video).first,
              let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }

        let frame = CMTime(value: 1, timescale: 30)
        do {
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: frame),
                                      of: source, at: .zero)
        } catch {
            return nil
        }
        track.scaleTimeRange(CMTimeRange(start: .zero, duration: frame),
                             toDuration: cmt(totalDuration))
        return track
    }

    /// 一帧黑色画面的缓存文件，按尺寸各存一份，重复导出不再重写
    private static let blackFrameLock = NSLock()

    private static func blackFrameAsset(renderSize: CGSize) -> AVURLAsset? {
        let width = Int(renderSize.width.rounded())
        let height = Int(renderSize.height.rounded())
        guard width > 1, height > 1 else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiva-backdrop-\(width)x\(height).mov")

        blackFrameLock.lock()
        defer { blackFrameLock.unlock() }

        if !FileManager.default.fileExists(atPath: url.path) {
            guard writeBlackFrame(to: url, width: width, height: height) else { return nil }
        }
        return AVURLAsset(url: url)
    }

    private static func writeBlackFrame(to url: URL, width: Int, height: Int) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            writer.cancelWriting()
            return false
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pixel = buffer else {
            writer.cancelWriting()
            return false
        }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let base = CVPixelBufferGetBaseAddress(pixel),
           let context = CGContext(data: base,
                                   width: width,
                                   height: height,
                                   bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                       | CGBitmapInfo.byteOrder32Little.rawValue) {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])

        while !input.isReadyForMoreMediaData { usleep(1000) }
        adaptor.append(pixel, withPresentationTime: .zero)
        input.markAsFinished()

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        return writer.status == .completed
    }

    private static func singleInstruction(plan: ClipPlan,
                                          track: AVMutableCompositionTrack,
                                          from: Double,
                                          to: Double,
                                          renderSize: CGSize) -> AVMutableVideoCompositionInstruction? {
        guard let range = timeRange(from: from, to: to) else { return nil }
        let instruction = AVMutableVideoCompositionInstruction()
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
        // 有入场 / 出场动效时走单独一条路径：动效要求不透明度和变换按**同一条
        // 采样表**发 ramp，而下面这段淡入淡出逻辑有一堆「ramp 端点必须和片段
        // 结尾同一个 tick」的细节（验证过几百条断言）。两套逻辑混在一起容易
        // 互相踩，所以干脆分开：没有动效的项目仍然走原来那条，一个字节都不变
        if plan.item.properties.motion.hasMotion {
            return motionLayerInstruction(plan: plan, track: track,
                                          renderSize: renderSize, range: range)
        }

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let base = baseTransform(plan: plan, renderSize: renderSize)
        let clipStart = plan.item.startTime
        let props = plan.item.properties
        let clipDuration = max(0.05, plan.timelineDuration)

        // 缩放：有关键帧就逐段做变换 ramp，否则用一个固定变换
        let scaleSamples = props.animationSamples(.scale, duration: clipDuration)
        if scaleSamples.count > 1 {
            for index in 1..<scaleSamples.count {
                let a = scaleSamples[index - 1]
                let b = scaleSamples[index]
                guard b.time - a.time > 0.001,
                      let ramp = timeRange(from: clipStart + a.time, to: clipStart + b.time) else { continue }
                let from = baseTransform(plan: plan, renderSize: renderSize, scaleOverride: a.value)
                let to = baseTransform(plan: plan, renderSize: renderSize, scaleOverride: b.value)
                layer.setTransformRamp(fromStart: from, toEnd: to, timeRange: ramp)
            }
        } else {
            layer.setTransform(base, at: range.start)
        }

        let opacity = Float(min(max(props.opacity, 0), 1))

        // 不透明度：有关键帧时整段由关键帧接管，淡入淡出不再叠加
        let opacitySamples = props.animationSamples(.opacity, duration: clipDuration)
        if opacitySamples.count > 1 {
            for index in 1..<opacitySamples.count {
                let a = opacitySamples[index - 1]
                let b = opacitySamples[index]
                guard b.time - a.time > 0.001,
                      let ramp = timeRange(from: clipStart + a.time, to: clipStart + b.time) else { continue }
                layer.setOpacityRamp(fromStartOpacity: Float(min(max(a.value, 0), 1)),
                                     toEndOpacity: Float(min(max(b.value, 0), 1)),
                                     timeRange: ramp)
            }
            return layer
        }

        layer.setOpacity(opacity, at: range.start)

        // 入场淡入（有转场时由转场指令接管）
        if plan.inTransition <= 0 {
            let fadeIn = min(plan.item.properties.fadeIn, plan.timelineDuration * 0.5)
            if fadeIn > 0.02, let ramp = timeRange(from: clipStart, to: clipStart + fadeIn) {
                layer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: opacity, timeRange: ramp)
            }
        }

        // 淡出：终点必须和片段结尾是同一个 tick，否则会和淡入 ramp 叠上 1 tick
        let fadeOut = min(plan.item.properties.fadeOut, plan.timelineDuration * 0.5)
        if fadeOut > 0.02 {
            let clipEnd = clipStart + plan.timelineDuration
            if let ramp = timeRange(from: clipEnd - fadeOut, to: clipEnd) {
                layer.setOpacityRamp(fromStartOpacity: opacity, toEndOpacity: 0, timeRange: ramp)
            }
        }
        return layer
    }

    /// 主画面的入场 / 出场动效。
    ///
    /// 和画中画的区别只有一处：位移按**画幅**宽高换算（`rect = 画幅`），
    /// 所以「左侧入场」在主画面上是整帧从画面左边推进来，在画中画上是
    /// 那个小窗从自己左边滑进来。
    private static func motionLayerInstruction(plan: ClipPlan,
                                               track: AVMutableCompositionTrack,
                                               renderSize: CGSize,
                                               range: CMTimeRange) -> AVMutableVideoCompositionLayerInstruction {
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let props = plan.item.properties
        let a = plan.item.startTime
        let span = max(0.05, plan.timelineDuration)
        let motionStyle = props.motion.sanitized
        let half = span / 2
        // 和淡入同一条规矩：片段开头就在转场里的话，入场交给转场，不再叠加
        let fadeIn = plan.inTransition > 0 ? 0 : min(max(0, props.fadeIn), half)
        let fadeOut = min(max(0, props.fadeOut), half)
        let opacityKeyed = !props.keyframes(for: .opacity).isEmpty
        let scaleKeyed = !props.keyframes(for: .scale).isEmpty
        let frameRect = CGRect(origin: .zero, size: renderSize)

        func factors(_ t: Double) -> PiPMotionFactors {
            PiPMotion.combined(enter: motionStyle.enterMotion,
                               enterDuration: motionStyle.enterDuration,
                               exit: motionStyle.exitMotion,
                               exitDuration: motionStyle.exitDuration,
                               span: span,
                               at: min(max(t - a, 0), span))
        }

        func opacity(_ t: Double) -> Double {
            let local = min(max(t - a, 0), span)
            var value: Double
            if opacityKeyed {
                value = min(max(props.animatedValue(.opacity, at: local), 0), 1)
            } else {
                value = min(max(props.opacity, 0), 1)
                if fadeIn > 0.02, local < fadeIn { value *= local / fadeIn }
                if fadeOut > 0.02, local > span - fadeOut { value *= (span - local) / fadeOut }
            }
            return max(0, value) * factors(t).opacity
        }

        func transform(_ t: Double) -> CGAffineTransform {
            let local = min(max(t - a, 0), span)
            let base = baseTransform(plan: plan, renderSize: renderSize,
                                     scaleOverride: scaleKeyed
                                        ? props.animatedValue(.scale, at: local) : nil)
            return PiPMotion.apply(factors(t), to: base, rect: frameRect)
        }

        var marks: [Double] = [a, a + span]
        if fadeIn > 0.02 { marks.append(a + fadeIn) }
        if fadeOut > 0.02 { marks.append(a + span - fadeOut) }
        if scaleKeyed {
            marks += props.animationSamples(.scale, duration: span).map { a + $0.time }
        }
        if opacityKeyed {
            marks += props.animationSamples(.opacity, duration: span).map { a + $0.time }
        }
        marks += PiPMotion.sampleOffsets(span: span,
                                         enterDuration: motionStyle.enterDuration,
                                         exitDuration: motionStyle.exitDuration).map { a + $0 }

        let lo = CMTimeGetSeconds(range.start)
        let hi = CMTimeGetSeconds(range.end)
        var times: [Double] = [lo, hi]
        for t in marks where t > lo + 0.0005 && t < hi - 0.0005 {
            if times.allSatisfy({ abs($0 - t) > 0.0005 }) { times.append(t) }
        }
        times.sort()

        // 起点先落一个定值，否则指令从片段中间切开时第一段没有起始状态
        layer.setOpacity(Float(opacity(times[0])), at: range.start)
        layer.setTransform(transform(times[0]), at: range.start)

        for index in 1..<times.count {
            let t0 = times[index - 1]
            let t1 = times[index]
            guard t1 - t0 > 0.0005, let ramp = timeRange(from: t0, to: t1) else { continue }
            layer.setOpacityRamp(fromStartOpacity: Float(opacity(t0)),
                                 toEndOpacity: Float(opacity(t1)),
                                 timeRange: ramp)
            layer.setTransformRamp(fromStart: transform(t0),
                                   toEnd: transform(t1),
                                   timeRange: ramp)
        }
        return layer
    }

    private static func transitionInstruction(prev: ClipPlan,
                                              prevTrack: AVMutableCompositionTrack,
                                              cur: ClipPlan,
                                              curTrack: AVMutableCompositionTrack,
                                              duration: Double,
                                              renderSize: CGSize) -> AVMutableVideoCompositionInstruction? {
        let startSeconds = cur.item.startTime
        guard let range = timeRange(from: startSeconds, to: startSeconds + duration) else { return nil }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
        let actual = CMTimeGetSeconds(range.duration)

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

        // 任一侧有关键帧时，把转场区间切成小段，逐段把关键帧的缩放 / 不透明度
        // 叠加到转场进度上（AVFoundation 的 ramp 只能两点线性）
        if prev.item.properties.hasAnyKeyframes || cur.item.properties.hasAnyKeyframes {
            applySteppedTransition(transition: cur.item.transition,
                                   prev: prev, cur: cur,
                                   outLayer: outLayer, inLayer: inLayer,
                                   renderSize: renderSize,
                                   start: startSeconds,
                                   duration: actual)
            instruction.layerInstructions = [outLayer, inLayer]
            return instruction
        }

        switch cur.item.transition {
        case .none:
            break

        case .crossDissolve:
            outLayer.setOpacityRamp(fromStartOpacity: outOpacity, toEndOpacity: 0, timeRange: range)
            inLayer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: inOpacity, timeRange: range)

        case .fadeThroughBlack:
            // 前后两半共用同一个中点 tick，否则中间会漏一格全黑或叠一格
            let half = startSeconds + actual / 2
            if let first = timeRange(from: startSeconds, to: half) {
                outLayer.setOpacityRamp(fromStartOpacity: outOpacity, toEndOpacity: 0, timeRange: first)
            }
            if let second = timeRange(from: half, to: startSeconds + actual) {
                inLayer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: inOpacity, timeRange: second)
            }

        case .slideLeft:
            let dx = renderSize.width
            // translatedBy 作用在「源坐标」上，会被 fit 缩放放大数倍；
            // 这里要的是渲染坐标系里的位移，所以用 concatenating
            outLayer.setTransformRamp(fromStart: outBase,
                                      toEnd: outBase.concatenating(CGAffineTransform(translationX: -dx, y: 0)),
                                      timeRange: range)
            inLayer.setTransformRamp(fromStart: inBase.concatenating(CGAffineTransform(translationX: dx, y: 0)),
                                     toEnd: inBase,
                                     timeRange: range)
            // 等值的 opacity ramp 会被 AVFoundation 当成 no-op，导致入场层一直透明（中段黑屏），
            // 这里直接给个定值
            inLayer.setOpacity(inOpacity, at: range.start)

        case .zoomIn:
            let center = CGPoint(x: renderSize.width / 2, y: renderSize.height / 2)
            outLayer.setOpacityRamp(fromStartOpacity: outOpacity, toEndOpacity: 0, timeRange: range)
            inLayer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: inOpacity, timeRange: range)
            inLayer.setTransformRamp(fromStart: inBase.concatenating(scaleAbout(0.86, center: center)),
                                     toEnd: inBase,
                                     timeRange: range)
        }

        // 层顺序：前 → 后（滑动转场入场层在下，避免把前一段整块盖住）
        instruction.layerInstructions = [outLayer, inLayer]
        return instruction
    }

    // MARK: - 画中画

    /// 画中画目标矩形：按「画幅宽 × widthRatio」等比缩放，再贴到指定角。
    /// 目标宽高比取素材自身的宽高比，所以这里不需要再走一次 fit / fill。
    ///
    /// 坐标系是视频合成的坐标系：原点在左上角，**y 向下增长**。
    static func pipRect(naturalSize: CGSize,
                        renderSize: CGSize,
                        style: PiPStyle) -> CGRect {
        let s = style.sanitized
        guard naturalSize.width > 1, naturalSize.height > 1,
              renderSize.width > 1, renderSize.height > 1 else { return .zero }

        var width = renderSize.width * CGFloat(s.widthRatio)
        var height = width * naturalSize.height / naturalSize.width
        guard width > 0.5, height > 0.5, height.isFinite else { return .zero }
        let margin = renderSize.width * CGFloat(s.margin)

        // 竖屏素材放大到 70% 宽时高度会远超画幅，直接按宽算会顶出画面。
        // 这里等比缩到「画幅减去两侧留白」以内，比例不变、保证完整可见。
        let maxWidth = renderSize.width - 2 * margin
        let maxHeight = renderSize.height - 2 * margin
        if maxWidth > 1, maxHeight > 1 {
            let fit = min(1, min(maxWidth / width, maxHeight / height))
            if fit < 1, fit.isFinite {
                width *= fit
                height *= fit
            }
        }

        let origin: CGPoint
        if let free = s.freeOrigin {
            // 自由位置：直接按归一化坐标落位，再夹回「留白以内」。
            // 夹的时候上下界可能相等（画中画正好占满可放区域），用 max 兜一下，
            // 否则 min(max(x, lo), hi) 在 hi < lo 时会把位置甩到负值。
            let rawX = CGFloat(free.x) * renderSize.width
            let rawY = CGFloat(free.y) * renderSize.height
            let loX = margin
            let loY = margin
            let hiX = max(loX, renderSize.width - margin - width)
            let hiY = max(loY, renderSize.height - margin - height)
            origin = CGPoint(x: min(max(rawX, loX), hiX),
                             y: min(max(rawY, loY), hiY))
        } else {
            switch s.position {
            case .topLeading:
                origin = CGPoint(x: margin, y: margin)
            case .topTrailing:
                origin = CGPoint(x: renderSize.width - margin - width, y: margin)
            case .bottomLeading:
                origin = CGPoint(x: margin, y: renderSize.height - margin - height)
            case .bottomTrailing:
                origin = CGPoint(x: renderSize.width - margin - width,
                                 y: renderSize.height - margin - height)
            case .center:
                origin = CGPoint(x: (renderSize.width - width) / 2,
                                 y: (renderSize.height - height) / 2)
            }
        }
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    private static func pipTransform(plan: ClipPlan,
                                     renderSize: CGSize,
                                     widthRatioOverride: Double? = nil) -> CGAffineTransform {
        pipGeometry(plan: plan, renderSize: renderSize,
                    widthRatioOverride: widthRatioOverride).transform
    }

    /// 画中画的「最终矩形 + 变换」。
    ///
    /// 动效要绕矩形中心缩放、按矩形宽高换算位移，所以两个值必须一起出来：
    /// 只拿变换的话，得从矩阵里反推中心点，遇到旋转就推不对了。
    private static func pipGeometry(plan: ClipPlan,
                                    renderSize: CGSize,
                                    widthRatioOverride: Double? = nil) -> (transform: CGAffineTransform,
                                                                          rect: CGRect) {
        let raw = CGRect(origin: .zero, size: plan.naturalSize).applying(plan.preferredTransform)
        let width = abs(raw.width)
        let height = abs(raw.height)
        guard width > 1, height > 1 else { return (.identity, .zero) }

        var style = plan.item.properties.pip
        // 缩放（静态值或关键帧）当作画中画尺寸的倍率：
        // 「尺寸」定基准，缩放用来做推拉动画，两者语义不打架
        let multiplier = min(max(widthRatioOverride ?? plan.item.properties.scale, 0.1), 3.0)
        style.widthRatio *= multiplier
        let rect = pipRect(naturalSize: CGSize(width: width, height: height),
                           renderSize: renderSize,
                           style: style)
        guard rect.width > 0.5 else { return (.identity, .zero) }

        let box = CGRect(x: raw.minX, y: raw.minY, width: width, height: height)
        let scale = rect.width / width

        var transform = plan.preferredTransform
        transform = transform.concatenating(CGAffineTransform(translationX: -box.midX, y: -box.midY))
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))

        let angle = plan.item.properties.rotation * .pi / 180
        if abs(angle) > 0.0001 {
            transform = transform.concatenating(CGAffineTransform(rotationAngle: angle))
        }
        transform = transform.concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        return (transform, rect)
    }

    /// 给画中画图层铺「不透明度 + 变换」曲线，只覆盖 [lo, hi] 这一条指令。
    ///
    /// 关键在区间外归零：AVFoundation 会把断流 track 的末帧 hold 到指令结束，
    /// 不归零画中画就会一直糊到片尾。区间内的曲线按片段自身的
    /// opacity / 淡入淡出 / 关键帧走，指令从曲线中间切开时端点按插值算，
    /// 所以画中画横跨多条指令也不会跳变。
    private static func applyOverlay(_ layer: AVMutableVideoCompositionLayerInstruction,
                                     plan: ClipPlan,
                                     renderSize: CGSize,
                                     clipTo lo: Double,
                                     hi: Double) {
        let a = plan.item.startTime
        let b = a + plan.timelineDuration
        guard b > a + 0.0005, hi > lo else { return }

        let props = plan.item.properties
        let span = b - a
        let half = span / 2
        let fadeIn = min(max(0, props.fadeIn), half)
        let fadeOut = min(max(0, props.fadeOut), half)

        // 有关键帧时整段交给关键帧，淡入淡出不再叠加（和主画面片段规则一致）
        let opacityKeyed = !props.keyframes(for: .opacity).isEmpty
        let scaleKeyed = !props.keyframes(for: .scale).isEmpty
        let motionStyle = props.motion.sanitized
        let motionActive = motionStyle.hasMotion

        /// 该时刻的入场 / 出场乘数
        func motion(_ local: Double) -> PiPMotionFactors {
            guard motionActive else { return PiPMotionFactors() }
            return PiPMotion.combined(enter: motionStyle.enterMotion,
                                      enterDuration: motionStyle.enterDuration,
                                      exit: motionStyle.exitMotion,
                                      exitDuration: motionStyle.exitDuration,
                                      span: span,
                                      at: local)
        }

        /// 区间内某时刻的相对不透明度（不含「区间外为 0」这层）
        func base(_ t: Double) -> Double {
            let local = min(max(t - a, 0), span)
            var value: Double
            if opacityKeyed {
                value = min(max(props.animatedValue(.opacity, at: local), 0), 1)
            } else {
                value = min(max(props.opacity, 0), 1)
                var factor = 1.0
                if fadeIn > 0.02, local < fadeIn { factor = min(factor, local / fadeIn) }
                if fadeOut > 0.02, local > span - fadeOut {
                    factor = min(factor, (span - local) / fadeOut)
                }
                value *= max(0, factor)
            }
            // 动效是叠在淡入淡出 / 关键帧之上的一层乘数
            return value * motion(local).opacity
        }

        /// 该时刻的变换（含缩放关键帧与动效）
        func transform(_ t: Double) -> CGAffineTransform {
            let local = min(max(t - a, 0), span)
            let ratio = scaleKeyed ? props.animatedValue(.scale, at: local) : nil
            let geometry = pipGeometry(plan: plan, renderSize: renderSize,
                                       widthRatioOverride: ratio)
            guard motionActive else { return geometry.transform }
            return PiPMotion.apply(motion(local), to: geometry.transform, rect: geometry.rect)
        }

        func value(_ t: Double) -> Double {
            (t < a || t > b) ? 0 : base(t)
        }

        // 折点：片段两端、淡入淡出边界、关键帧时间点、动效窗口内的细分点
        var breaks: [Double] = [a, b]
        if fadeIn > 0.02 { breaks.append(a + fadeIn) }
        if fadeOut > 0.02 { breaks.append(b - fadeOut) }
        for frame in props.keyframes(for: .opacity) {
            breaks.append(min(max(a + frame.time, a), b))
        }
        for frame in props.keyframes(for: .scale) {
            breaks.append(min(max(a + frame.time, a), b))
        }
        if motionActive {
            for offset in PiPMotion.sampleOffsets(span: span,
                                                  enterDuration: motionStyle.enterDuration,
                                                  exitDuration: motionStyle.exitDuration) {
                breaks.append(min(max(a + offset, a), b))
            }
        }

        var samples: [Double] = [lo, hi]
        for t in breaks where t > lo + 0.0005 && t < hi - 0.0005 {
            if samples.allSatisfy({ abs($0 - t) > 0.0005 }) { samples.append(t) }
        }
        samples.sort()

        // 指令从画中画之前开始时，先把图层压到全透明，否则默认是不透明的
        if lo <= a + 0.0005 {
            layer.setOpacity(0, at: cmt(lo))
        }

        for index in 1..<samples.count {
            let t0 = samples[index - 1]
            let t1 = samples[index]
            guard t1 - t0 > 0.0005, let range = timeRange(from: t0, to: t1) else { continue }
            layer.setOpacityRamp(fromStartOpacity: Float(value(t0)),
                                 toEndOpacity: Float(value(t1)),
                                 timeRange: range)
        }

        // 指令跨过画中画结尾时补一个归零台阶：淡出为 0 时 ramp 已经收在 0，
        // 否则（无淡出）需要这一下硬切，避免末帧被 hold 住
        if hi >= b - 0.0005, fadeOut <= 0.02, !opacityKeyed {
            layer.setOpacity(0, at: cmt(b))
        }

        // 变换：没有缩放关键帧、也没有动效时一个定值就够
        if !scaleKeyed && !motionActive {
            layer.setTransform(pipTransform(plan: plan, renderSize: renderSize), at: cmt(lo))
            return
        }
        var previous: CGAffineTransform?
        for index in 0..<samples.count {
            let t = samples[index]
            let current = transform(t)
            if index > 0, let from = previous,
               let range = timeRange(from: samples[index - 1], to: t) {
                layer.setTransformRamp(fromStart: from, toEnd: current, timeRange: range)
            }
            previous = current
        }
        if let first = previous, samples.count == 1 {
            layer.setTransform(first, at: cmt(lo))
        }
    }

    // MARK: - 带关键帧的转场

    /// 把转场区间切成小段，逐段计算「转场进度 × 关键帧值」，再发 ramp
    /// 转场在某一时刻的两层状态：不透明度 + 变换。
    ///
    /// 抽成静态函数是为了让两条路径共用同一份曲线——系统合成器走
    /// `setOpacityRamp` / `setTransformRamp`，自绘合成器走采样点。
    /// 各写一份迟早会漂移：预览看着没问题、导出少淡一格这种 bug 最难查。
    private static func transitionState(transition: TransitionType,
                                        prev: ClipPlan,
                                        cur: ClipPlan,
                                        renderSize: CGSize,
                                        start: Double,
                                        duration: Double,
                                        at t: Double) -> (outAlpha: Double, inAlpha: Double,
                                                          outTransform: CGAffineTransform,
                                                          inTransform: CGAffineTransform) {
        func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
        let p = min(1, max(0, (t - start) / max(0.001, duration)))
        let outA = clamp01(prev.item.properties.animatedValue(.opacity, at: t - prev.item.startTime))
        let inA = clamp01(cur.item.properties.animatedValue(.opacity, at: t - cur.item.startTime))
        let outT = baseTransform(plan: prev, renderSize: renderSize,
                                 scaleOverride: prev.item.properties.animatedValue(.scale, at: t - prev.item.startTime))
        let inT = baseTransform(plan: cur, renderSize: renderSize,
                                scaleOverride: cur.item.properties.animatedValue(.scale, at: t - cur.item.startTime))

        switch transition {
        case .none:
            return (outA, inA, outT, inT)
        case .crossDissolve:
            return (outA * (1 - p), inA * p, outT, inT)
        case .fadeThroughBlack:
            if p < 0.5 {
                return (outA * (1 - p * 2), 0, outT, inT)
            } else {
                return (0, inA * ((p - 0.5) * 2), outT, inT)
            }
        case .slideLeft:
            let dx = renderSize.width
            return (outA, inA,
                    outT.concatenating(CGAffineTransform(translationX: -dx * CGFloat(p), y: 0)),
                    inT.concatenating(CGAffineTransform(translationX: dx * CGFloat(1 - p), y: 0)))
        case .zoomIn:
            let center = CGPoint(x: renderSize.width / 2, y: renderSize.height / 2)
            let zoom = 0.86 + 0.14 * p
            return (outA * (1 - p), inA * p,
                    outT,
                    inT.concatenating(scaleAbout(zoom, center: center)))
        }
    }

    private static func applySteppedTransition(transition: TransitionType,
                                               prev: ClipPlan,
                                               cur: ClipPlan,
                                               outLayer: AVMutableVideoCompositionLayerInstruction,
                                               inLayer: AVMutableVideoCompositionLayerInstruction,
                                               renderSize: CGSize,
                                               start: Double,
                                               duration: Double) {
        let steps = max(6, min(48, Int((duration / 0.05).rounded())))

        func state(at t: Double) -> (outAlpha: Float, inAlpha: Float,
                                     outTransform: CGAffineTransform,
                                     inTransform: CGAffineTransform) {
            let s = transitionState(transition: transition, prev: prev, cur: cur,
                                    renderSize: renderSize, start: start,
                                    duration: duration, at: t)
            return (Float(s.outAlpha), Float(s.inAlpha), s.outTransform, s.inTransform)
        }

        var previous = state(at: start)
        for step in 1...steps {
            let stepEnd = start + duration * Double(step) / Double(steps)
            let current = state(at: stepEnd)
            let stepStart = start + duration * Double(step - 1) / Double(steps)
            // 相邻两段共用同一个边界 tick，否则段与段之间会漏缝或叠上
            guard let range = timeRange(from: stepStart, to: stepEnd) else { continue }

            outLayer.setOpacityRamp(fromStartOpacity: previous.outAlpha,
                                    toEndOpacity: current.outAlpha,
                                    timeRange: range)
            inLayer.setOpacityRamp(fromStartOpacity: previous.inAlpha,
                                   toEndOpacity: current.inAlpha,
                                   timeRange: range)
            outLayer.setTransformRamp(fromStart: previous.outTransform,
                                      toEnd: current.outTransform,
                                      timeRange: range)
            inLayer.setTransformRamp(fromStart: previous.inTransform,
                                     toEnd: current.inTransform,
                                     timeRange: range)
            previous = current
        }
    }

    // MARK: - 自绘合成器（圆角 / 描边）

    /// 把已经铺好的系统指令逐条翻成自绘指令。
    ///
    /// 刻意复用系统的切分结果而不是自己重排一遍：指令边界、转场区间、
    /// 空隙补黑这些规则在 makeVideoComposition 里已经调通了（踩过 -11841），
    /// 重新铺一遍等于把那些坑再踩一次。这里只补「每层在这一段里的曲线」。
    private static func makeCompositeInstructions(_ instructions: [AVMutableVideoCompositionInstruction],
                                                  plans: [ClipPlan],
                                                  videoTracks: [AVMutableCompositionTrack],
                                                  overlays: [ClipPlan],
                                                  overlayTracks: [AVMutableCompositionTrack],
                                                  renderSize: CGSize) -> [CompositeInstruction] {
        func plan(for trackID: CMPersistentTrackID,
                  in list: [ClipPlan],
                  tracks: [AVMutableCompositionTrack],
                  lo: Double,
                  hi: Double) -> ClipPlan? {
            list.first { plan in
                guard plan.trackSlot < tracks.count, tracks[plan.trackSlot].trackID == trackID else {
                    return false
                }
                let a = plan.item.startTime
                // 必须把 extraTail 算进来：转场时前一段会向后延 t 秒，
                // 它的名义区间只到转场起点，不加延展量就会被判成「不相交」，
                // 于是转场里只剩后一段——交叉淡入直接变成硬切。
                let b = a + plan.timelineDuration + plan.extraTail
                return b > lo + 0.0005 && a < hi - 0.0005
            }
        }

        return instructions.map { instruction in
            let lo = CMTimeGetSeconds(instruction.timeRange.start)
            let hi = CMTimeGetSeconds(instruction.timeRange.end)

            var mainPlans: [ClipPlan] = []
            var overlayPlans: [ClipPlan] = []
            for layer in instruction.layerInstructions {
                let id = layer.trackID
                guard id != kCMPersistentTrackID_Invalid else { continue }
                if let p = plan(for: id, in: plans, tracks: videoTracks, lo: lo, hi: hi) {
                    mainPlans.append(p)
                } else if let p = plan(for: id, in: overlays, tracks: overlayTracks, lo: lo, hi: hi) {
                    overlayPlans.append(p)
                }
                // 黑底轨在这里匹配不到任何 plan，直接丢掉——自绘路径的画布本来就是黑的
            }

            var layers: [RenderLayer] = []

            // 画中画在最前面
            for p in overlayPlans {
                guard p.trackSlot < overlayTracks.count else { continue }
                if let spec = overlayLayerSpec(plan: p,
                                               track: overlayTracks[p.trackSlot],
                                               renderSize: renderSize,
                                               lo: lo,
                                               hi: hi) {
                    layers.append(spec)
                }
            }

            if mainPlans.count >= 2 {
                // 转场：两条主画面层
                let prev = mainPlans[0]
                let cur = mainPlans[1]
                guard prev.trackSlot < videoTracks.count,
                      cur.trackSlot < videoTracks.count else {
                    return CompositeInstruction(timeRange: instruction.timeRange, layers: layers)
                }
                layers += transitionLayerSpecs(prev: prev,
                                               prevTrack: videoTracks[prev.trackSlot],
                                               cur: cur,
                                               curTrack: videoTracks[cur.trackSlot],
                                               renderSize: renderSize,
                                               lo: lo,
                                               hi: hi)
            } else if let p = mainPlans.first, p.trackSlot < videoTracks.count {
                if let spec = clipLayerSpec(plan: p,
                                            track: videoTracks[p.trackSlot],
                                            renderSize: renderSize,
                                            lo: lo,
                                            hi: hi) {
                    layers.append(spec)
                }
            }

            return CompositeInstruction(timeRange: instruction.timeRange, layers: layers)
        }
    }

    /// 折点 → 采样点表：只留落在 (lo, hi) 里的，按时间升序，相邻太近的合并。
    /// 两端必须正好是 lo / hi，否则合成器在指令边界上取不到值。
    private static func sampleTimes(_ marks: [Double], lo: Double, hi: Double) -> [Double] {
        guard hi > lo + 0.0005 else { return [lo] }
        var out: [Double] = [lo]
        for t in marks.sorted() where t.isFinite {
            guard t > lo + 0.0005, t < hi - 0.0005 else { continue }
            if let last = out.last, t - last < 0.0005 { continue }
            out.append(t)
        }
        out.append(hi)
        return out
    }

    /// 主画面单段的曲线。规则和 `layerInstruction` 一一对应：
    /// 有关键帧时整段交给关键帧（淡入淡出不再叠加）、有入场转场时淡入交给转场。
    private static func clipLayerSpec(plan: ClipPlan,
                                      track: AVMutableCompositionTrack,
                                      renderSize: CGSize,
                                      lo: Double,
                                      hi: Double) -> RenderLayer? {
        guard hi > lo + 0.0005 else { return nil }
        let a = plan.item.startTime
        let span = max(0.05, plan.timelineDuration)
        let b = a + span
        let props = plan.item.properties
        let half = span / 2
        let fadeIn = plan.inTransition > 0 ? 0 : min(max(0, props.fadeIn), half)
        let fadeOut = min(max(0, props.fadeOut), half)
        let opacityKeyed = !props.keyframes(for: .opacity).isEmpty
        let scaleKeyed = !props.keyframes(for: .scale).isEmpty
        let motionStyle = props.motion.sanitized
        let motionActive = motionStyle.hasMotion
        let fixed = baseTransform(plan: plan, renderSize: renderSize)
        let frameRect = CGRect(origin: .zero, size: renderSize)

        func factors(_ l: Double) -> PiPMotionFactors {
            guard motionActive else { return PiPMotionFactors() }
            return PiPMotion.combined(enter: motionStyle.enterMotion,
                                      enterDuration: motionStyle.enterDuration,
                                      exit: motionStyle.exitMotion,
                                      exitDuration: motionStyle.exitDuration,
                                      span: span,
                                      at: l)
        }

        func opacity(at t: Double) -> Double {
            let local = t - a
            guard local >= -0.0005, local <= span + 0.0005 else { return 0 }
            let l = min(max(local, 0), span)
            let base: Double
            if opacityKeyed {
                base = min(max(props.animatedValue(.opacity, at: l), 0), 1)
            } else {
                var value = min(max(props.opacity, 0), 1)
                if fadeIn > 0.02, l < fadeIn { value *= l / fadeIn }
                if fadeOut > 0.02, l > span - fadeOut { value *= (span - l) / fadeOut }
                base = max(0, value)
            }
            return base * factors(l).opacity
        }

        func transform(at t: Double) -> CGAffineTransform {
            guard scaleKeyed || motionActive else { return fixed }
            let l = min(max(t - a, 0), span)
            let base = baseTransform(plan: plan, renderSize: renderSize,
                                     scaleOverride: scaleKeyed
                                        ? props.animatedValue(.scale, at: l) : nil)
            guard motionActive else { return base }
            return PiPMotion.apply(factors(l), to: base, rect: frameRect)
        }

        var marks: [Double] = [a, b]
        if fadeIn > 0.02 { marks.append(a + fadeIn) }
        if fadeOut > 0.02 { marks.append(b - fadeOut) }
        if scaleKeyed {
            marks += props.animationSamples(.scale, duration: span).map { a + $0.time }
        }
        if opacityKeyed {
            marks += props.animationSamples(.opacity, duration: span).map { a + $0.time }
        }
        if motionActive {
            marks += PiPMotion.sampleOffsets(span: span,
                                             enterDuration: motionStyle.enterDuration,
                                             exitDuration: motionStyle.exitDuration).map { a + $0 }
        }

        let samples = sampleTimes(marks, lo: lo, hi: hi).map {
            (time: $0, opacity: opacity(at: $0), transform: transform(at: $0))
        }
        var layer = RenderLayer(trackID: track.trackID, samples: samples)
        attachGrade(to: &layer, props: props, start: a, span: span)
        return layer
    }

    /// 把调色挂到 layer 上。
    ///
    /// 有关键帧就生成采样点：时间点直接取 `animationSamples` 的结果——
    /// 那个函数已经把缓动曲线细分成折线了，这里再线性插值就不会丢掉缓动。
    /// 没有关键帧只写静态值，合成器连插值都不会做。
    private static func attachGrade(to layer: inout RenderLayer,
                                    props: ItemProperties,
                                    start: Double,
                                    span: Double) {
        layer.grade = props.grade.sanitized
        guard props.hasColorGradeKeyframes, span > 0.0005 else { return }

        var times: Set<Double> = [0, span]
        for property in AnimatableProperty.colorGradeProperties {
            for sample in props.animationSamples(property, duration: span) {
                times.insert(min(max(sample.time, 0), span))
            }
        }
        layer.gradeSamples = times.sorted().map {
            (time: start + $0, grade: props.resolvedGrade(at: $0))
        }
    }

    /// 转场两层。曲线直接来自 `transitionState`，和系统合成器那份是同一个函数。
    private static func transitionLayerSpecs(prev: ClipPlan,
                                             prevTrack: AVMutableCompositionTrack,
                                             cur: ClipPlan,
                                             curTrack: AVMutableCompositionTrack,
                                             renderSize: CGSize,
                                             lo: Double,
                                             hi: Double) -> [RenderLayer] {
        let duration = hi - lo
        guard duration > 0.0005 else { return [] }
        let transition = cur.item.transition

        func state(at t: Double) -> (outAlpha: Double, inAlpha: Double,
                                     outTransform: CGAffineTransform,
                                     inTransform: CGAffineTransform) {
            transitionState(transition: transition,
                            prev: prev, cur: cur,
                            renderSize: renderSize,
                            start: lo, duration: duration, at: t)
        }

        // 无关键帧时所有转场都是「两个端点线性插值」，两个采样点就够；
        // 有关键帧才需要细分，粒度和 applySteppedTransition 的步长对齐
        var marks: [Double] = [lo, hi]
        if prev.item.properties.hasAnyKeyframes || cur.item.properties.hasAnyKeyframes {
            let steps = max(6, min(48, Int((duration / 0.05).rounded())))
            for i in 1..<steps {
                marks.append(lo + duration * Double(i) / Double(steps))
            }
        }

        let times = sampleTimes(marks, lo: lo, hi: hi)
        let outSamples = times.map { t -> (time: Double, opacity: Double, transform: CGAffineTransform) in
            let s = state(at: t)
            return (t, s.outAlpha, s.outTransform)
        }
        let inSamples = times.map { t -> (time: Double, opacity: Double, transform: CGAffineTransform) in
            let s = state(at: t)
            return (t, s.inAlpha, s.inTransform)
        }
        // 层顺序和系统路径一致：前 → 后
        var outLayer = RenderLayer(trackID: prevTrack.trackID, samples: outSamples)
        attachGrade(to: &outLayer, props: prev.item.properties,
                    start: prev.item.startTime,
                    span: max(0.05, prev.timelineDuration))
        var inLayer = RenderLayer(trackID: curTrack.trackID, samples: inSamples)
        attachGrade(to: &inLayer, props: cur.item.properties,
                    start: cur.item.startTime,
                    span: max(0.05, cur.timelineDuration))
        return [outLayer, inLayer]
    }

    /// 画中画的曲线，规则和 `applyOverlay` 一一对应（含区间外归零）。
    private static func overlayLayerSpec(plan: ClipPlan,
                                         track: AVMutableCompositionTrack,
                                         renderSize: CGSize,
                                         lo: Double,
                                         hi: Double) -> RenderLayer? {
        let a = plan.item.startTime
        let b = a + plan.timelineDuration
        guard b > a + 0.0005, hi > lo + 0.0005 else { return nil }

        let props = plan.item.properties
        let span = b - a
        let half = span / 2
        let fadeIn = min(max(0, props.fadeIn), half)
        let fadeOut = min(max(0, props.fadeOut), half)
        let opacityKeyed = !props.keyframes(for: .opacity).isEmpty
        let scaleKeyed = !props.keyframes(for: .scale).isEmpty
        let style = props.pip.sanitized
        let motionStyle = props.motion.sanitized
        let motionActive = motionStyle.hasMotion
        let fixed = pipTransform(plan: plan, renderSize: renderSize)

        func motion(_ local: Double) -> PiPMotionFactors {
            guard motionActive else { return PiPMotionFactors() }
            return PiPMotion.combined(enter: motionStyle.enterMotion,
                                      enterDuration: motionStyle.enterDuration,
                                      exit: motionStyle.exitMotion,
                                      exitDuration: motionStyle.exitDuration,
                                      span: span,
                                      at: local)
        }

        func base(_ t: Double) -> Double {
            let local = min(max(t - a, 0), span)
            var value: Double
            if opacityKeyed {
                value = min(max(props.animatedValue(.opacity, at: local), 0), 1)
            } else {
                value = min(max(props.opacity, 0), 1)
                var factor = 1.0
                if fadeIn > 0.02, local < fadeIn { factor = min(factor, local / fadeIn) }
                if fadeOut > 0.02, local > span - fadeOut {
                    factor = min(factor, (span - local) / fadeOut)
                }
                value *= max(0, factor)
            }
            return value * motion(local).opacity
        }

        func opacity(at t: Double) -> Double { (t < a || t > b) ? 0 : base(t) }

        func transform(at t: Double) -> CGAffineTransform {
            guard scaleKeyed || motionActive else { return fixed }
            let local = min(max(t - a, 0), span)
            let ratio = scaleKeyed ? props.animatedValue(.scale, at: local) : nil
            let geometry = pipGeometry(plan: plan, renderSize: renderSize,
                                       widthRatioOverride: ratio)
            guard motionActive else { return geometry.transform }
            return PiPMotion.apply(motion(local), to: geometry.transform, rect: geometry.rect)
        }

        var marks: [Double] = [a, b]
        if fadeIn > 0.02 { marks.append(a + fadeIn) }
        if fadeOut > 0.02 { marks.append(b - fadeOut) }
        for frame in props.keyframes(for: .opacity) {
            marks.append(min(max(a + frame.time, a), b))
        }
        for frame in props.keyframes(for: .scale) {
            marks.append(min(max(a + frame.time, a), b))
        }
        if motionActive {
            for offset in PiPMotion.sampleOffsets(span: span,
                                                  enterDuration: motionStyle.enterDuration,
                                                  exitDuration: motionStyle.exitDuration) {
                marks.append(min(max(a + offset, a), b))
            }
        }

        let samples = sampleTimes(marks, lo: lo, hi: hi).map {
            (time: $0, opacity: opacity(at: $0), transform: transform(at: $0))
        }

        var layer = RenderLayer(trackID: track.trackID, samples: samples)
        attachGrade(to: &layer, props: props, start: a, span: span)
        if style.hasDecoration {
            layer.cornerRatio = style.cornerRadius
            layer.borderRatio = style.borderWidth
            layer.borderColor = Self.cgColor(hex: style.borderColorHex,
                                             alpha: style.borderOpacity)
        }
        if style.hasShadow {
            layer.shadowRatio = style.shadowRadius
            layer.shadowOffsetRatio = style.shadowOffset
            layer.shadowOpacity = style.shadowOpacity
            layer.shadowColor = Self.cgColor(hex: style.shadowColorHex, alpha: 1)
        }
        return layer
    }

    /// 0xRRGGBB + alpha → CGColor（sRGB，和字幕渲染保持一致）
    static func cgColor(hex: Int, alpha: Double) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: CGFloat(min(max(alpha, 0), 1)))
    }

    // MARK: - 变换

    private static func baseTransform(plan: ClipPlan,
                                      renderSize: CGSize,
                                      scaleOverride: Double? = nil) -> CGAffineTransform {
        let raw = CGRect(origin: .zero, size: plan.naturalSize).applying(plan.preferredTransform)
        let width = abs(raw.width)
        let height = abs(raw.height)
        guard width > 1, height > 1 else { return .identity }

        let rect = CGRect(x: raw.minX, y: raw.minY, width: width, height: height)
        let fit = fitScale(renderSize: renderSize,
                           naturalSize: CGSize(width: width, height: height),
                           mode: plan.fillMode)
        let userScale = max(0.01, scaleOverride ?? plan.item.properties.scale)
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

    /// 素材铺进画幅的比例。
    /// 适应取 min（完整画面，短边留黑边）；填满取 max（铺满画幅，长边被裁掉）。
    /// 画幅或素材尺寸非法时退回 1，避免 NaN 传进 transform。
    static func fitScale(renderSize: CGSize,
                         naturalSize: CGSize,
                         mode: ExportFillMode) -> CGFloat {
        guard naturalSize.width > 1, naturalSize.height > 1,
              renderSize.width > 1, renderSize.height > 1 else { return 1 }
        let widthRatio = renderSize.width / naturalSize.width
        let heightRatio = renderSize.height / naturalSize.height
        return mode == .fit ? min(widthRatio, heightRatio) : max(widthRatio, heightRatio)
    }

    private static func scaleAbout(_ scale: CGFloat, center: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -center.x, y: -center.y)
    }
}
