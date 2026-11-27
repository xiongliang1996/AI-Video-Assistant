//
//  TimelineView.swift
//  多轨时间线：拖拽移动 / 边缘裁剪 / 吸附 / 缩放 / 拖动播放头
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum DragMode {
    case move, trimStart, trimEnd
}

struct TimelineView: View {
    @EnvironmentObject var appState: AppState

    @State private var dragOrigin: TimelineItem?
    @State private var dragMode: DragMode = .move
    @State private var snapTime: Double?
    @State private var dropTime: Double?
    @State private var dropTrack: Int?
    @State private var dragLowerDelta: Double = -.greatestFiniteMagnitude
    @State private var dragUpperDelta: Double = .greatestFiniteMagnitude
    @State private var dragGroupIDs: Set<UUID> = []
    @State private var dragGroupStarts: [UUID: Double] = [:]
    /// 拖淡入淡出手柄时的起点快照：和裁剪一样，一次拖拽只记一个撤销点
    @State private var fadeOrigin: TimelineItem?
    @State private var fadeEdge: FadeEdge?
    @State private var fadeHint: String?
    @State private var fadeHintEdge: FadeEdge?

    private let basePPS: CGFloat = 26
    private let trackHeight: CGFloat = 46
    private let headWidth: CGFloat = 78
    private let minClipDuration: Double = 0.2

    private var pps: CGFloat { basePPS * appState.timelineZoom }

    /// 一张缩略图覆盖 1.6 秒素材：放大时间线时缩略图跟着变宽、变少，
    /// 缩小时自动变密，始终保持「一格约 1.6 秒」的阅读节奏
    private var thumbTileWidth: CGFloat { max(28, pps * 1.6) }

    private var canvasWidth: CGFloat {
        let seconds = max(appState.totalDuration, 30) + 20
        return max(900, CGFloat(seconds) * pps)
    }

