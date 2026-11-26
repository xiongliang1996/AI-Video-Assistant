//
//  EditorView.swift
//  编辑器：素材栏 + 预览台 + 播放控制
//

import SwiftUI
import AVKit
import AVFoundation
import QuartzCore

struct EditorView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar()
            HStack(spacing: 0) {
                MediaPanel()
                Rectangle().fill(Theme.line).frame(width: 1)
                VStack(spacing: 0) {
                    PreviewStage()
                    TransportBar()
                    TimelineView()
                }
                .background(Theme.canvas)
                Rectangle().fill(Theme.line).frame(width: 1)
                PropertiesPanel()
            }
        }
        .background(Theme.bg)
    }
}

// MARK: - 顶部工具栏

struct EditorToolbar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Text(appState.currentProject.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("· \(appState.timeline.count) 个片段 · \(formatTimecode(appState.totalDuration))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
            }

            Spacer()

            StatusPill(text: appState.currentProject.settings.resolution.label)
            StatusPill(text: "\(appState.currentProject.settings.fps) fps")

            Rectangle().fill(Theme.line2).frame(width: 1, height: 18)

            Button {
                appState.undo()
            } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(IconButtonStyle())
                .disabled(!appState.canUndo)
                .help("撤销 ⌘Z")

            Button {
                appState.redo()
            } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(IconButtonStyle())
                .disabled(!appState.canRedo)
                .help("重做 ⇧⌘Z")

            Button {
                appState.isPlaying.toggle()
            } label: {
                Label("预览", systemImage: "eye")
                    .font(.system(size: 12.5))
            }
            .buttonStyle(SoftButtonStyle())

            Button {
                appState.exportVideo()
            } label: {
                Label("导出视频", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(appState.processing != nil)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Theme.panel.opacity(0.72))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

// MARK: - 素材栏

struct MediaPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var tab = 0
    private let tabs = ["媒体", "文字", "转场", "特效"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("素材")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    appState.importMedia()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(IconButtonStyle(size: 24))
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            HStack(spacing: 2) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, title in
                    Button {
                        tab = index
                    } label: {
                        Text(title)
                            .font(.system(size: 11.5, weight: tab == index ? .medium : .regular))
                            .foregroundStyle(tab == index ? Theme.text : Theme.text2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(tab == index ? Theme.panel : Color.clear)
                                    .shadow(color: .black.opacity(tab == index ? 0.06 : 0), radius: 1, y: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.04)))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            searchBox

            if appState.mediaLibrary.isEmpty {
                EmptyHint(icon: "photo.on.rectangle.angled",
                          title: "还没有素材",
                          subtitle: "导入视频 / 音频 / 图片开始创作")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                              spacing: 8) {
                        ForEach(Array(appState.mediaLibrary.enumerated()), id: \.element.id) { index, asset in
                            MediaThumb(asset: asset, index: index)
                                .mediaSkim(asset, cornerRadius: 7)
                                .onTapGesture {
                                    appState.addToTimeline(asset)
                                }
                                .onDrag {
                                    NSItemProvider(contentsOf: asset.url) ?? NSItemProvider()
                                } preview: {
                                    MediaDragPreview(asset: asset, index: index)
                                }
                                .contextMenu {
                                    Button("加入时间线末尾") { appState.addToTimeline(asset) }
                                    Button("在访达中显示") {
                                        NSWorkspace.shared.activateFileViewerSelecting([asset.url])
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }

            HStack(spacing: 6) {
                Button {
                    appState.importMedia()
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                        .font(.system(size: 11.5))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SoftButtonStyle(height: 27))

                Button {
                    appState.notify("录音功能开发中")
                } label: {
                    Label("录音", systemImage: "mic")
                        .font(.system(size: 11.5))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SoftButtonStyle(height: 27))
            }
            .padding(10)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
        .frame(width: 236)
        .background(Theme.panel2)
    }

    private var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
            Text("搜索素材")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text3)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line2, lineWidth: 1))
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

struct MediaThumb: View {
    @ObservedObject var asset: MediaAsset
    let index: Int

    var body: some View {
        ZStack {
            if let image = asset.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.thumb(index)
            }

            LinearGradient(colors: [.clear, .black.opacity(0.42)],
                           startPoint: .center, endPoint: .bottom)

            VStack {
                HStack {
                    Image(systemName: asset.type.icon)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Text(asset.durationText)
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.black.opacity(0.5)))
                }
            }
            .padding(4)
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        )
        .help(asset.name)
    }
}

