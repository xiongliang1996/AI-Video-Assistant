//
//  AppState.swift
//  全局状态
//

import SwiftUI
import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

enum Panel: String, CaseIterable, Identifiable {
    case editor = "编辑器"
    case generate = "AI 生视频"
    case tts = "AI 配音"
    case subtitle = "AI 字幕"
    case library = "媒体库"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .editor: return "film"
        case .generate: return "wand.and.stars"
        case .tts: return "speaker.wave.2"
        case .subtitle: return "captions.bubble"
        case .library: return "photo.on.rectangle.angled"
        }
    }
}

struct ProcessingState {
    var title: String
    var message: String
    var progress: Double
}

final class AppState: ObservableObject {
    static let shared = AppState()

    // 项目
    @Published var projects: [VideoProject] = []
    @Published var currentProject: VideoProject

    // 导航
    @Published var selectedPanel: Panel = .editor
    @Published var showingSettings = false

    // 素材与时间线
    @Published var mediaLibrary: [MediaAsset] = []
    @Published var timeline: [TimelineItem] = []
    @Published var selectedItemID: UUID?

    // 播放
    @Published var currentTime: Double = 0
    @Published var isPlaying = false

    // 配置
    @Published var aiConfig = AIConfig()

    // 反馈
    @Published var processing: ProcessingState?
    @Published var toast: String?
    @Published var errorMessage: String?

    private var toastWorkItem: DispatchWorkItem?

    private init() {
        self.currentProject = VideoProject(name: "品牌短片 v3")
        self.projects = [currentProject]
        self.aiConfig = AIConfigManager.shared.load()
        seedDemoTimelineIfNeeded()
    }

    // MARK: - 派生状态

    var selectedItem: TimelineItem? {
        guard let id = selectedItemID else { return nil }
        return timeline.first { $0.id == id }
    }

    var totalDuration: Double {
        timeline.map(\.endTime).max() ?? 0
    }

    var videoClips: [TimelineItem] {
        timeline.filter { $0.type == .video || $0.type == .aiGenerated }.sorted { $0.startTime < $1.startTime }
    }

    var audioClips: [TimelineItem] {
        timeline.filter { $0.type == .audio }.sorted { $0.startTime < $1.startTime }
    }

    var subtitleClips: [TimelineItem] {
        timeline.filter { $0.type == .subtitle || $0.type == .text }.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - 项目

    func createProject(named name: String = "未命名项目") {
        let project = VideoProject(name: name)
        projects.append(project)
        currentProject = project
        timeline = []
        selectedItemID = nil
        currentTime = 0
        notify("已创建项目「\(name)」")
    }

    func selectProject(_ project: VideoProject) {
        currentProject = project
        selectedPanel = .editor
    }

    // MARK: - 素材

    func importMedia() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .audio, .image, .mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK else { return }
        addMedia(urls: panel.urls)
    }

    func addMedia(urls: [URL]) {
        for url in urls {
            let asset = MediaAsset(url: url)
            mediaLibrary.append(asset)
            Task { await asset.loadMetadata() }
        }
        notify("已导入 \(urls.count) 个素材")
    }

    func addGeneratedMedia(url: URL, duration: Double, name: String) {
        let asset = MediaAsset(url: url)
        mediaLibrary.append(asset)
        Task { await asset.loadMetadata() }

        let start = totalDuration
        var item = TimelineItem(type: .aiGenerated,
                                name: name,
                                startTime: start,
                                duration: max(1, duration),
                                assetURL: url)
        item.assetID = asset.id
        timeline.append(item)
        selectedItemID = item.id
        notify("已加入时间线")
    }

    // MARK: - 时间线

    func addToTimeline(_ asset: MediaAsset) {
        let start = totalDuration
        let duration = asset.duration > 0 ? asset.duration : 5
        var item = TimelineItem(type: asset.type == .audio ? .audio : .video,
                                name: asset.name,
                                startTime: start,
                                duration: duration,
                                assetURL: asset.url)
        item.assetID = asset.id
        timeline.append(item)
        selectedItemID = item.id
        notify("「\(asset.name)」已加入时间线")
    }

    func addSubtitle(_ entry: SubtitleEntry) {
        var item = TimelineItem(type: .subtitle,
                                name: entry.text,
                                startTime: entry.startTime,
                                duration: max(0.5, entry.endTime - entry.startTime))
        item.properties.textContent = entry.text
        timeline.append(item)
    }

    func addSubtitles(_ entries: [SubtitleEntry]) {
        entries.forEach { addSubtitle($0) }
        notify("已添加 \(entries.count) 条字幕")
    }

    func removeSelectedItem() {
        guard let id = selectedItemID else { return }
        timeline.removeAll { $0.id == id }
        selectedItemID = nil
    }

    func updateItem(_ item: TimelineItem) {
        guard let index = timeline.firstIndex(where: { $0.id == item.id }) else { return }
        timeline[index] = item
    }

    // MARK: - 导出

    func exportVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(currentProject.name).mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let items = timeline
        let settings = currentProject.settings

        processing = ProcessingState(title: "正在导出视频…", message: "准备中", progress: 0.02)

        Task {
            do {
                try await VideoExporter.shared.export(items: items, settings: settings, to: url) { p, msg in
                    self.processing = ProcessingState(title: "正在导出视频…", message: msg, progress: p)
                }
                self.processing = nil
                self.notify("导出完成：\(url.lastPathComponent)")
            } catch {
                self.processing = nil
                self.showError(error.localizedDescription)
            }
        }
    }

    // MARK: - 反馈

    func notify(_ message: String) {
        toast = message
        toastWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.2)) { self?.toast = nil }
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    func showError(_ message: String) {
        errorMessage = message
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - 示例数据

    private func seedDemoTimelineIfNeeded() {
        timeline = [
            TimelineItem(type: .video, name: "品牌开场", startTime: 0, duration: 6),
            TimelineItem(type: .video, name: "产品特写", startTime: 6.2, duration: 10),
            TimelineItem(type: .aiGenerated, name: "AI 生成片段", startTime: 16.3, duration: 5),
            TimelineItem(type: .video, name: "片尾 Logo", startTime: 21.5, duration: 7),
            TimelineItem(type: .audio, name: "背景音乐 · Ambient", startTime: 0, duration: 20),
            TimelineItem(type: .audio, name: "AI 配音 · 晓晓", startTime: 6.9, duration: 11.2),
            TimelineItem(type: .subtitle, name: "用 AI 讲一个好故事", startTime: 0.8, duration: 4.6),
            TimelineItem(type: .subtitle, name: "从一句描述开始创作", startTime: 6.5, duration: 5.8),
            TimelineItem(type: .subtitle, name: "让灵感即刻成片", startTime: 13, duration: 5),
            TimelineItem(type: .subtitle, name: "现在就试试", startTime: 18.8, duration: 4.2)
        ]
        selectedItemID = timeline.first { $0.name == "产品特写" }?.id
        currentTime = 12
    }
}