    private var rulerSeconds: Int {
        Int(canvasWidth / pps)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                trackHeads
                Rectangle().fill(Theme.line).frame(width: 1)
                ScrollView(.horizontal, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            RulerView(pps: pps, seconds: rulerSeconds)
                                .frame(height: 22)
                                .contentShape(Rectangle())
                                .gesture(scrubGesture)

                            track(for: .video, lane: 0)
                            track(for: .video, lane: 1)
                            track(for: .audio, lane: 0)
                            track(for: .audio, lane: 1)
                            track(for: .subtitle, lane: 0)
                        }

                        if let snapTime {
                            snapLine(at: snapTime)
                        }
                        if let dropTime {
                            dropIndicator(at: dropTime, track: dropTrack)
                        }
                        playhead
                    }
                    .frame(width: canvasWidth, alignment: .topLeading)
                    .onDrop(of: [UTType.fileURL],
                            delegate: TimelineDropDelegate(pps: pps,
                                                           trackHeight: trackHeight,
                                                           rulerHeight: 22,
                                                           dropTime: $dropTime,
                                                           dropTrack: $dropTrack,
                                                           onDrop: handleDrop))
                }
            }
            // 空时间线的提示挂在「轨道区整体」上，不能挂在 ScrollView 内容里：
            // 内容宽度是 canvasWidth（≥900pt），按它居中会飘到屏幕外被裁掉。
            // 也不能挡住拖放，所以不接收点击
            .overlay {
                if appState.timeline.isEmpty {
                    emptyHint
                        .allowsHitTesting(false)
                }
            }
        }
        // 5 条轨道（V1 / V2 / A1 / A2 / S1）+ 标尺 + 工具栏
        .frame(height: 288)
        .background(Theme.panel2)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    // MARK: - 空状态

    /// 文案由 `EmptyTimelineHint` 决定（素材库空不空说法不一样），这里只管画
    private var emptyHint: some View {
        let hint = appState.emptyTimelineHint
        return VStack(spacing: 6) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.text3)
            Text(hint.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text2)
            Text(hint.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
            if hint.suggestsDemo {
                Text("想先看看效果？按 ⌘/ 打开使用引导")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.accent.opacity(0.85))
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.panel.opacity(0.94))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.line2, lineWidth: 1))
        )
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 3) {
            Text("时间线")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .padding(.trailing, 6)

            Button {} label: { Image(systemName: "cursorarrow") }
                .buttonStyle(IconButtonStyle(active: true, size: 24))
                .help("选择 / 拖拽")

            Button {
                splitAtPlayhead()
            } label: { Image(systemName: "scissors") }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("在播放头处切割所选片段")

            Button {
                appState.showingSmartCut = true
            } label: { Image(systemName: "wand.and.stars") }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("智能剪辑：按语音停顿切片 / 去停顿")

            Button {
                if let item = appState.selectedItem {
                    var copy = item
                    copy.transition = copy.transition == .none ? .crossDissolve : .none
                    appState.updateItem(copy)
                }
            } label: { Image(systemName: "circle.lefthalf.filled") }
                .buttonStyle(IconButtonStyle(active: (appState.selectedItem?.transition ?? TransitionType.none) != TransitionType.none,
                                             size: 24))
                .help("给所选片段加入/取消转场")

            Button {
                appState.snapAllTransitions()
            } label: { Image(systemName: "arrow.left.to.line") }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("把所有转场片段吸附成相邻（⌘⇧T）")

            Rectangle().fill(Theme.line2).frame(width: 1, height: 14)

            Button {
                appState.removeSelectedItem()
            } label: { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("删除所选")

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.text3)
                Slider(value: Binding(get: { appState.timelineZoom },
                                      set: { appState.timelineZoom = $0 }),
                       in: AppState.timelineZoomRange)
                    .controlSize(.mini)
                    .tint(Theme.accent)
                    .frame(width: 74)
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private var trackHeads: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 22)
            head("V1", "视频")
            head("V2", "画中画")
            head("A1", "音乐")
            head("A2", "配音")
            head("S1", "字幕")
        }
        .frame(width: headWidth)
    }

    private func head(_ code: String, _ name: String) -> some View {
        HStack(spacing: 5) {
            Text(code)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.06)))
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(Theme.text3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: trackHeight)
    }

    // MARK: - 轨道

    private func track(for kind: TimelineTrack, lane: Int) -> some View {
        let items = appState.clips(on: kind, lane: lane)
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.clear)
                .frame(height: trackHeight)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 1)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    appState.clearSelection()
                }

            ForEach(items) { item in
                clip(item)
            }
        }
        .frame(height: trackHeight)
    }

    private func clip(_ item: TimelineItem) -> some View {
        let width = max(28, CGFloat(item.duration) * pps)
        let status = appState.transitionStatus(for: item)
        let overlapWidth: CGFloat = {
            if case .active(let overlap) = status { return CGFloat(overlap) * pps }
            return 0
        }()
        return ClipView(item: item,
                        width: width,
                        selected: appState.selectedItemIDs.contains(item.id),
                        tileWidth: thumbTileWidth,
                        transitionStatus: status,
                        transitionWidth: overlapWidth,
                        pps: pps,
                        fadeHintEdge: fadeHintEdge,
                        fadeHintText: fadeHint,
                        onSelect: {
                            appState.select(item.id,
                                            additive: NSEvent.modifierFlags.contains(.command))
                        },
                        onMove: { translation, ended in
                            handleDrag(item, mode: .move, translation: translation, ended: ended)
                        },
                        onTrimStart: { translation, ended in
                            handleDrag(item, mode: .trimStart, translation: translation, ended: ended)
                        },
                        onTrimEnd: { translation, ended in
                            handleDrag(item, mode: .trimEnd, translation: translation, ended: ended)
                        },
                        onDuplicate: {
                            appState.select(item.id, additive: false)
                            appState.duplicateSelection()
                        },
                        onDelete: {
                            appState.select(item.id, additive: false)
                            appState.removeSelectedItem()
                        },
                        onAutoDuck: {
                            appState.select(item.id, additive: false)
                            appState.presentAutoDuck(for: item)
                        },
                        onFadeIn: { translation, ended in
                            handleFade(item, edge: .fadeIn, translation: translation, ended: ended)
                        },
                        onFadeOut: { translation, ended in
                            handleFade(item, edge: .fadeOut, translation: translation, ended: ended)
                        },
                        onClearFade: {
                            appState.select(item.id, additive: false)
                            appState.beginEdit()
                            var copy = item
                            copy.properties.fadeIn = 0
                            copy.properties.fadeOut = 0
                            appState.updateItem(copy)
                        })
            .offset(x: CGFloat(item.startTime) * pps)
            .zIndex(appState.selectedItemIDs.contains(item.id) ? 2 : 1)
    }
    private var playhead: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 8))
                .foregroundStyle(Color(hex: 0xFF3B30))
                .offset(y: -1)
            Rectangle()
                .fill(Color(hex: 0xFF3B30))
                .frame(width: 1.5)
        }
        .frame(maxHeight: .infinity)
        .offset(x: CGFloat(appState.currentTime) * pps - 4)
        .allowsHitTesting(false)
    }

    private func snapLine(at seconds: Double) -> some View {
        Rectangle()
            .fill(Theme.accent.opacity(0.75))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .offset(x: CGFloat(seconds) * pps)
            .allowsHitTesting(false)
    }

    // MARK: - 拖入素材

    private func dropIndicator(at seconds: Double, track: Int?) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .background(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear.frame(height: 22)
                ForEach(0..<5, id: \.self) { index in
                    Rectangle()
                        .fill(index == track ? Theme.accent.opacity(0.16) : Color.clear)
                        .frame(height: trackHeight)
                }
                Spacer(minLength: 0)
            }
        }
        .offset(x: CGFloat(seconds) * pps)
        .allowsHitTesting(false)
    }

    private func handleDrop(urls: [URL], time: Double, trackIndex: Int) {
        guard !urls.isEmpty else { return }
        // 落点决定素材去哪一层：V2 = 画中画，A1/A2 = 音乐 / 配音
        var audioLaneHint: Int?
        var videoLaneHint: Int?
        switch trackIndex {
        case 1: videoLaneHint = 1
        case 2: audioLaneHint = 0
        case 3: audioLaneHint = 1
        default: break
        }
        Task {
            for url in urls {
                await appState.insertMedia(url: url,
                                           at: time,
                                           audioLaneHint: audioLaneHint,
                                           videoLaneHint: videoLaneHint)
            }
        }
    }

    // MARK: - 播放头拖动

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let time = max(0, Double(value.location.x / pps))
                appState.seek(to: time)
            }
    }

    // MARK: - 拖拽逻辑

    private func handleDrag(_ item: TimelineItem,
                            mode: DragMode,
                            translation: CGSize,
                            ended: Bool) {
        if ended {
            dragOrigin = nil
            dragMode = .move
            snapTime = nil
            dragGroupIDs = []
            dragGroupStarts = [:]
            return
        }

        if dragOrigin?.id != item.id || dragMode != mode {
            dragOrigin = item
            dragMode = mode
            prepareDragBounds(for: item, mode: mode)
            // 一次拖拽只记一个撤销点
            appState.beginEdit()
        }
        guard let origin = dragOrigin else { return }

        if !appState.selectedItemIDs.contains(item.id) {
            appState.select(item.id, additive: false)
        }

        let delta = Double(translation.width / pps)

        // 垂直拖动切换轨道层（音频 A1/A2），多选时不换层
        var working = origin
        let laneCount = TimelineItem.laneCount(for: origin.trackKind)
        if mode == .move, laneCount > 1, dragGroupIDs.count <= 1 {
            let laneDelta = Int((translation.height / trackHeight).rounded())
            let target = min(max(0, origin.trackLane + laneDelta), laneCount - 1)
            if target != origin.trackLane,
               appState.laneIsFree(origin.trackKind,
                                   lane: target,
                                   start: origin.startTime,
                                   end: origin.endTime) {
                working.trackLane = target
            }
        }

        let neighbors = appState.neighbors(of: working)
        let points = snapCandidates(excludingIDs: dragGroupIDs.isEmpty ? [origin.id] : dragGroupIDs)
        let threshold = Double(8 / pps)
        var updated = working
        var snapped: Double?

        switch mode {
        case .move:
            var start = working.startTime + delta

            if let s = nearest(start, in: points, threshold: threshold) {
                start = s
                snapped = s
            } else if let s = nearest(start + working.duration, in: points, threshold: threshold) {
                start = s - working.duration
                snapped = s
            }

            var appliedDelta = start - origin.startTime
            appliedDelta = min(max(appliedDelta, dragLowerDelta), dragUpperDelta)
            if let s = snapped, abs(appliedDelta - (s - origin.startTime)) > 0.02 {
                snapped = nil
            }

            snapTime = snapped

            if dragGroupIDs.count > 1 {
                // 整组按同一偏移移动（起点取自拖拽开始时的快照，避免累加漂移）
                for (id, originalStart) in dragGroupStarts {
                    guard var copy = appState.timeline.first(where: { $0.id == id }) else { continue }
                    copy.startTime = max(0, originalStart + appliedDelta)
                    appState.updateItem(copy)
                }
                return
            }

            updated.startTime = max(0, origin.startTime + appliedDelta)
            appState.updateItem(updated)

        case .trimStart:
            let minStart = max(neighbors.prevEnd, working.startTime - working.sourceStart)
            let maxStart = working.endTime - minClipDuration
            var start = min(max(working.startTime + delta, minStart), maxStart)

            if let s = nearest(start, in: points, threshold: threshold) {
                start = min(max(s, minStart), maxStart)
                snapped = s
            }

            let shift = start - working.startTime
            updated.startTime = start
            updated.duration = max(minClipDuration, working.duration - shift)
            updated.sourceStart = max(0, working.sourceStart + shift)

            snapTime = snapped
            appState.updateItem(updated)

        case .trimEnd:
            let maxEnd = min(neighbors.nextStart, working.endTime + maxExtraTail(working))
            let minEnd = working.startTime + minClipDuration
            var end = min(max(working.endTime + delta, minEnd), maxEnd)

            if let s = nearest(end, in: points, threshold: threshold) {
                end = min(max(s, minEnd), maxEnd)
                snapped = s
            }

            updated.duration = max(minClipDuration, end - working.startTime)

            snapTime = snapped
            appState.updateItem(updated)
        }
    }

    /// 拖上边缘的淡入淡出手柄。
    ///
    /// 起点取按下时的快照、位移每帧从 0 重算，所以拖过头再拖回来能原路返回，
    /// 不会因为逐帧累加而漂移。
    private func handleFade(_ item: TimelineItem,
                            edge: FadeEdge,
                            translation: CGSize,
                            ended: Bool) {
        if ended {
            fadeOrigin = nil
            fadeEdge = nil
            fadeHint = nil
            fadeHintEdge = nil
            return
        }

        if fadeOrigin?.id != item.id || fadeEdge != edge {
            fadeOrigin = item
            fadeEdge = edge
            appState.beginEdit()
        }
        guard let origin = fadeOrigin else { return }

        if !appState.selectedItemIDs.contains(item.id) {
            appState.select(item.id, additive: false)
        }

        let other = edge == .fadeIn ? origin.properties.fadeOut : origin.properties.fadeIn
        let start = edge == .fadeIn ? origin.properties.fadeIn : origin.properties.fadeOut
        let value = FadeGeometry.value(origin: start,
                                       translation: translation.width,
                                       pps: pps,
                                       duration: origin.duration,
                                       other: other,
                                       edge: edge)

        var copy = appState.timeline.first(where: { $0.id == item.id }) ?? origin
        if edge == .fadeIn {
            copy.properties.fadeIn = value
        } else {
            copy.properties.fadeOut = value
        }
        appState.updateItem(copy)
        fadeHintEdge = edge
        fadeHint = String(format: "%.2f s", value)
    }

    /// 拖拽开始时算好整组可移动的偏移范围，避免多选时互相挤压
    private func prepareDragBounds(for item: TimelineItem, mode: DragMode) {
        let inSelection = appState.selectedItemIDs.contains(item.id)
        dragGroupIDs = (mode == .move && inSelection) ? appState.selectedItemIDs : [item.id]

        guard mode == .move else {
            dragLowerDelta = -.greatestFiniteMagnitude
            dragUpperDelta = .greatestFiniteMagnitude
            return
        }

        let snapshot = appState.timeline
        dragGroupStarts = Dictionary(uniqueKeysWithValues:
            snapshot.filter { dragGroupIDs.contains($0.id) }.map { ($0.id, $0.startTime) })
        var lower = -Double.greatestFiniteMagnitude
        var upper = Double.greatestFiniteMagnitude

        for member in snapshot where dragGroupIDs.contains(member.id) {
            let siblings = snapshot.filter {
                $0.id != member.id
                    && !dragGroupIDs.contains($0.id)
                    && $0.trackKind == member.trackKind
                    && $0.trackLane == member.trackLane
            }
            let prevEnd = siblings.filter { $0.endTime <= member.startTime + 0.001 }
                .map(\.endTime)
                .max() ?? 0
            let nextStart = siblings.filter { $0.startTime >= member.startTime - 0.001 }
                .map(\.startTime)
                .min() ?? .greatestFiniteMagnitude

            lower = max(lower, prevEnd - member.startTime)
            lower = max(lower, -member.startTime)
            if nextStart.isFinite {
                upper = min(upper, nextStart - member.duration - member.startTime)
            }
        }

        if lower > upper { upper = lower }
        dragLowerDelta = lower
        dragUpperDelta = upper
    }

    private func nearest(_ value: Double, in points: [Double], threshold: Double) -> Double? {
        var best: Double?
        var bestDistance = threshold
        for point in points {
            let distance = abs(value - point)
            if distance < bestDistance {
                bestDistance = distance
                best = point
            }
        }
        return best
    }

    private func snapCandidates(excludingIDs ids: Set<UUID>) -> [Double] {
        var points: [Double] = [0, appState.currentTime, appState.totalDuration]
        for other in appState.timeline where !ids.contains(other.id) {
            points.append(other.startTime)
            points.append(other.endTime)
        }
        return points
    }

    private func maxExtraTail(_ item: TimelineItem) -> Double {
        guard let assetDuration = appState.assetDuration(for: item) else { return 3600 }
        return max(0, assetDuration - item.sourceStart - item.duration)
    }

    // MARK: - 切割

    private func splitAtPlayhead() {
        let time = appState.currentTime
        guard let item = appState.selectedItem ?? appState.videoClips.first(where: {
            time > $0.startTime && time < $0.endTime
        }) else {
            appState.notify("把播放头放在片段中间再切割")
            return
        }
        guard time > item.startTime + minClipDuration, time < item.endTime - minClipDuration else {
            appState.notify("播放头太靠近片段边缘")
            return
        }

        var left = item
        left.duration = time - item.startTime

        var right = item
        right.id = UUID()
        right.startTime = time
        right.duration = item.duration - left.duration
        right.sourceStart = item.sourceStart + left.duration
        right.transition = .none

        appState.beginEdit()
        appState.updateItem(left)
        appState.timeline.append(right)
        appState.selectedItemID = right.id
        appState.notify("已切割片段")
    }
}