// MARK: - 预览台

struct PreviewStage: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        GeometryReader { geo in
            // 画框跟随项目画幅比例：竖屏项目以前被塞进 16:9 框里，画面只占中间一条
            let target = appState.currentProject.settings.resolution.size
            let availWidth = max(200, geo.size.width - 32)
            let availHeight = max(120, geo.size.height - 20)
            let scale = min(availWidth / max(1, target.width),
                            availHeight / max(1, target.height))
            let videoWidth = max(160, (target.width * scale).rounded())
            let videoHeight = max(90, (target.height * scale).rounded())

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(hex: 0x0B0C11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.black.opacity(0.4), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 16, y: 8)

                if let player = appState.previewPlayer {
                    PlayerLayerView(player: player)
                        .overlay(alignment: .topLeading) {
                            // 播放时藏起来：一边播一边拖没有意义，还挡画面
                            if !appState.isPlaying, let overlay = appState.activeOverlay {
                                PiPDragHandle(item: overlay,
                                              renderSize: appState.previewRenderSize,
                                              stageSize: CGSize(width: videoWidth, height: videoHeight))
                                    .id(overlay.id)
                            }
                        }
                } else {
                    TitleCard()
                }

                // 字幕覆盖层：与导出烧录用同一套样式参数
                if let subtitle = appState.activeSubtitle {
                    SubtitleOverlay(item: subtitle, stageHeight: videoHeight)
                        .padding(.bottom, videoHeight * CGFloat(min(max(subtitle.properties.textOffsetY, 0), 0.85)))
                }

                if let status = appState.previewStatus {
                    VStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(status)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                    )
                    .frame(maxHeight: .infinity)
                }

                VStack {
                    HStack {
                        Spacer()
                        Text("\(appState.currentProject.settings.resolution.rawValue) · \(appState.currentProject.settings.fps)fps")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.35)))
                    }
                    Spacer()
                }
                .padding(10)
                .allowsHitTesting(false)
            }
            .frame(width: videoWidth, height: videoHeight)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

// MARK: - 字幕覆盖层

struct SubtitleOverlay: View {
    let item: TimelineItem
    let stageHeight: CGFloat

    var body: some View {
        let p = item.properties
        let fs = max(6, CGFloat(p.fontSize) * stageHeight / SubtitleRenderer.designHeight)
        let stageWidth = stageHeight * 16 / 9

        Text(SubtitleRenderer.text(of: item))
            .font(.system(size: fs, weight: p.textBold ? .bold : .regular))
            .foregroundStyle(Color(hex: UInt32(max(0, p.textColorHex))))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, fs * 0.52)
            .padding(.vertical, fs * 0.26)
            .background(
                RoundedRectangle(cornerRadius: fs * 0.34, style: .continuous)
                    .fill(Color.black.opacity(min(max(p.textBoxOpacity, 0), 1)))
            )
            .frame(maxWidth: stageWidth * 0.92)
            .allowsHitTesting(false)
    }
}

// MARK: - 画中画拖拽层

/// 预览台上直接拖画中画：拖框内移动位置，拖四角改尺寸。
///
/// 拖动过程只改本地 `liveStyle`，松手才写回项目——每次写回都会重建预览合成，
/// 边拖边写会卡成一帧一帧的。这也和属性面板滑杆的既有做法一致。
struct PiPDragHandle: View {
    let item: TimelineItem
    let renderSize: CGSize
    let stageSize: CGSize

    @EnvironmentObject var appState: AppState
    @State private var startCenter: NormalizedPoint?
    @State private var resizeStart: CGRect?
    @State private var liveStyle: PiPStyle?
    @State private var hovering = false

