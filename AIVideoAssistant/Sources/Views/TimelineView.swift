//
//  TimelineView.swift
//  多轨时间线：拖拽移动 / 边缘裁剪 / 吸附 / 缩放 / 拖动播放头
//

import SwiftUI
import AppKit

private enum DragMode {
    case move, trimStart, trimEnd
}

struct TimelineView: View {
    @EnvironmentObject var appState: AppState

    @State private var zoom: CGFloat = 1.0
    @State private var dragOrigin: TimelineItem?
    @State private var dragMode: DragMode = .move
    @State private var snapTime: Double?

    private let basePPS: CGFloat = 26
    private let trackHeight: CGFloat = 46
    private let headWidth: CGFloat = 78
    private let minClipDuration: Double = 0.2

    private var pps: CGFloat { basePPS * zoom }

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

                            track(for: appState.videoClips)
                            track(for: appState.audioClips)
                            track(for: appState.subtitleClips)
                        }

                        if let snapTime {
                            snapLine(at: snapTime)
                        }
                        playhead
                    }
                    .frame(width: canvasWidth, alignment: .topLeading)
                }
            }
        }
        .frame(height: 206)
        .background(Theme.panel2)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
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
                if let item = appState.selectedItem {
                    var copy = item
                    copy.transition = copy.transition == .none ? .crossDissolve : .none
                    appState.updateItem(copy)
                }
            } label: { Image(systemName: "circle.lefthalf.filled") }
                .buttonStyle(IconButtonStyle(active: (appState.selectedItem?.transition ?? TransitionType.none) != TransitionType.none,
                                             size: 24))
                .help("给所选片段加入/取消转场")

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
                Slider(value: $zoom, in: 0.5...3.0)
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
            head("A1", "音频")
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

    private func track(for items: [TimelineItem]) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.clear)
                .frame(height: trackHeight)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 1)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    appState.selectedItemID = nil
                }

            ForEach(items) { item in
                clip(item)
            }
        }
        .frame(height: trackHeight)
    }

    private func clip(_ item: TimelineItem) -> some View {
        let width = max(28, CGFloat(item.duration) * pps)
        return ClipView(item: item,
                        width: width,
                        selected: appState.selectedItemID == item.id,
                        onSelect: {
                            appState.selectedItemID = item.id
                        },
                        onMove: { translation, ended in
                            handleDrag(item, mode: .move, translation: translation, ended: ended)
                        },
                        onTrimStart: { translation, ended in
                            handleDrag(item, mode: .trimStart, translation: translation, ended: ended)
                        },
                        onTrimEnd: { translation, ended in
                            handleDrag(item, mode: .trimEnd, translation: translation, ended: ended)
                        })
            .offset(x: CGFloat(item.startTime) * pps)
            .zIndex(appState.selectedItemID == item.id ? 2 : 1)
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
                            translation: CGFloat,
                            ended: Bool) {
        if ended {
            dragOrigin = nil
            dragMode = .move
            snapTime = nil
            return
        }

        if dragOrigin?.id != item.id || dragMode != mode {
            dragOrigin = item
            dragMode = mode
        }
        guard let origin = dragOrigin else { return }

        appState.selectedItemID = item.id

        let delta = Double(translation / pps)
        let neighbors = appState.neighbors(of: origin)
        let points = snapCandidates(excluding: origin)
        let threshold = Double(8 / pps)
        var updated = origin
        var snapped: Double?

        switch mode {
        case .move:
            let lower = max(0, neighbors.prevEnd)
            let upper: Double = neighbors.nextStart.isFinite
                ? max(lower, neighbors.nextStart - origin.duration)
                : .greatestFiniteMagnitude

            var start = origin.startTime + delta

            if let s = nearest(start, in: points, threshold: threshold) {
                start = s
                snapped = s
            } else if let s = nearest(start + origin.duration, in: points, threshold: threshold) {
                start = s - origin.duration
                snapped = s
            }

            start = min(max(start, lower), upper)
            if let s = snapped,
               abs(start - s) > 0.02,
               abs(start + origin.duration - s) > 0.02 {
                snapped = nil
            }

            updated.startTime = start

        case .trimStart:
            let minStart = max(neighbors.prevEnd, origin.startTime - origin.sourceStart)
            let maxStart = origin.endTime - minClipDuration
            var start = min(max(origin.startTime + delta, minStart), maxStart)

            if let s = nearest(start, in: points, threshold: threshold) {
                start = min(max(s, minStart), maxStart)
                snapped = s
            }

            let shift = start - origin.startTime
            updated.startTime = start
            updated.duration = max(minClipDuration, origin.duration - shift)
            updated.sourceStart = max(0, origin.sourceStart + shift)

        case .trimEnd:
            let maxEnd = min(neighbors.nextStart, origin.endTime + maxExtraTail(origin))
            let minEnd = origin.startTime + minClipDuration
            var end = min(max(origin.endTime + delta, minEnd), maxEnd)

            if let s = nearest(end, in: points, threshold: threshold) {
                end = min(max(s, minEnd), maxEnd)
                snapped = s
            }

            updated.duration = max(minClipDuration, end - origin.startTime)
        }

        snapTime = snapped
        appState.updateItem(updated)
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

    private func snapCandidates(excluding item: TimelineItem) -> [Double] {
        var points: [Double] = [0, appState.currentTime, appState.totalDuration]
        for other in appState.timeline where other.id != item.id {
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

        appState.updateItem(left)
        appState.timeline.append(right)
        appState.selectedItemID = right.id
        appState.notify("已切割片段")
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

    var onSelect: () -> Void
    var onMove: (CGFloat, Bool) -> Void
    var onTrimStart: (CGFloat, Bool) -> Void
    var onTrimEnd: (CGFloat, Bool) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: item.type.icon)
                .font(.system(size: 9, weight: .medium))
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(width: width, height: 36, alignment: .leading)
        .background(Theme.clipGradient(for: item.type))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .topLeading) {
            if item.transition != .none {
                Image(systemName: item.transition.icon)
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(2.5)
                    .background(Circle().fill(Color.black.opacity(0.35)))
                    .padding(.leading, 3)
                    .padding(.top, 3)
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
                .onChanged { value in onMove(value.translation.width, false) }
                .onEnded { value in onMove(value.translation.width, true) }
        )
        .simultaneousGesture(
            TapGesture().onEnded { onSelect() }
        )
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
                            onTrimStart(value.translation.width, false)
                        } else {
                            onTrimEnd(value.translation.width, false)
                        }
                    }
                    .onEnded { value in
                        if isLeading {
                            onTrimStart(value.translation.width, true)
                        } else {
                            onTrimEnd(value.translation.width, true)
                        }
                    }
            )
    }
}