// MARK: - 拖入素材的落点代理

private struct TimelineDropDelegate: DropDelegate {
    let pps: CGFloat
    let trackHeight: CGFloat
    let rulerHeight: CGFloat
    @Binding var dropTime: Double?
    @Binding var dropTrack: Int?
    let onDrop: ([URL], Double, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) {
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        dropTime = nil
        dropTrack = nil
    }

    private func update(_ info: DropInfo) {
        dropTime = max(0, Double(info.location.x / max(1, pps)))
        let y = info.location.y - rulerHeight
        let index = Int(y / max(1, trackHeight))
        // 轨道行数：V1 / V2 / A1 / A2 / S1
        dropTrack = min(max(0, index), 4)
    }

    func performDrop(info: DropInfo) -> Bool {
        update(info)
        let time = dropTime ?? 0
        let track = dropTrack ?? 0
        dropTime = nil
        dropTrack = nil

        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }

        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = Self.resolve(item) else { return }
                DispatchQueue.main.async {
                    onDrop([url], time, track)
                }
            }
        }
        return true
    }

    private static func resolve(_ item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = item as? String, let url = URL(string: string) { return url }
        return nil
    }
}

// MARK: - 标尺

struct RulerView: View {
    let pps: CGFloat
    let seconds: Int

    var body: some View {
        Canvas { context, size in
            for second in 0...max(seconds, 1) {
                let x = CGFloat(second) * pps
                guard x <= size.width else { break }
                let major = second % 5 == 0
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: major ? 12 : 6))
                context.stroke(path,
                               with: .color(major ? Color.black.opacity(0.2) : Color.black.opacity(0.1)),
                               lineWidth: 1)
                if major {
                    context.draw(
                        Text("\(second)s")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.text3),
                        at: CGPoint(x: x + 3, y: 4),
                        anchor: .topLeading
                    )
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

// MARK: - 片段

struct ClipView: View {
    let item: TimelineItem
    let width: CGFloat
    let selected: Bool
    /// 一张缩略图的目标宽度（跟随时间线缩放）
    var tileWidth: CGFloat = 52
    /// 入场转场的实际状态，决定角标颜色
    var transitionStatus: TransitionStatus = .unset
    /// 转场重叠区间在时间线上的像素宽度
    var transitionWidth: CGFloat = 0
    /// 每秒像素数：淡入淡出手柄靠它把「秒」换算成「像素」
    var pps: CGFloat = 26
    /// 正在拖淡入 / 淡出手柄时显示的数值气泡
    var fadeHintEdge: FadeEdge?
    var fadeHintText: String?

    var onSelect: () -> Void
    var onMove: (CGSize, Bool) -> Void
    var onTrimStart: (CGSize, Bool) -> Void
    var onTrimEnd: (CGSize, Bool) -> Void
    var onDuplicate: () -> Void = {}
    var onDelete: () -> Void = {}
    /// 音频片段才用得上：按配音生成闪避包络
    var onAutoDuck: () -> Void = {}
    /// 拖片段上边缘的淡入 / 淡出手柄
    var onFadeIn: (CGSize, Bool) -> Void = { _, _ in }
    var onFadeOut: (CGSize, Bool) -> Void = { _, _ in }
    var onClearFade: () -> Void = {}

    @State private var hovering = false

    /// 波形桶数随宽度变化，按 8 的倍数取整，减少缓存碎片
    private var waveBuckets: Int {
        let raw = Int(width / 4)
        let rounded = max(16, min(96, (raw / 8) * 8))
        return rounded
    }

    // MARK: 淡入淡出

    /// 字幕没有淡入淡出（烧录时按整句出现），其余类型都能拖
    private var supportsFade: Bool { item.type != .subtitle }

    /// 有关键帧时整段曲线交给关键帧，淡入淡出不再叠加
    private var fadeKeyed: Bool {
        item.type == .audio
            ? !item.properties.keyframes(for: .volume).isEmpty
            : !item.properties.keyframes(for: .opacity).isEmpty
    }

    /// 入场转场生效时淡入由转场接管，拖了也没用
    private var fadeInDimmed: Bool {
        !FadeGeometry.isEffective(edge: .fadeIn,
                                  inTransitionActive: transitionStatus.isActive,
                                  hasOpacityKeyframes: fadeKeyed)
    }

    private var fadeOutDimmed: Bool { fadeKeyed }

    private var fadeOverlay: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fin = min(CGFloat(max(0, item.properties.fadeIn)) * pps, w)
            let fout = min(CGFloat(max(0, item.properties.fadeOut)) * pps, w)
            ZStack(alignment: .topLeading) {
                if fin > 1 {
                    FadeWedge(start: 0, end: fin, rising: true)
                        .fill(Color.black.opacity(fadeInDimmed ? 0.10 : 0.30))
                    FadeRamp(start: 0, end: fin, rising: true)
                        .stroke(Color.white.opacity(fadeInDimmed ? 0.35 : 0.85),
                                style: StrokeStyle(lineWidth: 1.2,
                                                   dash: fadeInDimmed ? [3, 3] : []))
                }
                if fout > 1 {
                    FadeWedge(start: w - fout, end: w, rising: false)
                        .fill(Color.black.opacity(fadeOutDimmed ? 0.10 : 0.30))
                    FadeRamp(start: w - fout, end: w, rising: false)
                        .stroke(Color.white.opacity(fadeOutDimmed ? 0.35 : 0.85),
                                style: StrokeStyle(lineWidth: 1.2,
                                                   dash: fadeOutDimmed ? [3, 3] : []))
                }
            }
        }
        .allowsHitTesting(false)
    }

