//
//  EditorView.swift
//  编辑器：素材栏 + 预览台 + 播放控制
//

import SwiftUI
import AVKit
import AVFoundation

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

            Button {} label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(IconButtonStyle())
                .help("撤销")

            Button {} label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(IconButtonStyle())
                .help("重做")

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
                                .onTapGesture {
                                    appState.addToTimeline(asset)
                                }
                                .contextMenu {
                                    Button("加入时间线") { appState.addToTimeline(asset) }
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
    @State private var player: AVPlayer?

    var body: some View {
        GeometryReader { geo in
            let height = min(geo.size.height - 20, (geo.size.width - 32) * 9 / 16)
            let width = height * 16 / 9

            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(hex: 0x0B0C11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.black.opacity(0.4), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 16, y: 8)

                if let player {
                    VideoPlayer(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else {
                    TitleCard()
                }
            }
            .frame(width: max(200, width), height: max(120, height))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .onAppear { refreshPlayer() }
        .onChange(of: appState.selectedItemID) { _ in refreshPlayer() }
    }

    private func refreshPlayer() {
        if let item = appState.selectedItem,
           let url = item.assetURL,
           MediaType.detect(from: url) != .audio {
            player = AVPlayer(url: url)
        } else {
            player = nil
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
                appState.currentTime = 0
            } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 11))
            }
            .buttonStyle(IconButtonStyle(size: 26))

            Button {
                appState.isPlaying.toggle()
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
                appState.currentTime = max(0, appState.currentTime - 1)
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
            guard appState.isPlaying else { return }
            let next = appState.currentTime + 0.05
            appState.currentTime = next > max(appState.totalDuration, 1) ? 0 : next
        }
    }
}