    private var style: PiPStyle { item.properties.pip }
    private var isSelected: Bool { appState.selectedItemIDs.contains(item.id) }

    /// 素材真实宽高比；还没读到就先用 16:9 顶着，读到会重绘
    private var naturalSize: CGSize {
        appState.mediaSize(for: item.assetURL) ?? CGSize(width: 16, height: 9)
    }

    private var aspect: CGFloat {
        max(0.01, naturalSize.width / max(1, naturalSize.height))
    }

    /// 拖动中跟手、松手前不落盘的那份样式
    private var currentStyle: PiPStyle { liveStyle ?? style }

    /// 当前画中画在画幅里的矩形
    private var currentRect: CGRect {
        guard renderSize.width > 1, renderSize.height > 1 else { return .zero }
        return CompositionBuilder.pipRect(naturalSize: naturalSize,
                                          renderSize: renderSize,
                                          style: currentStyle)
    }

    var body: some View {
        let fitted = PiPGeometry.fittedRect(contentSize: renderSize,
                                            in: CGRect(origin: .zero, size: stageSize))
        let viewRect = PiPGeometry.viewRect(currentRect, renderSize: renderSize, fitted: fitted)
        let emphasized = hovering || isSelected

        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.07 : 0.001))

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.accent.opacity(emphasized ? 0.95 : 0.45),
                              style: StrokeStyle(lineWidth: emphasized ? 1.6 : 1.1,
                                                 dash: emphasized ? [6, 4] : [4, 5]))

            cornerHandles(fitted: fitted, visible: emphasized)
        }
        .frame(width: max(24, viewRect.width), height: max(16, viewRect.height))
        .offset(x: viewRect.minX, y: viewRect.minY)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(moveGesture(fitted: fitted))
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { resetToPreset() }
        )
        .help("拖动移动位置，拖四角改尺寸，双击回到九宫格")
        .task(id: item.assetURL) { appState.requestMediaSize(for: item.assetURL) }
    }

    private func cornerHandles(fitted: CGRect, visible: Bool) -> some View {
        GeometryReader { g in
            let side: CGFloat = 7
            let hit: CGFloat = 22
            ForEach(PiPCorner.allCases, id: \.self) { corner in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: side, height: side)
                    // 点击区比视觉大得多：7pt 的方块几乎抓不住
                    .frame(width: hit, height: hit)
                    .contentShape(Rectangle())
                    .position(x: corner.isLeading ? 0 : g.size.width,
                              y: corner.isTop ? 0 : g.size.height)
                    .opacity(visible ? 1 : 0.001)
                    .gesture(resizeGesture(corner, fitted: fitted))
            }
        }
    }

    private func moveGesture(fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard fitted.width > 1, fitted.height > 1,
                      renderSize.width > 1, renderSize.height > 1 else { return }

                // 第一次回调时记下按下瞬间的中心点，后面都按「起点 + 累计位移」算，
                // 不用每帧累加，避免浮点漂移
                if startCenter == nil {
                    let rect = currentRect
                    startCenter = NormalizedPoint(x: Double(rect.midX / renderSize.width),
                                                  y: Double(rect.midY / renderSize.height))
                }
                guard let center0 = startCenter else { return }

                let size = currentRect.size
                let center = NormalizedPoint(
                    x: center0.x + Double(value.translation.width / fitted.width),
                    y: center0.y + Double(value.translation.height / fitted.height))

                var origin = PiPGeometry.origin(centeredAt: center,
                                                size: size,
                                                renderSize: renderSize)
                origin = PiPGeometry.snapToEdges(origin,
                                                 size: size,
                                                 renderSize: renderSize,
                                                 margin: style.margin)
                origin = PiPGeometry.clampOrigin(origin,
                                                 size: size,
                                                 renderSize: renderSize,
                                                 margin: style.margin)

                var next = style
                next.freeOrigin = origin
                liveStyle = next
            }
            .onEnded { _ in
                startCenter = nil
                commitLiveStyle()
            }
    }

    private func resizeGesture(_ corner: PiPCorner, fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard fitted.width > 1, fitted.height > 1,
                      renderSize.width > 1, renderSize.height > 1 else { return }

                if resizeStart == nil { resizeStart = currentRect }
                guard let start = resizeStart else { return }

                // 视图位移换算回画幅像素，再交给纯函数算新尺寸
                let translation = CGSize(
                    width: value.translation.width / fitted.width * renderSize.width,
                    height: value.translation.height / fitted.height * renderSize.height)

                liveStyle = PiPGeometry.resize(rect: start,
                                               corner: corner,
                                               translation: translation,
                                               renderSize: renderSize,
                                               margin: style.margin,
                                               aspect: aspect,
                                               style: style)
            }
            .onEnded { _ in
                resizeStart = nil
                commitLiveStyle()
            }
    }

    private func commitLiveStyle() {
        guard let next = liveStyle else { return }
        liveStyle = nil
        guard next != style else { return }
        var copy = item
        copy.properties.pip = next
        appState.updateItem(copy, recordUndo: true)
    }

    private func resetToPreset() {
        guard style.freeOrigin != nil else { return }
        var copy = item
        copy.properties.pip.freeOrigin = nil
        appState.updateItem(copy, recordUndo: true)
        appState.notify("画中画回到「\(style.position.label)」")
    }
}

