//
//  AppState.swift
//  全局状态：项目 / 时间线 / 播放预览 / 持久化
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

    // 预览（时间线合成后的真实画面）
    @Published var previewPlayer: AVPlayer?
    @Published var previewStatus: String?

    // 配置
    @Published var aiConfig = AIConfig()

    // 反馈
    @Published var processing: ProcessingState?
    @Published var toast: String?
    @Published var errorMessage: String?

    private var toastWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var previewGeneration = 0
    private var timeObserver: Any?
    private var terminateObserver: NSObjectProtocol?

    private init() {
        self.aiConfig = AIConfigManager.shared.load()

        let store = ProjectStore.shared
        let summaries = store.list()

        if let latest = summaries.first, let snapshot = try? store.load(id: latest.id) {
            self.currentProject = snapshot.project
            self.timeline = snapshot.timeline
            self.mediaLibrary = snapshot.media.map { ref in
                let asset = MediaAsset(url: URL(fileURLWithPath: ref.path))
                asset.name = ref.name
                return asset
            }
            self.currentTime = snapshot.currentTime
            self.selectedItemID = snapshot.selectedItemID
            self.projects = summaries.map(\.project)
        } else {
            let project = VideoProject(name: "品牌短片 v3")
            self.currentProject = project
            self.projects = [project]
            self.seedDemoTimelineIfNeeded()
        }

        loadMediaMetadata()
        setupAutosave()
        setupPreviewPipeline()

        // 首次启动即落盘，保证项目文件立刻存在
        saveNow()

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveNow()
        }
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

    func clips(on track: TimelineTrack) -> [TimelineItem] {
        switch track {
        case .video: return videoClips
        case .audio: return audioClips
        case .subtitle: return subtitleClips
        }
    }

    /// 同一轨道上相邻片段的边界，用于拖拽时避免重叠
    func neighbors(of item: TimelineItem) -> (prevEnd: Double, nextStart: Double) {
        let siblings = clips(on: item.trackKind).filter { $0.id != item.id }
        let prevEnd = siblings.filter { $0.endTime <= item.startTime + 0.001 }
            .map(\.endTime)
            .max() ?? 0
        let nextStart = siblings.filter { $0.startTime >= item.startTime - 0.001 }
            .map(\.startTime)
            .min() ?? .greatestFiniteMagnitude
        return (prevEnd, nextStart)
    }

    /// 素材可用的总时长（用于限制右边界裁剪）
    func assetDuration(for item: TimelineItem) -> Double? {
        guard let url = item.assetURL else { return nil }
        if let asset = mediaLibrary.first(where: { $0.url == url }), asset.duration > 0 {
            return asset.duration
        }
        return nil
    }

    // MARK: - 项目

    func createProject(named name: String = "未命名项目") {
        let project = VideoProject(name: name)
        currentProject = project
        timeline = []
        mediaLibrary = []
        selectedItemID = nil
        currentTime = 0
        isPlaying = false
        previewPlayer?.pause()
        saveNow()
        notify("已创建项目「\(name)」")
    }

    func selectProject(_ project: VideoProject) {
        if project.id != currentProject.id,
           let snapshot = try? ProjectStore.shared.load(id: project.id) {
            apply(snapshot)
        }
        selectedPanel = .editor
    }

    func apply(_ snapshot: ProjectSnapshot) {
        currentProject = snapshot.project
        timeline = snapshot.timeline
        mediaLibrary = snapshot.media.map { ref in
            let asset = MediaAsset(url: URL(fileURLWithPath: ref.path))
            asset.name = ref.name
            return asset
        }
        selectedItemID = snapshot.selectedItemID
        currentTime = snapshot.currentTime
        isPlaying = false
        previewPlayer?.pause()
        loadMediaMetadata()
    }

    func deleteProject(_ project: VideoProject) {
        ProjectStore.shared.delete(id: project.id)
        refreshProjectList()
        if project.id == currentProject.id {
            if let next = projects.first, let snapshot = try? ProjectStore.shared.load(id: next.id) {
                apply(snapshot)
            } else {
                createProject(named: "未命名项目")
            }
        }
        notify("已删除项目「\(project.name)」")
    }

    // MARK: - 持久化

    private func setupAutosave() {
        $timeline
            .dropFirst()
            .debounce(for: .seconds(1.2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveNow() }
            .store(in: &cancellables)

        $mediaLibrary
            .dropFirst()
            .debounce(for: .seconds(1.2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveNow() }
            .store(in: &cancellables)

        $currentProject
            .dropFirst()
            .debounce(for: .seconds(0.4), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveNow() }
            .store(in: &cancellables)
    }

    func saveNow() {
        var project = currentProject
        project.updatedAt = Date()

        let snapshot = ProjectSnapshot(
            project: project,
            media: mediaLibrary.map { MediaRef(id: $0.id, path: $0.url.path, name: $0.name, type: $0.type) },
            timeline: timeline,
            currentTime: currentTime,
            selectedItemID: selectedItemID
        )

        do {
            try ProjectStore.shared.save(snapshot)
            refreshProjectList()
        } catch {
            showError("保存项目失败：\(error.localizedDescription)")
        }
    }

    func saveProjectAs() {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: "aiva") {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "\(currentProject.name).aiva"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var project = currentProject
        project.updatedAt = Date()
        let snapshot = ProjectSnapshot(
            project: project,
            media: mediaLibrary.map { MediaRef(id: $0.id, path: $0.url.path, name: $0.name, type: $0.type) },
            timeline: timeline,
            currentTime: currentTime,
            selectedItemID: selectedItemID
        )
        do {
            let data = try JSONEncoder.projectEncoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            notify("项目已导出：\(url.lastPathComponent)")
        } catch {
            showError("导出项目失败：\(error.localizedDescription)")
        }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: "aiva") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let snapshot = try ProjectStore.shared.load(from: url)
            apply(snapshot)
            // 从外部打开的项目，落到本地库中，便于下次直接切换
            try? ProjectStore.shared.save(snapshot)
            refreshProjectList()
            notify("已打开「\(snapshot.project.name)」")
        } catch {
            showError("打开项目失败：\(error.localizedDescription)")
        }
    }

    func revealProjectFile() {
        ProjectStore.shared.reveal(id: currentProject.id)
    }

    private func refreshProjectList() {
        let summaries = ProjectStore.shared.list()
        let newIDs = summaries.map(\.id)
        guard newIDs != projects.map(\.id) else { return }
        projects = summaries.map(\.project)
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

    func loadMediaMetadata() {
        for asset in mediaLibrary where asset.duration <= 0 {
            Task { await asset.loadMetadata() }
        }
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
        notify("已删除片段")
    }

    func updateItem(_ item: TimelineItem) {
        guard let index = timeline.firstIndex(where: { $0.id == item.id }) else { return }
        timeline[index] = item
    }

    // MARK: - 播放

    func togglePlayback() {
        if isPlaying {
            isPlaying = false
            previewPlayer?.pause()
        } else {
            if currentTime >= totalDuration - 0.05 {
                seek(to: 0)
            }
            isPlaying = true
            previewPlayer?.play()
        }
    }

    func seek(to time: Double) {
        let clamped = min(max(0, time), max(0, totalDuration))
        currentTime = clamped
        guard let player = previewPlayer else { return }
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero)
    }

    // MARK: - 预览

    private func setupPreviewPipeline() {
        $timeline
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] items in self?.rebuildPreview(items) }
            .store(in: &cancellables)

        $currentProject
            .map(\.settings)
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.rebuildPreview(self.timeline)
            }
            .store(in: &cancellables)

        rebuildPreview(timeline)
    }

    private func rebuildPreview(_ items: [TimelineItem]) {
        let hasVideo = items.contains {
            ($0.type == .video || $0.type == .aiGenerated) && $0.assetURL != nil
        }
        guard hasVideo else {
            teardownPreview()
            return
        }

        previewGeneration += 1
        let generation = previewGeneration
        previewStatus = "正在生成预览…"

        Task { [weak self] in
            guard let self else { return }
            do {
                let build = try await CompositionBuilder.build(items: items,
                                                               renderSize: CGSize(width: 1280, height: 720),
                                                               fps: 30)
                await MainActor.run {
                    guard generation == self.previewGeneration else { return }
                    let item = AVPlayerItem(asset: build.composition)
                    item.videoComposition = build.videoComposition
                    item.audioMix = build.audioMix
                    let player = AVPlayer(playerItem: item)
                    player.actionAtItemEnd = .pause
                    self.install(player: player, at: self.currentTime)
                    self.previewStatus = nil
                    if self.isPlaying { player.play() }
                }
            } catch {
                await MainActor.run {
                    guard generation == self.previewGeneration else { return }
                    self.previewStatus = "预览不可用"
                    self.teardownPreview(keepStatus: true)
                }
            }
        }
    }

    private func install(player: AVPlayer, at time: Double) {
        if let token = timeObserver, let old = previewPlayer {
            old.removeTimeObserver(token)
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20),
            queue: .main
        ) { [weak self] cmTime in
            guard let self, self.isPlaying else { return }
            let seconds = CMTimeGetSeconds(cmTime)
            guard seconds.isFinite else { return }
            if seconds >= self.totalDuration - 0.03 {
                self.currentTime = self.totalDuration
                self.isPlaying = false
                self.previewPlayer?.pause()
            } else {
                self.currentTime = seconds
            }
        }

        player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero)
        previewPlayer = player
    }

    private func teardownPreview(keepStatus: Bool = false) {
        if let token = timeObserver, let player = previewPlayer {
            player.removeTimeObserver(token)
        }
        timeObserver = nil
        previewPlayer?.pause()
        previewPlayer = nil
        if !keepStatus { previewStatus = nil }
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
            TimelineItem(type: .video, name: "产品特写", startTime: 6, duration: 10),
            TimelineItem(type: .aiGenerated, name: "AI 生成片段", startTime: 16, duration: 5),
            TimelineItem(type: .video, name: "片尾 Logo", startTime: 21, duration: 7),
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

extension JSONEncoder {
    static var projectEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
