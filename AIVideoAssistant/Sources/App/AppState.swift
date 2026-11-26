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
    @Published var showingSmartCut = false
    @Published var showingExportQueue = false
    /// 素材重连面板
    @Published var showingAssetRelink = false
    /// 面板里列出的缺失素材（打开面板时扫一次）
    @Published var relinkCandidates: [AssetRelinker.Missing] = []
    /// 找不到文件的素材路径集合。用集合而不是计数，素材卡片才能标出哪一张丢了
    @Published var missingAssetPaths: Set<String> = []
    /// 提示条上的数字
    var missingAssetCount: Int { missingAssetPaths.count }
    /// 导出前体检结果；有值就弹面板
    @Published var preflightReport: PreflightReport?
    /// 体检通过后要继续做的事（打开保存面板）
    private var preflightAction: (() -> Void)?

    // 素材与时间线
    @Published var mediaLibrary: [MediaAsset] = []
    /// 素材库里的自定义集合（分文件夹管理）
    @Published var mediaCollections: [MediaCollection] = []
    @Published var timeline: [TimelineItem] = []
    @Published var selectedItemIDs: Set<UUID> = []
    /// 用户自己存的导出预设（内置的在 ExportPresetLibrary.builtins）
    @Published var customExportPresets: [ExportPreset] = []

    /// 单选时的主选中项；多选时为 nil（属性面板改为显示批量操作）
    var selectedItemID: UUID? {
        get { selectedItemIDs.count == 1 ? selectedItemIDs.first : nil }
        set {
            if let newValue {
                selectedItemIDs = [newValue]
            } else {
                selectedItemIDs = []
            }
        }
    }

    var selectedItems: [TimelineItem] {
        timeline.filter { selectedItemIDs.contains($0.id) }
    }

    var hasMultiSelection: Bool { selectedItemIDs.count > 1 }

    /// 点选片段：additive 时切换选中状态（⌘ 点击）
    func select(_ id: UUID, additive: Bool) {
        if additive {
            if selectedItemIDs.contains(id) {
                selectedItemIDs.remove(id)
            } else {
                selectedItemIDs.insert(id)
            }
        } else {
            selectedItemIDs = [id]
        }
    }

    func clearSelection() {
        selectedItemIDs = []
    }

    func selectAll() {
        selectedItemIDs = Set(timeline.map(\.id))
    }

    // 播放
    @Published var currentTime: Double = 0
    @Published var isPlaying = false

    // 预览（时间线合成后的真实画面）
    @Published var previewPlayer: AVPlayer?
    @Published var previewStatus: String?

    /// 画中画素材尺寸缓存（key = 文件路径）。
    /// 预览台画拖拽框要知道素材宽高比，不然竖屏画中画会被画成横的；
    /// 读一次就留着，拖动时不能每次都去问 AVFoundation。
    @Published private(set) var mediaSizes: [String: CGSize] = [:]

    // 配置
    @Published var aiConfig = AIConfig()

    // 反馈
    @Published var processing: ProcessingState?
    @Published var toast: String?
    @Published var errorMessage: String?

    // 撤销 / 重做
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []
    private var lastUndoStamp: Date = .distantPast

    struct EditSnapshot: Equatable {
        var timeline: [TimelineItem]
        var selectedItemIDs: Set<UUID>
    }

    private var toastWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var previewGeneration = 0
    private var timeObserver: Any?
    private var terminateObserver: NSObjectProtocol?

    private init() {
        self.aiConfig = AIConfigManager.shared.load()
        self.customExportPresets = ExportPresetStore.load()

        let store = ProjectStore.shared
        let summaries = store.list()

        if let latest = summaries.first, let snapshot = try? store.load(id: latest.id) {
            self.currentProject = snapshot.project
            self.timeline = snapshot.timeline
            self.mediaLibrary = snapshot.media.map { ref in
                let asset = MediaAsset(url: URL(fileURLWithPath: ref.path), id: ref.id)
                asset.name = ref.name
                return asset
            }
            self.mediaCollections = MediaShelf.sanitized(snapshot.collections, library: self.mediaLibrary)
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
        setupExportQueue()
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

    /// 指定层上的片段（音频分层用）
    func clips(on track: TimelineTrack, lane: Int) -> [TimelineItem] {
        clips(on: track).filter { $0.trackLane == lane }
    }

    /// 当前时间点应显示的字幕
    var activeSubtitle: TimelineItem? {
        SubtitleRenderer.activeItem(at: currentTime, in: timeline)
    }

    /// 预览用的合成尺寸：跟随项目画幅比例，最长边压到 1280 以内。
    /// 以前固定 1280×720，竖屏 / 方形项目的预览比例是错的，
    /// 画中画的落位也会跟着错位——预览台和导出必须用同一个画幅。
    var previewRenderSize: CGSize {
        let target = currentProject.settings.resolution.size
        let longest = max(target.width, target.height)
        guard longest > 1280, longest > 0 else { return target }
        let scale = 1280 / longest
        return CGSize(width: (target.width * scale).rounded(),
                      height: (target.height * scale).rounded())
    }

    /// 播放头位置正在显示的那条画中画（V2 层且在自身区间内）。
    /// 预览台的拖拽框只画这一条，避免多条画中画叠在一起抢手势。
    var activeOverlay: TimelineItem? {
        timeline.first { $0.isOverlay && currentTime >= $0.startTime && currentTime < $0.endTime }
    }

    /// 查缓存的素材尺寸；没缓存就返回 nil（调用方先用 16:9 兜底）
    func mediaSize(for url: URL?) -> CGSize? {
        guard let url else { return nil }
        return mediaSizes[url.path]
    }

    /// 异步读一次素材尺寸并缓存。重复调用会被缓存挡掉。
    func requestMediaSize(for url: URL?) {
        guard let url, mediaSizes[url.path] == nil else { return }
        let key = url.path
        Task { [weak self] in
            let size = await PiPGeometry.displaySize(url: url)
            // 读不出来就记 16:9：宁可画框比例不准，也不要每次重绘都重试
            let resolved = size ?? CGSize(width: 16, height: 9)
            await MainActor.run { [weak self] in
                self?.mediaSizes[key] = resolved
            }
        }
    }

    /// 该层上指定时间范围是否空闲
    func laneIsFree(_ track: TimelineTrack, lane: Int, start: Double, end: Double) -> Bool {
        !clips(on: track, lane: lane).contains { start < $0.endTime - 0.01 && end > $0.startTime + 0.01 }
    }

    /// 为音频片段找一个不冲突的层
    func firstFreeAudioLane(start: Double, end: Double) -> Int {
        for lane in 0..<TimelineItem.laneCount(for: .audio) {
            if laneIsFree(.audio, lane: lane, start: start, end: end) { return lane }
        }
        return 0
    }

    /// 同一轨道同一层上相邻片段的边界，用于拖拽时避免重叠
    func neighbors(of item: TimelineItem) -> (prevEnd: Double, nextStart: Double) {
        let siblings = clips(on: item.trackKind, lane: item.trackLane).filter { $0.id != item.id }
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

    // MARK: - 转场

    /// 同轨道同层、起点更早的最近一段（转场靠它吃尾巴）
    func previousClip(before item: TimelineItem) -> TimelineItem? {
        clips(on: item.trackKind, lane: item.trackLane)
            .filter { $0.id != item.id && $0.startTime < item.startTime - 0.001 }
            .max { $0.startTime < $1.startTime }
    }

    /// 某段片段的入场转场当前是什么状态
    func transitionStatus(for item: TimelineItem) -> TransitionStatus {
        let prev = previousClip(before: item)
        return TimelineLayout.transitionStatus(for: item,
                                               previous: prev,
                                               previousAssetDuration: prev.flatMap { assetDuration(for: $0) })
    }

    /// 把片段贴到前一段末尾，让转场能生效
    @discardableResult
    func snapToPrevious(_ itemID: UUID) -> Bool {
        guard let item = timeline.first(where: { $0.id == itemID }),
              let prev = previousClip(before: item) else {
            notify("这一段前面没有片段")
            return false
        }
        let nextStart = neighbors(of: item).nextStart
        guard let target = TimelineLayout.snappedStart(item: item,
                                                       previousEnd: prev.endTime,
                                                       nextStart: nextStart) else {
            notify("后面空间不够，先给这一段挪个位置")
            return false
        }
        beginEdit()
        var copy = item
        copy.startTime = target
        updateItem(copy)
        notify("已吸附到上一段末尾")
        return true
    }

    /// 把所有设置了转场的片段批量吸附成相邻
    /// - Returns: 实际被移动的片段数
    @discardableResult
    func snapAllTransitions() -> Int {
        let targets = timeline
            .filter { $0.transition != .none && $0.trackKind == .video }
            .sorted { $0.startTime < $1.startTime }
        guard !targets.isEmpty else {
            notify("时间线上还没有设置转场")
            return 0
        }

        // 先在副本上跑一遍：一是判断有没有活可干（别压空的撤销点），
        // 二是吸附要「顺序」做——前一段挪完，后一段的参照物才更新
        func plan(on items: [TimelineItem]) -> [(UUID, Double)] {
            var working = items
            var moves: [(UUID, Double)] = []
            for item in targets {
                guard let index = working.firstIndex(where: { $0.id == item.id }) else { continue }
                let current = working[index]
                let prevEnd = working
                    .filter { $0.id != current.id
                              && $0.trackKind == current.trackKind
                              && $0.trackLane == current.trackLane
                              && $0.startTime < current.startTime - 0.001 }
                    .map(\.endTime).max()
                guard let prevEnd else { continue }
                let nextStart = working
                    .filter { $0.id != current.id
                              && $0.trackKind == current.trackKind
                              && $0.trackLane == current.trackLane
                              && $0.startTime >= current.startTime - 0.001 }
                    .map(\.startTime).min() ?? .greatestFiniteMagnitude
                guard let target = TimelineLayout.snappedStart(item: current,
                                                               previousEnd: prevEnd,
                                                               nextStart: nextStart) else { continue }
                working[index].startTime = target
                moves.append((current.id, target))
            }
            return moves
        }

        let moves = plan(on: timeline)
        guard !moves.isEmpty else {
            let stuck = targets.filter { item in
                guard let prev = previousClip(before: item) else { return false }
                return abs(item.startTime - prev.endTime) > TimelineLayout.transitionContiguity
            }.count
            notify(stuck > 0 ? "有 \(stuck) 段后面空间不够，没能吸附" : "所有转场片段已经相邻")
            return 0
        }

        beginEdit()
        for (id, target) in moves {
            guard var copy = timeline.first(where: { $0.id == id }) else { continue }
            copy.startTime = target
            updateItem(copy)
        }
        notify("已吸附 \(moves.count) 段转场片段")
        return moves.count
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
        resetHistory()
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
            let asset = MediaAsset(url: URL(fileURLWithPath: ref.path), id: ref.id)
            asset.name = ref.name
            return asset
        }
        mediaCollections = MediaShelf.sanitized(snapshot.collections, library: mediaLibrary)
        selectedItemID = snapshot.selectedItemID
        currentTime = snapshot.currentTime
        isPlaying = false
        previewPlayer?.pause()
        resetHistory()
        loadMediaMetadata()
    }

    private func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        lastUndoStamp = .distantPast
        refreshUndoFlags()
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

        $mediaCollections
            .dropFirst()
            .debounce(for: .seconds(1.2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveNow() }
            .store(in: &cancellables)

        $currentProject
            .dropFirst()
            .debounce(for: .seconds(0.4), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveNow() }
            .store(in: &cancellables)

        // 素材或时间线变了就重扫一次缺失文件，供素材库提示条使用。
        // 防抖是为了拖动片段时不要每一帧都去 stat 一遍所有路径
        $mediaLibrary
            .map { _ in () }
            .merge(with: $timeline.map { _ in () })
            .debounce(for: .seconds(0.8), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMissingAssetCount() }
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
            selectedItemID: selectedItemID,
            collections: mediaCollections
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
            selectedItemID: selectedItemID,
            collections: mediaCollections
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

        beginEdit()
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

    /// 在指定位置插入素材（拖拽落点）。同轨同层已有片段时自动顺延到空隙
    @discardableResult
    func insertMedia(url: URL,
                     at desiredStart: Double,
                     audioLaneHint: Int? = nil,
                     videoLaneHint: Int? = nil) async -> Bool {
        let asset: MediaAsset
        if let existing = mediaLibrary.first(where: { $0.url == url }) {
            asset = existing
        } else {
            let created = MediaAsset(url: url)
            mediaLibrary.append(created)
            asset = created
        }
        if asset.duration <= 0 {
            await asset.loadMetadata()
        }

        let kind: TimelineItemType = asset.type == .audio ? .audio : .video
        let duration = asset.duration > 0 ? asset.duration : 5
        let trackKind = kind == .audio ? TimelineTrack.audio : .video

        var lane = 0
        if kind == .audio {
            let preferred = min(max(0, audioLaneHint ?? 0), TimelineItem.laneCount(for: .audio) - 1)
            lane = preferred
            if !laneIsFree(.audio, lane: lane, start: desiredStart, end: desiredStart + duration) {
                let other = preferred == 0 ? 1 : 0
                if laneIsFree(.audio, lane: other, start: desiredStart, end: desiredStart + duration) {
                    lane = other
                }
            }
        } else if let videoLaneHint {
            // 拖到 V2 上就是「做成画中画」；V2 冲突时退回 V1，别把素材丢掉
            let preferred = min(max(0, videoLaneHint), TimelineItem.laneCount(for: .video) - 1)
            lane = laneIsFree(.video, lane: preferred, start: desiredStart, end: desiredStart + duration)
                ? preferred : 0
        }

        let start = freeStart(kind: trackKind, lane: lane, desired: desiredStart, duration: duration)

        beginEdit()
        var item = TimelineItem(type: kind,
                                name: asset.name,
                                startTime: start,
                                duration: duration,
                                assetURL: asset.url)
        item.assetID = asset.id
        item.trackLane = lane
        timeline.append(item)
        selectedItemID = item.id
        if item.isOverlay {
            notify("「\(asset.name)」已作为画中画插入 \(formatTimecode(start))")
        } else {
            notify("「\(asset.name)」已插入 \(formatTimecode(start))")
        }
        return true
    }

    /// 从期望位置开始找一段不与同轨同层片段重叠的起点
    func freeStart(kind: TimelineTrack, lane: Int, desired: Double, duration: Double) -> Double {
        TimelineLayout.freeStart(existing: clips(on: kind, lane: lane),
                                 desired: desired,
                                 duration: duration)
    }

    func addToTimeline(_ asset: MediaAsset) {
        beginEdit()
        let start = totalDuration
        let duration = asset.duration > 0 ? asset.duration : 5
        var item = TimelineItem(type: asset.type == .audio ? .audio : .video,
                                name: asset.name,
                                startTime: start,
                                duration: duration,
                                assetURL: asset.url)
        item.assetID = asset.id
        if item.type == .audio {
            item.trackLane = firstFreeAudioLane(start: start, end: start + duration)
        }
        timeline.append(item)
        selectedItemID = item.id
        notify("「\(asset.name)」已加入时间线")
    }

    /// 时间线上每个素材被引用的次数（素材库筛选 / 未使用清理都用它）
    var mediaUsage: MediaUsage { MediaShelf.usage(in: timeline) }

    /// 从素材库移除（只动素材库，不删磁盘文件，也不动时间线上已有的片段）
    func removeMedia(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removed = mediaLibrary.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        let usage = mediaUsage
        let used = removed.filter { usage.count($0) > 0 }.count
        for asset in removed {
            HoverPreviewStore.shared.invalidate(url: asset.url)
        }
        mediaLibrary.removeAll { ids.contains($0.id) }
        mediaCollections = MediaShelf.sanitized(mediaCollections, library: mediaLibrary)
        if used > 0 {
            notify("已移出 \(removed.count) 个素材，其中 \(used) 个仍被时间线使用")
        } else {
            notify("已移出 \(removed.count) 个素材")
        }
    }

    /// 一次性移出没被时间线用到的素材
    /// - Returns: 实际移出的数量
    @discardableResult
    func removeUnusedMedia() -> Int {
        let ids = MediaShelf.unusedIDs(mediaLibrary, usage: mediaUsage)
        guard !ids.isEmpty else {
            notify("素材库里的素材都在时间线中用到了")
            return 0
        }
        mediaLibrary.removeAll { ids.contains($0.id) }
        mediaCollections = MediaShelf.sanitized(mediaCollections, library: mediaLibrary)
        notify("已移出 \(ids.count) 个未使用素材（文件仍在磁盘上）")
        return ids.count
    }

    // MARK: - 素材集合

    func collection(_ id: UUID) -> MediaCollection? {
        mediaCollections.first { $0.id == id }
    }

    /// 素材被哪些集合收录（卡片右键菜单打勾用）
    func collectionIDs(containing assetID: UUID) -> [UUID] {
        mediaCollections.filter { $0.contains(assetID) }.map(\.id)
    }

    /// 新建集合，返回新集合 id。重名自动加序号
    @discardableResult
    func createCollection(name: String, assetIDs: Set<UUID> = []) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "未命名集合" : trimmed
        var finalName = base
        var suffix = 2
        while mediaCollections.contains(where: { $0.name == finalName }) {
            finalName = "\(base) \(suffix)"
            suffix += 1
        }

        var collection = MediaCollection(name: finalName)
        MediaShelf.add(orderedAssetIDs(assetIDs), to: &collection)
        mediaCollections.append(collection)
        notify("已创建集合「\(finalName)」")
        return collection.id
    }

    func renameCollection(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = mediaCollections.firstIndex(where: { $0.id == id }) else { return }
        mediaCollections[index].name = trimmed
    }

    /// 删除集合只删分组关系，素材本身还在素材库里
    func deleteCollection(_ id: UUID) {
        guard let index = mediaCollections.firstIndex(where: { $0.id == id }) else { return }
        let name = mediaCollections[index].name
        mediaCollections.remove(at: index)
        notify("已删除集合「\(name)」，素材仍保留在素材库")
    }

    @discardableResult
    func addToCollection(_ assetIDs: Set<UUID>, collectionID: UUID) -> Int {
        guard let index = mediaCollections.firstIndex(where: { $0.id == collectionID }) else { return 0 }
        let added = MediaShelf.add(orderedAssetIDs(assetIDs), to: &mediaCollections[index])
        let name = mediaCollections[index].name
        if added > 0 {
            notify("已把 \(added) 个素材加入「\(name)」")
        } else {
            notify("这些素材已经在「\(name)」里了")
        }
        return added
    }

    @discardableResult
    func removeFromCollection(_ assetIDs: Set<UUID>, collectionID: UUID) -> Int {
        guard let index = mediaCollections.firstIndex(where: { $0.id == collectionID }) else { return 0 }
        let before = mediaCollections[index].assetIDs.count
        mediaCollections[index].assetIDs.removeAll { assetIDs.contains($0) }
        let removed = before - mediaCollections[index].assetIDs.count
        if removed > 0 {
            notify("已从「\(mediaCollections[index].name)」移出 \(removed) 个素材")
        }
        return removed
    }

    /// 按素材库顺序排，避免 Set 的随机顺序让集合成员次序乱跳
    private func orderedAssetIDs(_ ids: Set<UUID>) -> [UUID] {
        mediaLibrary.map(\.id).filter { ids.contains($0) }
    }

    /// 集合内拖动排序。拖拽过程会连续触发，所以不发提示，只返回有没有真的动
    @discardableResult
    func reorderCollection(_ collectionID: UUID, moving: UUID, over target: UUID) -> Bool {
        reorderCollection(collectionID, moving: [moving], over: target)
    }

    /// 一次拖多个：整组挪到 target 上（相对顺序不变）
    @discardableResult
    func reorderCollection(_ collectionID: UUID, moving: Set<UUID>, over target: UUID) -> Bool {
        guard let index = mediaCollections.firstIndex(where: { $0.id == collectionID }) else { return false }
        let before = mediaCollections[index].assetIDs
        let after = MediaShelf.reorder(before, moving: moving, over: target)
        guard after != before else { return false }
        mediaCollections[index].assetIDs = after
        return true
    }

    /// 拖到集合空白处 → 挪到该集合最后
    @discardableResult
    func moveToEndOfCollection(_ collectionID: UUID, moving: UUID) -> Bool {
        guard let index = mediaCollections.firstIndex(where: { $0.id == collectionID }) else { return false }
        let before = mediaCollections[index].assetIDs
        let after = MediaShelf.moveToEnd(before, moving: moving)
        guard after != before else { return false }
        mediaCollections[index].assetIDs = after
        return true
    }

    /// 拖放进来的文件 URL → 素材库里对应素材的 id（规则见 MediaShelf）
    func assetIDs(forURLs urls: [URL]) -> Set<UUID> {
        MediaShelf.assetIDs(forURLs: urls, in: mediaLibrary)
    }

    /// 把拖进来的文件加进集合；文件不在素材库里时给出提示而不是静默失败
    @discardableResult
    func addDroppedURLs(_ urls: [URL], toCollection collectionID: UUID) -> Int {
        let ids = assetIDs(forURLs: urls)
        if ids.isEmpty {
            notify("这些文件还不在素材库里，先导入素材库再拖进集合")
            return 0
        }
        let missing = urls.count - ids.count
        let added = addToCollection(ids, collectionID: collectionID)
        if missing > 0, added > 0 {
            notify("已加入 \(added) 个素材，另有 \(missing) 个文件不在素材库里被跳过")
        }
        return added
    }

    func addSubtitle(_ entry: SubtitleEntry,
                     fontSize: Int = 28,
                     colorHex: Int = 0xFFFFFF) {
        var item = TimelineItem(type: .subtitle,
                                name: entry.text,
                                startTime: entry.startTime,
                                duration: max(0.5, entry.endTime - entry.startTime))
        item.properties.textContent = entry.text
        item.properties.fontSize = fontSize
        item.properties.textColorHex = colorHex
        timeline.append(item)
    }

    func addSubtitles(_ entries: [SubtitleEntry],
                      fontSize: Int = 28,
                      colorHex: Int = 0xFFFFFF) {
        guard !entries.isEmpty else { return }
        beginEdit()
        entries.forEach { addSubtitle($0, fontSize: fontSize, colorHex: colorHex) }
        notify("已添加 \(entries.count) 条字幕")
    }

    func removeSelectedItem() {
        guard !selectedItemIDs.isEmpty else { return }
        let count = selectedItemIDs.count
        beginEdit()
        timeline.removeAll { selectedItemIDs.contains($0.id) }
        selectedItemIDs = []
        notify(count > 1 ? "已删除 \(count) 个片段" : "已删除片段")
    }

    /// 把选中的片段整组复制一份，贴在整组末尾。
    ///
    /// 没有走剪贴板（⌘C / ⌘V）：菜单快捷键在 macOS 上优先于响应者链，
    /// 绑了 ⌘C 之后字幕面板的文本框就复制不了字了。⌘D 一步到位，
    /// 也正好覆盖「复制这个片段再改改」的绝大多数用法。
    @discardableResult
    func duplicateSelection() -> Int {
        let picked = selectedItems.sorted { $0.startTime < $1.startTime }
        guard !picked.isEmpty else { return 0 }

        let base = picked[0].startTime
        var anchor = picked.map(\.endTime).max() ?? base

        // 组末尾被占用就整组往右推：把 anchor 推到「冲突片段结束时间 - 该片段偏移」，
        // 迭代几轮就能把所有冲突推干净（通常一轮就够）
        for _ in 0..<6 {
            var next = anchor
            for item in picked {
                let offset = item.startTime - base
                let start = anchor + offset
                let end = start + item.duration
                for other in clips(on: item.trackKind, lane: item.trackLane)
                where start < other.endTime - 0.001 && end > other.startTime + 0.001 {
                    next = max(next, other.endTime - offset)
                }
            }
            if next <= anchor + 0.0001 { break }
            anchor = next
        }

        beginEdit()
        var fresh: [TimelineItem] = []
        fresh.reserveCapacity(picked.count)
        for item in picked {
            var copy = item
            copy.id = UUID()                     // 必须换 id，否则选中/删除会串
            copy.startTime = anchor + (item.startTime - base)
            fresh.append(copy)
        }
        timeline.append(contentsOf: fresh)
        selectedItemIDs = Set(fresh.map(\.id))
        notify(fresh.count > 1 ? "已复制 \(fresh.count) 个片段" : "已复制片段")
        return fresh.count
    }

    // MARK: - 时间线缩放

    /// 时间线缩放倍率。放在 AppState 而不是视图里，菜单快捷键才够得着。
    @Published var timelineZoom: CGFloat = 1.0

    static let timelineZoomRange: ClosedRange<CGFloat> = 0.5...3.0

    func zoomTimeline(by factor: CGFloat) {
        timelineZoom = min(max(timelineZoom * factor, Self.timelineZoomRange.lowerBound),
                           Self.timelineZoomRange.upperBound)
    }

    func resetTimelineZoom() {
        timelineZoom = 1.0
    }

    /// recordUndo=true 时把这次修改纳入撤销栈（滑杆连续拖动会在 1 秒内合并）
    func updateItem(_ item: TimelineItem, recordUndo: Bool = false) {
        guard let index = timeline.firstIndex(where: { $0.id == item.id }) else { return }
        if recordUndo { beginEdit(coalescing: true) }
        timeline[index] = item
    }

    /// 把片段移到另一层（音频 A1/A2、视频 V1/V2）
    func moveToLane(_ item: TimelineItem, lane: Int) {
        let kind = item.trackKind
        let maxLane = TimelineItem.laneCount(for: kind)
        guard maxLane > 1 else { return }
        let target = min(max(0, lane), maxLane - 1)
        guard target != item.trackLane else { return }
        guard laneIsFree(kind, lane: target, start: item.startTime, end: item.endTime) else {
            notify("该轨道这个时间段已被占用")
            return
        }
        beginEdit()
        var copy = item
        copy.trackLane = target
        if let index = timeline.firstIndex(where: { $0.id == item.id }) {
            timeline[index] = copy
        }
        if kind == .video {
            notify(target >= 1 ? "已转为画中画（V2）" : "已回到主画面（V1）")
        }
    }

    // MARK: - 智能剪辑（按停顿切片 / 去停顿）

    /// 分析结果（针对当前目标片段）
    @Published var speechAnalysis: SpeechAnalysis?
    @Published var isAnalyzingSpeech = false
    @Published var smartCutTargetID: UUID?

    /// 检测参数
    @Published var silenceThresholdDB: Float = -34
    @Published var minPauseDuration: Double = 0.35
    @Published var minSpeechDuration: Double = 0.25

    var smartCutTarget: TimelineItem? {
        if let id = smartCutTargetID, let item = timeline.first(where: { $0.id == id }) { return item }
        return defaultSpeechClip
    }

    /// 优先挑配音轨（A2），其次任意音频片段
    var defaultSpeechClip: TimelineItem? {
        let audio = timeline.filter { $0.type == .audio }
        return audio.first { $0.trackLane == 1 } ?? audio.first
    }

    /// 目标片段覆盖的文件区间（秒）
    private func sourceRange(of item: TimelineItem) -> ClosedRange<Double> {
        let speed = max(0.1, item.properties.speed)
        let start = max(0, item.sourceStart)
        return start...(start + item.duration * speed)
    }

    /// 文件时间 → 时间线时间
    private func timelineTime(_ fileTime: Double, in item: TimelineItem) -> Double {
        let speed = max(0.1, item.properties.speed)
        return item.startTime + (fileTime - item.sourceStart) / speed
    }

    /// 落在目标片段内部的停顿（时间线时间）
    func pauses(in item: TimelineItem, includeEdges: Bool = false) -> [ClosedRange<Double>] {
        guard let analysis = speechAnalysis else { return [] }
        let source = sourceRange(of: item)
        var result: [ClosedRange<Double>] = []
        for silence in analysis.silences {
            guard silence.upperBound > source.lowerBound + 0.02,
                  silence.lowerBound < source.upperBound - 0.02 else { continue }
            let start = max(silence.lowerBound, source.lowerBound)
            let end = min(silence.upperBound, source.upperBound)
            guard end - start > 0.05 else { continue }
            if !includeEdges {
                // 只处理片段内部的停顿，头尾留给用户自己裁
                guard silence.lowerBound > source.lowerBound + 0.05,
                      silence.upperBound < source.upperBound - 0.05 else { continue }
            }
            result.append(timelineTime(start, in: item)...timelineTime(end, in: item))
        }
        return result
    }

    func analyzeSpeech(for item: TimelineItem? = nil) async {
        guard let clip = item ?? smartCutTarget, let url = clip.assetURL else {
            notify("先选一个带音频的片段")
            return
        }
        smartCutTargetID = clip.id
        isAnalyzingSpeech = true
        let threshold = silenceThresholdDB
        let minSilence = minPauseDuration
        let minSpeech = minSpeechDuration

        let analysis = await withCheckedContinuation { (continuation: CheckedContinuation<SpeechAnalysis?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: SilenceDetector.analyze(url: url,
                                                                       thresholdDB: threshold,
                                                                       minSilence: minSilence,
                                                                       minSpeech: minSpeech))
            }
        }
        isAnalyzingSpeech = false
        guard let analysis else {
            notify("这个文件读不出音频")
            return
        }
        speechAnalysis = analysis
        let count = pauses(in: clip).count
        notify("识别到 \(count) 处停顿，可剪掉约 \(String(format: "%.1f", analysis.silenceDuration)) 秒")
    }

    /// 按停顿中点把目标片段切成多段
    func splitAtPauses() {
        guard let clip = smartCutTarget else { return }
        let ranges = pauses(in: clip)
        guard !ranges.isEmpty else {
            notify("没有可切的停顿")
            return
        }
        let points = ranges.map { ($0.lowerBound + $0.upperBound) / 2 }
        let pieces = TimelineLayout.split(clip, at: points)
        guard pieces.count > 1 else {
            notify("停顿太靠近片段边缘")
            return
        }
        beginEdit()
        timeline.removeAll { $0.id == clip.id }
        timeline.append(contentsOf: pieces)
        timeline.sort { $0.startTime < $1.startTime }
        selectedItemIDs = Set(pieces.map(\.id))
        notify("已按停顿切成 \(pieces.count) 段")
    }

    /// 删掉停顿并把后面的内容整体前移（波纹删除），全轨同步移动保持对齐
    func rippleDeletePauses() {
        guard let clip = smartCutTarget else { return }
        let ranges = pauses(in: clip)
        guard !ranges.isEmpty else {
            notify("没有可删的停顿")
            return
        }
        let removed = ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        beginEdit()
        let kept = TimelineLayout.rippleDelete(items: timeline, ranges: ranges)
        let alive = Set(kept.map(\.id))
        timeline = kept
        selectedItemIDs = selectedItemIDs.intersection(alive)
        currentTime = min(currentTime, totalDuration)
        notify("已剪掉 \(String(format: "%.1f", removed)) 秒停顿，时长缩短到 \(formatTimecode(totalDuration))")
    }

    func resetSpeechAnalysis() {
        speechAnalysis = nil
        smartCutTargetID = nil
    }

    // MARK: - 撤销 / 重做

    /// 记录一次编辑前的状态。coalescing=true 时在 1 秒内合并（用于滑杆连续拖动）
    func beginEdit(coalescing: Bool = false) {
        let now = Date()
        if coalescing, now.timeIntervalSince(lastUndoStamp) < 1.0 {
            lastUndoStamp = now
            return
        }
        lastUndoStamp = now

        let snapshot = EditSnapshot(timeline: timeline, selectedItemIDs: selectedItemIDs)
        if undoStack.last != snapshot {
            undoStack.append(snapshot)
            if undoStack.count > 120 { undoStack.removeFirst() }
        }
        redoStack.removeAll()
        refreshUndoFlags()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(EditSnapshot(timeline: timeline, selectedItemIDs: selectedItemIDs))
        applySnapshot(previous)
        lastUndoStamp = .distantPast
        refreshUndoFlags()
        notify("已撤销")
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(EditSnapshot(timeline: timeline, selectedItemIDs: selectedItemIDs))
        applySnapshot(next)
        lastUndoStamp = .distantPast
        refreshUndoFlags()
        notify("已重做")
    }

    private func applySnapshot(_ snapshot: EditSnapshot) {
        timeline = snapshot.timeline
        let alive = Set(timeline.map(\.id))
        selectedItemIDs = snapshot.selectedItemIDs.intersection(alive)
    }

    private func refreshUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
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
        let renderSize = previewRenderSize
        previewStatus = "正在生成预览…"

        Task { [weak self] in
            guard let self else { return }
            do {
                let build = try await CompositionBuilder.build(items: items,
                                                               renderSize: renderSize,
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

    // MARK: - 导出预设

    /// 内置 + 自定义
    var exportPresets: [ExportPreset] {
        ExportPresetLibrary.all(custom: customExportPresets)
    }

    /// 当前设置正好等于某个预设时返回它，否则 nil（说明是手调过的）
    var activeExportPreset: ExportPreset? {
        ExportPresetLibrary.matching(currentProject.settings, in: exportPresets)
    }

    func applyExportPreset(_ preset: ExportPreset) {
        var project = currentProject
        project.settings = preset.settings
        currentProject = project
        notify("已切换到「\(preset.name)」· \(preset.summary)")
    }

    /// 改单个参数（分辨率 / 帧率 / 画质 / 填充方式）都走这里，保证只有一处写入口
    func updateExportSettings(_ change: (inout ExportSettings) -> Void) {
        var project = currentProject
        change(&project.settings)
        currentProject = project
    }

    /// 把当前设置存成自定义预设，返回最终用的名字（重名会自动加序号）
    @discardableResult
    func saveExportPreset(named raw: String) -> String {
        let existing = exportPresets
        let preset = ExportPresetLibrary.makePreset(name: raw,
                                                    settings: currentProject.settings,
                                                    avoiding: existing)
        customExportPresets = ExportPresetLibrary.upserting(preset, into: customExportPresets)
        ExportPresetStore.save(customExportPresets)
        notify("已保存预设「\(preset.name)」")
        return preset.name
    }

    func deleteExportPreset(_ id: UUID) {
        guard let preset = customExportPresets.first(where: { $0.id == id }) else { return }
        customExportPresets = ExportPresetLibrary.removing(id: id, from: customExportPresets)
        ExportPresetStore.save(customExportPresets)
        notify("已删除预设「\(preset.name)」")
    }

    // MARK: - 导出

    /// 导出前先体检：有问题就弹面板列清楚，用户确认后再选路径。
    /// 没问题的常见情况（干净时间线）不会多一步，直接进保存面板。
    func exportVideo() {
        guard !timeline.isEmpty else {
            showError("时间线是空的，先放点素材进来")
            return
        }
        let items = timeline
        let settings = currentProject.settings

        Task { @MainActor in
            let report = await PreflightCheck.run(items: items, settings: settings)
            if report.hasIssues {
                self.preflightAction = { [weak self] in self?.presentExportPanel() }
                self.preflightReport = report
            } else {
                self.presentExportPanel()
            }
        }
    }

    /// 体检面板里点了「开始导出 / 仍然导出」
    func proceedExportAfterPreflight() {
        let action = preflightAction
        preflightAction = nil
        preflightReport = nil
        // 等 sheet 收完再开保存面板，否则两个模态会打架
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { action?() }
    }

    /// 体检面板里点了「取消 / 去修改」
    func dismissPreflight() {
        preflightAction = nil
        preflightReport = nil
    }

    /// 从体检面板跳到重连面板。两个都是 sheet，不能同时开，
    /// 所以先关掉体检、等它收完动画再弹重连
    func relinkFromPreflight() {
        dismissPreflight()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            self?.presentAssetRelink()
        }
    }

    private func presentExportPanel() {
        let settings = currentProject.settings
        let panel = NSSavePanel()
        panel.allowedContentTypes = [settings.format.avFileType == .mov ? .quickTimeMovie : .mpeg4Movie]
        panel.nameFieldStringValue = "\(currentProject.name).\(settings.format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        enqueueExport(to: url)
    }

    /// 加入导出队列（串行执行，可在导出队列面板里取消）
    func enqueueExport(to url: URL) {
        guard !timeline.isEmpty else {
            showError("时间线是空的，先放点素材进来")
            return
        }
        // 队列是 @MainActor 的，这里把快照递过去
        let items = timeline
        let settings = currentProject.settings
        let title = currentProject.name
        Task { @MainActor in
            ExportQueue.shared.enqueue(title: title, items: items, settings: settings, to: url)
            let pending = ExportQueue.shared.pendingCount
            self.notify(pending > 1 ? "已加入导出队列（前面还有 \(pending - 1) 个）" : "已开始导出")
        }
    }

    // MARK: - 素材重连

    /// 扫一遍素材库和时间线，找出所有找不到文件的素材
    func scanMissingAssets() -> [AssetRelinker.Missing] {
        AssetRelinker.missing(
            libraryPaths: mediaLibrary.map { $0.url.path },
            timelinePaths: timeline.compactMap { $0.assetURL?.path },
            fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    /// 只更新缺失路径集合。素材变动后调一次就够，不用每次重绘都 stat 一遍文件
    func refreshMissingAssetCount() {
        missingAssetPaths = Set(scanMissingAssets().map(\.path))
    }

    /// 某个素材是不是已经找不到文件了（卡片上打标记用）
    func isAssetMissing(_ asset: MediaAsset) -> Bool {
        missingAssetPaths.contains(asset.url.path)
    }

    /// 打开重连面板（每次打开都重新扫，文件可能在别处已经修好了）
    func presentAssetRelink() {
        relinkCandidates = scanMissingAssets()
        showingAssetRelink = true
    }

    /// 把某个旧路径重连到新选的文件
    @discardableResult
    func relinkAsset(oldPath: String, to newURL: URL) -> Int {
        applyRelink([oldPath: newURL])
    }

    /// 选一个文件夹，按文件名批量匹配（整个目录被挪走时一次修完）
    @discardableResult
    func relinkAssets(inDirectory directory: URL) -> Int {
        let missing = relinkCandidates.isEmpty ? scanMissingAssets() : relinkCandidates
        guard !missing.isEmpty else {
            notify("没有需要重连的素材")
            return 0
        }
        let map = AssetRelinker.match(missing: missing,
                                      candidates: AssetRelinker.contents(of: directory))
        guard !map.isEmpty else {
            notify("「\(directory.lastPathComponent)」里没找到同名文件")
            return 0
        }
        return applyRelink(map)
    }

    /// 真正的落盘：改时间线引用 + 改素材库引用，其余字段一个不动
    @discardableResult
    private func applyRelink(_ map: [String: URL]) -> Int {
        guard !map.isEmpty else { return 0 }
        beginEdit()

        let (updated, changed) = AssetRelinker.apply(map, to: timeline)
        if changed > 0 { timeline = updated }

        // 素材库里的引用一并改，否则素材库里还会显示「找不到文件」
        for asset in mediaLibrary {
            guard let new = map[asset.url.path] else { continue }
            Task { await asset.relink(to: new) }
        }

        relinkCandidates = scanMissingAssets()
        refreshMissingAssetCount()
        if changed > 0 {
            notify("已重连 \(map.count) 个素材，\(changed) 个片段恢复正常")
        } else {
            notify("已重连 \(map.count) 个素材")
        }
        return changed
    }

    /// 把导出队列的状态接到顶部进度浮层上
    private func setupExportQueue() {
        Task { @MainActor in
        ExportQueue.shared.onActiveJobChange = { [weak self] job in
            guard let self else { return }
            if let job {
                self.processing = ProcessingState(title: "正在导出 \(job.title)",
                                                  message: job.message,
                                                  progress: max(0.02, job.progress))
            } else if self.processing?.title.hasPrefix("正在导出") == true {
                self.processing = nil
            }
        }
        ExportQueue.shared.onJobFinish = { [weak self] job in
            guard let self else { return }
            switch job.state {
            case .done:
                self.notify("导出完成：\(job.outputURL.lastPathComponent)")
            case .failed(let message):
                self.showError(message)
            case .cancelled:
                self.notify("已取消导出")
            default:
                break
            }
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
        var music = TimelineItem(type: .audio, name: "背景音乐 · Ambient", startTime: 0, duration: 20)
        music.trackLane = 0
        var voice = TimelineItem(type: .audio, name: "AI 配音 · 晓晓", startTime: 6.9, duration: 11.2)
        voice.trackLane = 1
        voice.properties.volume = 1.2

        timeline = [
            TimelineItem(type: .video, name: "品牌开场", startTime: 0, duration: 6),
            TimelineItem(type: .video, name: "产品特写", startTime: 6, duration: 10),
            TimelineItem(type: .aiGenerated, name: "AI 生成片段", startTime: 16, duration: 5),
            TimelineItem(type: .video, name: "片尾 Logo", startTime: 21, duration: 7),
            music,
            voice,
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