    var body: some View {
        HStack(spacing: 4) {
            // 片段很窄时把图标让出来给文字，否则只剩一个省略号
            if width >= 64 {
                Image(systemName: item.type.icon)
                    .font(.system(size: 9, weight: .medium))
            }
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        // 波形是浅色，文字压上去容易糊，补一层暗影保证可读
        .shadow(color: .black.opacity(0.45), radius: 2, y: 0.5)
        .padding(.horizontal, 6)
        .frame(width: width, height: 36, alignment: .leading)
        .background(
            Theme.clipGradient(for: item.type)
                .overlay {
                    if item.type == .audio, let url = item.assetURL {
                        FileWaveform(url: url,
                                     buckets: waveBuckets,
                                     color: Color.white.opacity(0.42),
                                     minBarHeight: 1,
                                     spacing: 1,
                                     sourceStart: item.sourceStart,
                                     duration: item.duration * max(0.1, item.properties.speed))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    } else if item.type == .video || item.type == .aiGenerated,
                              let url = item.assetURL {
                        ClipThumbnailStrip(url: url,
                                           sourceStart: item.sourceStart,
                                           duration: item.duration,
                                           speed: item.properties.speed,
                                           tileWidth: tileWidth)
                            .allowsHitTesting(false)
                            .overlay {
                                // 压一层暗色，保证白色片段名在亮画面上也看得清
                                LinearGradient(colors: [Color.black.opacity(0.42),
                                                        Color.black.opacity(0.12)],
                                               startPoint: .leading,
                                               endPoint: .trailing)
                            }
                    }
                }
        )
        .overlay {
            // 衰减区画在波形之上、裁剪之内，一眼看出这段从静音升上来
            if supportsFade { fadeOverlay }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .topLeading) {
            if item.transition != .none {
                // 生效：白底 + 强调色图标（片段本身就是强调色，纯色圆点会糊在一起）
                // 未生效：橙色警示，跟属性面板的警告条同一套语言
                Image(systemName: transitionStatus.isProblem ? "exclamationmark" : item.transition.icon)
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(transitionStatus.isProblem ? Color.white
                                     : (transitionStatus.isActive ? Theme.accent : Color.white))
                    .padding(2.5)
                    .background(
                        Circle().fill(transitionStatus.isProblem
                                      ? Theme.warning
                                      : (transitionStatus.isActive ? Color.white.opacity(0.95)
                                         : Color.black.opacity(0.35)))
                    )
                    .padding(.leading, 3)
                    .padding(.top, 3)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            // 画中画片段挂个角标，扫一眼就知道它不占满画幅
            if item.isOverlay {
                HStack(spacing: 2) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 7, weight: .bold))
                    if width >= 88 {
                        Text("画中画")
                            .font(.system(size: 7.5, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 3.5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .padding(.trailing, 3)
                .padding(.top, 3)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            // 生效的转场把重叠区间画出来，一眼能看出「这两段在叠」
            if transitionWidth > 0, transitionStatus.isActive {
                ZStack(alignment: .leading) {
                    LinearGradient(colors: [Color.white.opacity(0.34), Color.white.opacity(0.02)],
                                   startPoint: .leading,
                                   endPoint: .trailing)
                    Rectangle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 1.5)
                }
                .frame(width: min(max(4, transitionWidth), width))
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            if selected || hovering {
                handle(isLeading: true)
            }
        }
        .overlay(alignment: .trailing) {
            if selected || hovering {
                handle(isLeading: false)
            }
        }
        // 淡入淡出手柄：抓上边缘调淡入淡出，抓中间仍是裁剪
        .overlay(alignment: .topLeading) {
            if supportsFade, selected || hovering, width >= 24 {
                fadeHandle(edge: .fadeIn, dimmed: fadeInDimmed)
                    .offset(x: FadeGeometry.handleX(item.properties.fadeIn, pps: pps, width: width) - 7,
                            y: -3)
            }
        }
        .overlay(alignment: .topLeading) {
            if supportsFade, selected || hovering, width >= 24 {
                fadeHandle(edge: .fadeOut, dimmed: fadeOutDimmed)
                    .offset(x: width - FadeGeometry.handleX(item.properties.fadeOut, pps: pps, width: width) - 7,
                            y: -3)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(selected ? Theme.accent : Color.white.opacity(0.45),
                        lineWidth: selected ? 2 : 1)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(selected ? 0.2 : 0.1), radius: selected ? 5 : 2, y: 1)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in onMove(value.translation, false) }
                .onEnded { value in onMove(value.translation, true) }
        )
        .simultaneousGesture(
            TapGesture().onEnded { onSelect() }
        )
        .contextMenu {
            Button("复制一份") {
                onDuplicate()
            }
            if item.type == .audio {
                Button("自动闪避…") {
                    onAutoDuck()
                }
            }
            if supportsFade, item.properties.fadeIn > 0.02 || item.properties.fadeOut > 0.02 {
                Button("清除淡入淡出") {
                    onClearFade()
                }
            }
            Button("删除") {
                onDelete()
            }
            Divider()
            Text(laneLabel)
        }
    }

    /// 淡入淡出手柄：7pt 圆点压在片段上边缘（让开文字那一行），命中区 14pt
    private func fadeHandle(edge: FadeEdge, dimmed: Bool) -> some View {
        Circle()
            .fill(dimmed ? Color.white.opacity(0.7) : Color.white)
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(Color.black.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
            .help(dimmed ? "\(edge.label)此刻不生效（关键帧或入场转场接管了）" : "拖动调整\(edge.label)")
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if edge == .fadeIn { onFadeIn(value.translation, false) }
                        else { onFadeOut(value.translation, false) }
                    }
                    .onEnded { value in
                        if edge == .fadeIn { onFadeIn(value.translation, true) }
                        else { onFadeOut(value.translation, true) }
                    }
            )
            .overlay(alignment: .top) {
                if let fadeHintText, fadeHintEdge == edge {
                    Text(fadeHintText)
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.accent))
                        .fixedSize()
                        .offset(y: -16)
                        .allowsHitTesting(false)
                }
            }
    }