// MARK: - AVPlayer 图层（不带系统播放控件，跟自定义控制条联动）

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }

    final class PlayerNSView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.frame = bounds
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

struct TitleCard: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.stageGradient)

            RadialGradient(colors: [Theme.accent.opacity(0.55), .clear],
                           center: .init(x: 0.22, y: 0.2),
                           startRadius: 4, endRadius: 320)

            RadialGradient(colors: [Color(hex: 0xFF7AC0, alpha: 0.42), .clear],
                           center: .init(x: 0.82, y: 0.8),
                           startRadius: 4, endRadius: 280)

            VStack(spacing: 10) {
                Text("AI VIDEO ASSISTANT")
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(4)
                    .foregroundStyle(.white.opacity(0.5))
                Text("品牌短片 2026")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                Text("用 AI 讲一个好故事")
                    .font(.system(size: 11.5))
                    .kerning(1.5)
                    .foregroundStyle(.white.opacity(0.68))
            }

            RoundedRectangle(cornerRadius: 4)
                .stroke(.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .padding(24)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - 播放控制

struct TransportBar: View {
    @EnvironmentObject var appState: AppState

    private let ticker = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            Button {
                appState.seek(to: 0)
            } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 11))
            }
            .buttonStyle(IconButtonStyle(size: 26))

            Button {
                appState.togglePlayback()
            } label: {
                ZStack {
                    Circle().fill(Theme.panel)
                    Circle().stroke(Theme.line, lineWidth: 1)
                    Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .offset(x: appState.isPlaying ? 0 : 0.5)
                }
                .frame(width: 28, height: 28)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            }
            .buttonStyle(.plain)

            Button {
                appState.seek(to: appState.currentTime - 1)
            } label: {
                Image(systemName: "backward.frame.fill").font(.system(size: 11))
            }
            .buttonStyle(IconButtonStyle(size: 26))

            HStack(spacing: 3) {
                Text(formatTimecode(appState.currentTime))
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                Text("/ \(formatTimecode(appState.totalDuration))")
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text3)
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.1")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                Slider(value: .constant(0.72), in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 64)
                    .tint(Theme.text2)
            }

            StatusPill(text: "1.0×")
                .frame(height: 24)

            Button {} label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10.5))
            }
            .buttonStyle(IconButtonStyle(size: 26))
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .onReceive(ticker) { _ in
            // 有真实预览时由播放器驱动时间码；没有素材时退化为虚拟播放
            guard appState.isPlaying, appState.previewPlayer == nil else { return }
            let next = appState.currentTime + 0.05
            if next > max(appState.totalDuration, 1) {
                appState.currentTime = 0
            } else {
                appState.currentTime = next
            }
        }
    }
}