    /// 右键菜单末尾显示这条片段在哪条轨道上，多选后也能确认自己点的是哪条
    private var laneLabel: String {
        switch item.trackKind {
        case .video: return item.isOverlay ? "V2 · 画中画" : "V1 · 主画面"
        case .audio: return "A\(item.trackLane + 1)"
        case .subtitle: return "S1 · 字幕"
        }
    }

    private func handle(isLeading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.white)
            .frame(width: 5, height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.black.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            .frame(width: 12, height: 36)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if isLeading {
                            onTrimStart(value.translation, false)
                        } else {
                            onTrimEnd(value.translation, false)
                        }
                    }
                    .onEnded { value in
                        if isLeading {
                            onTrimStart(value.translation, true)
                        } else {
                            onTrimEnd(value.translation, true)
                        }
                    }
            )
    }
}

// MARK: - 淡入淡出形状

/// 淡入淡出的「衰减区」：音量为 0 的那块三角，压暗之后一眼看出斜坡方向
private struct FadeWedge: Shape {
    var start: CGFloat
    var end: CGFloat
    /// true = 淡入（左下角升到右上角）
    var rising: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let h = rect.height
        path.move(to: CGPoint(x: start, y: 0))
        path.addLine(to: CGPoint(x: end, y: 0))
        path.addLine(to: CGPoint(x: rising ? start : end, y: h))
        path.closeSubpath()
        return path
    }
}

/// 淡入淡出的包络线本身（合成器里就是线性 ramp，画曲线会骗人）
private struct FadeRamp: Shape {
    var start: CGFloat
    var end: CGFloat
    var rising: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let h = rect.height
        if rising {
            path.move(to: CGPoint(x: start, y: h))
            path.addLine(to: CGPoint(x: end, y: 0))
        } else {
            path.move(to: CGPoint(x: start, y: 0))
            path.addLine(to: CGPoint(x: end, y: h))
        }
        return path
    }
}
