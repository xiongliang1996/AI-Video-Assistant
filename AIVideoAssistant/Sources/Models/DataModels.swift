//
//  DataModels.swift
//  AI Video Assistant
//

import Foundation
import AppKit
import AVFoundation
import Combine

// MARK: - 视频项目

struct VideoProject: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var settings: ExportSettings

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.settings = ExportSettings()
    }
}

// MARK: - 导出设置

struct ExportSettings: Codable, Hashable {
    var resolution: ExportResolution = .r1080p
    var fps: Int = 30
    var format: ExportFormat = .mp4
    var quality: ExportQuality = .high
    /// 素材比例和画幅不一致时怎么办：留黑边还是裁切
    var fillMode: ExportFillMode = .fit

    init() {}

    init(resolution: ExportResolution,
         fps: Int = 30,
         format: ExportFormat = .mp4,
         quality: ExportQuality = .high,
         fillMode: ExportFillMode = .fit) {
        self.resolution = resolution
        self.fps = fps
        self.format = format
        self.quality = quality
        self.fillMode = fillMode
    }

    /// v1.17 及更早的项目文件没有 fillMode，缺字段时按「适应」处理
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resolution = (try? container.decodeIfPresent(ExportResolution.self, forKey: .resolution)) ?? .r1080p
        fps = (try? container.decodeIfPresent(Int.self, forKey: .fps)) ?? 30
        format = (try? container.decodeIfPresent(ExportFormat.self, forKey: .format)) ?? .mp4
        quality = (try? container.decodeIfPresent(ExportQuality.self, forKey: .quality)) ?? .high
        fillMode = (try? container.decodeIfPresent(ExportFillMode.self, forKey: .fillMode)) ?? .fit
    }

    /// 给界面看的一行摘要
    var summary: String {
        "\(resolution.label) · \(fps)fps · \(quality.rawValue) · \(fillMode.shortLabel)"
    }
}

enum ExportResolution: String, Codable, CaseIterable, Hashable {
    case r720p = "720p"
    case r1080p = "1080p"
    case r1440p = "1440p"
    case r4k = "4K"
    case vertical1080 = "竖屏 1080"
    case vertical720 = "竖屏 720"
    case square1080 = "方形 1080"

    var size: CGSize {
        switch self {
        case .r720p: return CGSize(width: 1280, height: 720)
        case .r1080p: return CGSize(width: 1920, height: 1080)
        case .r1440p: return CGSize(width: 2560, height: 1440)
        case .r4k: return CGSize(width: 3840, height: 2160)
        case .vertical1080: return CGSize(width: 1080, height: 1920)
        case .vertical720: return CGSize(width: 720, height: 1280)
        case .square1080: return CGSize(width: 1080, height: 1080)
        }
    }

    var label: String {
        switch self {
        case .r720p: return "1280×720"
        case .r1080p: return "1920×1080"
        case .r1440p: return "2560×1440"
        case .r4k: return "3840×2160"
        case .vertical1080: return "1080×1920"
        case .vertical720: return "720×1280"
        case .square1080: return "1080×1080"
        }
    }

    /// 竖屏 / 方形这类非 16:9 画幅，界面上要提示「素材会被裁切或留边」
    var isPortraitOrSquare: Bool {
        size.height >= size.width
    }

    var aspectLabel: String {
        switch self {
        case .r720p, .r1080p, .r1440p, .r4k: return "16:9"
        case .vertical1080, .vertical720: return "9:16"
        case .square1080: return "1:1"
        }
    }
}

enum ExportFillMode: String, Codable, CaseIterable, Hashable {
    case fit
    case fill

    var label: String {
        switch self {
        case .fit: return "适应（完整画面，可能留黑边）"
        case .fill: return "填满（铺满画幅，超出部分裁掉）"
        }
    }

    var shortLabel: String { self == .fit ? "适应" : "填满" }

    var icon: String {
        switch self {
        case .fit: return "arrow.down.right.and.arrow.up.left"
        case .fill: return "arrow.up.left.and.arrow.down.right"
        }
    }
}

enum ExportFormat: String, Codable, CaseIterable, Hashable {
    case mp4 = "MP4"
    case mov = "MOV"

    var fileExtension: String { self == .mp4 ? "mp4" : "mov" }
    var avFileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

enum ExportQuality: String, Codable, CaseIterable, Hashable {
    case medium = "中等"
    case high = "高"
    case best = "最佳"

    var preset: String {
        switch self {
        case .medium: return AVAssetExportPresetMediumQuality
        case .high: return AVAssetExportPresetHighestQuality
        case .best: return AVAssetExportPreset1920x1080
        }
    }
}

// MARK: - 媒体资产

enum MediaType: String, Codable {
    case video, audio, image

    static func detect(from url: URL) -> MediaType {
        switch url.pathExtension.lowercased() {
        case "mp3", "wav", "aac", "m4a", "flac", "ogg", "wma":
            return .audio
        case "jpg", "jpeg", "png", "gif", "bmp", "webp", "tiff", "heic":
            return .image
        default:
            return .video
        }
    }

    var icon: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        }
    }

    var label: String {
        switch self {
        case .video: return "视频"
        case .audio: return "音频"
        case .image: return "图片"
        }
    }

    /// 排序与分组时的固定顺序：视频 → 音频 → 图片
    var sortOrder: Int {
        switch self {
        case .video: return 0
        case .audio: return 1
        case .image: return 2
        }
    }
}

final class MediaAsset: ObservableObject, Identifiable {
    let id: UUID
    /// 路径可变：素材被移动 / 改名后要能重连到新位置，id 保持不变
    /// 才能让集合归属和时间线引用都对得上
    @Published private(set) var url: URL
    @Published private(set) var type: MediaType

    @Published var name: String
    @Published var duration: Double = 0
    @Published var resolution: CGSize = .zero
    @Published var thumbnail: NSImage?
    @Published var isLoading = false

    /// id 可指定：项目重新加载时沿用文件里的 id，
    /// 否则每次启动都会换一批 UUID，集合成员与片段引用都会对不上
    init(url: URL, id: UUID = UUID()) {
        self.id = id
        self.url = url
        self.type = MediaType.detect(from: url)
        self.name = url.lastPathComponent
    }

    var durationText: String {
        guard duration > 0 else { return "--:--" }
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// 重连到新位置：只换路径，id 与集合归属原样保留。
    /// 元数据（时长 / 尺寸 / 缩略图）重新读一遍，因为新文件可能不是同一个素材
    func relink(to newURL: URL) async {
        url = newURL
        type = MediaType.detect(from: newURL)
        name = newURL.lastPathComponent
        duration = 0
        resolution = .zero
        thumbnail = nil
        await loadMetadata()
    }

    func loadMetadata() async {
        await MainActor.run { self.isLoading = true }
        let asset = AVURLAsset(url: url)

        var loadedDuration: Double = 0
        var loadedSize: CGSize = .zero

        do {
            loadedDuration = CMTimeGetSeconds(try await asset.load(.duration))
        } catch {
            // 之前是 try? 静默吞掉：导入坏文件后用户只看到 0 秒素材，一点线索都没有
            AppLog.error(.media, "读取时长失败 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
        do {
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                loadedSize = try await track.load(.naturalSize)
            }
        } catch {
            AppLog.error(.media, "读取画面尺寸失败 \(url.lastPathComponent)：\(error.localizedDescription)")
        }

        var image: NSImage?
        if type != .audio {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 270)
            if let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }

        let dur = loadedDuration
        let size = loadedSize
        if dur <= 0 {
            // 文件不在了 / 编码不认识，都会走到这里。素材在时间线上占 0 秒，看起来像「拖进去没反应」
            let exists = FileManager.default.fileExists(atPath: url.path)
            AppLog.warning(.media, "素材时长为 0 \(url.lastPathComponent)（文件\(exists ? "存在" : "不存在")）")
        }
        let box = ImageBox(image: image)
        await MainActor.run {
            self.duration = dur
            self.resolution = size
            self.thumbnail = box.image
            self.isLoading = false
        }
    }
}

/// 用于跨 actor 传递 NSImage 的轻量包装（NSImage 本身非 Sendable）
private struct ImageBox: @unchecked Sendable {
    let image: NSImage?
}

// MARK: - 时间线

enum TimelineItemType: String, Codable, CaseIterable {
    case video, audio, text, subtitle, aiGenerated

    var label: String {
        switch self {
        case .video: return "视频"
        case .audio: return "音频"
        case .text: return "文字"
        case .subtitle: return "字幕"
        case .aiGenerated: return "AI 生成"
        }
    }

    var icon: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        case .text: return "textformat"
        case .subtitle: return "captions.bubble"
        case .aiGenerated: return "sparkles"
        }
    }
}

/// 时间线轨道分类（决定片段落在哪条轨道上）
enum TimelineTrack: String, Codable, Hashable {
    case video, audio, subtitle
}

/// 转场类型：作用于片段入点，与前一个片段做过渡
enum TransitionType: String, Codable, CaseIterable, Hashable {
    case none
    case crossDissolve
    case fadeThroughBlack
    case slideLeft
    case zoomIn

    var label: String {
        switch self {
        case .none: return "无"
        case .crossDissolve: return "交叉溶解"
        case .fadeThroughBlack: return "黑场过渡"
        case .slideLeft: return "左滑推入"
        case .zoomIn: return "缩放推入"
        }
    }

    var icon: String {
        switch self {
        case .none: return "minus"
        case .crossDissolve: return "circle.lefthalf.filled"
        case .fadeThroughBlack: return "moon.fill"
        case .slideLeft: return "arrow.left.square"
        case .zoomIn: return "plus.magnifyingglass"
        }
    }
}

/// 转场是否真的会渲染。
/// 判定规则与 CompositionBuilder 完全一致：相邻摆放、前一段有素材余量、重叠时长够用。
enum TransitionStatus: Equatable {
    /// 没设转场
    case unset
    /// 会生效，实际重叠 overlap 秒
    case active(overlap: Double)
    /// 前面没有可衔接的片段
    case noPrevious
    /// 与前一段之间有空隙
    case gap(Double)
    /// 与前一段重叠摆放
    case overlap(Double)
    /// 前一段素材已用尽，没有多余尾巴可吃
    case noTail
    /// 能算出来的重叠太短
    case tooShort(Double)

    var isProblem: Bool {
        switch self {
        case .unset, .active: return false
        default: return true
        }
    }

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .unset:
            return "未设置转场"
        case .active(let overlap):
            return String(format: "已生效 · 重叠 %.1f s", overlap)
        case .noPrevious:
            return "前面没有片段，转场无处衔接"
        case .gap(let value):
            return String(format: "与前一段间隔 %.2f s，不会生成转场", value)
        case .overlap(let value):
            return String(format: "与前一段重叠 %.2f s，不会生成转场", value)
        case .noTail:
            return "上一段素材已用尽，没有多余尾巴"
        case .tooShort(let value):
            return String(format: "可用重叠只有 %.2f s，低于 0.12 s", value)
        }
    }

    /// 一句话修复建议（为空表示不需要处理）
    var hint: String? {
        switch self {
        case .unset, .active:
            return nil
        case .noPrevious:
            return "把这一段移到某个片段后面，或给它前面补一段素材"
        case .gap:
            return "点「吸附到上一段」把它贴上去"
        case .overlap:
            return "点「吸附到上一段」消除重叠，或直接右移让两段相接"
        case .noTail:
            return "把上一段的右边缘往回缩一点，给它留出可用的尾巴"
        case .tooShort:
            return "把两段留长一些，或给上一段多留点尾巴"
        }
    }

    /// 是否可以用「吸附到上一段」一键修复
    var canSnap: Bool {
        switch self {
        case .gap, .overlap: return true
        default: return false
        }
    }

    var icon: String {
        switch self {
        case .unset: return "minus"
        case .active: return "checkmark.circle.fill"
        case .noPrevious: return "questionmark.circle"
        case .gap, .overlap: return "arrow.left.and.right"
        case .noTail: return "scissors"
        case .tooShort: return "timer"
        }
    }
}

/// 关键帧之间的补间方式
enum Easing: String, Codable, CaseIterable, Identifiable {
    case linear, easeIn, easeOut, easeInOut

    var id: String { rawValue }

    var label: String {
        switch self {
        case .linear: return "线性"
        case .easeIn: return "缓入"
        case .easeOut: return "缓出"
        case .easeInOut: return "缓入缓出"
        }
    }

    var icon: String {
        switch self {
        case .linear: return "line.diagonal"
        case .easeIn: return "chart.line.uptrend.xyaxis"
        case .easeOut: return "chart.line.downtrend.xyaxis"
        case .easeInOut: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    /// 把 0…1 的线性进度映射成缓动后的进度
    func apply(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        switch self {
        case .linear: return x
        case .easeIn: return x * x
        case .easeOut: return 1 - (1 - x) * (1 - x)
        case .easeInOut:
            return x < 0.5 ? 2 * x * x : 1 - 2 * (1 - x) * (1 - x)
        }
    }
}

/// 一个关键帧：时间相对片段起点（秒），值为该属性的取值
/// easing 描述「从这个关键帧到下一个」的补间方式
struct Keyframe: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var time: Double
    var value: Double
    var easing: Easing = .linear

    init(time: Double, value: Double, easing: Easing = .linear) {
        self.time = max(0, time)
        self.value = value
        self.easing = easing
    }

    enum CodingKeys: String, CodingKey {
        case id, time, value, easing
    }

    // 旧存档没有 easing 字段，回落线性
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        time = try c.decodeIfPresent(Double.self, forKey: .time) ?? 0
        value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
        easing = try c.decodeIfPresent(Easing.self, forKey: .easing) ?? .linear
    }
}

/// 支持关键帧动画的属性
enum AnimatableProperty: String, Codable, CaseIterable, Identifiable {
    case scale, opacity, volume

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scale: return "缩放"
        case .opacity: return "不透明度"
        case .volume: return "音量"
        }
    }

    var unit: String {
        switch self {
        case .scale: return "×"
        case .opacity: return ""
        case .volume: return "×"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .scale: return 0.2...3.0
        case .opacity: return 0...1
        case .volume: return 0...2
        }
    }

    /// 该属性在片段属性里的静态取值（没有关键帧时用它）
    func staticValue(_ p: ItemProperties) -> Double {
        switch self {
        case .scale: return p.scale
        case .opacity: return p.opacity
        case .volume: return p.volume
        }
    }
}

// MARK: - 画中画

/// 画中画贴在画幅的哪个角
enum PiPPosition: String, Codable, CaseIterable, Hashable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
    case center

    var label: String {
        switch self {
        case .topLeading: return "左上"
        case .topTrailing: return "右上"
        case .bottomLeading: return "左下"
        case .bottomTrailing: return "右下"
        case .center: return "居中"
        }
    }

    var icon: String {
        switch self {
        case .topLeading: return "arrow.up.left"
        case .topTrailing: return "arrow.up.right"
        case .bottomLeading: return "arrow.down.left"
        case .bottomTrailing: return "arrow.down.right"
        case .center: return "dot.circle"
        }
    }
}

/// 归一化坐标（0…1，y 向下）。存成两个 Double 而不是 CGPoint，
/// 项目文件是给人看得懂的 JSON，`{"x":0.68,"y":0.72}` 比一串数组清楚。
struct NormalizedPoint: Codable, Hashable {
    var x: Double
    var y: Double
}

/// 画中画的几何：只描述「多大、放哪儿」，不涉及素材本身。
/// 数值都用占画幅的比例表示，换导出分辨率时不用重设。
struct PiPStyle: Codable, Hashable {
    /// 画中画宽度占画幅宽度的比例
    var widthRatio: Double = 0.32
    var position: PiPPosition = .bottomTrailing
    /// 贴边留白，占画幅宽度的比例
    var margin: Double = 0.03
    /// 自由位置：画中画左上角的归一化坐标。
    /// nil 表示按 `position` 贴边——九宫格按钮点一下就会清空它，
    /// 所以在预览台上拖过之后，点九宫格能立刻回到整齐的贴边位。
    var freeOrigin: NormalizedPoint?

    /// 允许的范围，界面滑杆和引擎都按这个夹一次
    static let widthRange: ClosedRange<Double> = 0.1...0.75
    static let marginRange: ClosedRange<Double> = 0...0.12

    init() {}

    enum CodingKeys: String, CodingKey { case widthRatio, position, margin, freeOrigin }

    /// 旧项目文件没有这几个字段，缺了就按默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        widthRatio = try c.decodeIfPresent(Double.self, forKey: .widthRatio) ?? 0.32
        position = try c.decodeIfPresent(PiPPosition.self, forKey: .position) ?? .bottomTrailing
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? 0.03
        freeOrigin = try c.decodeIfPresent(NormalizedPoint.self, forKey: .freeOrigin)
    }

    /// 夹到合法区间，防止滑杆外的数值把 transform 算成 NaN 或飞出画幅
    var sanitized: PiPStyle {
        var copy = self
        copy.widthRatio = min(max(widthRatio, PiPStyle.widthRange.lowerBound),
                              PiPStyle.widthRange.upperBound)
        copy.margin = min(max(margin, PiPStyle.marginRange.lowerBound),
                          PiPStyle.marginRange.upperBound)
        if !copy.widthRatio.isFinite { copy.widthRatio = 0.32 }
        if !copy.margin.isFinite { copy.margin = 0.03 }
        if let f = copy.freeOrigin {
            let x = f.x.isFinite ? min(max(f.x, 0), 1) : 0
            let y = f.y.isFinite ? min(max(f.y, 0), 1) : 0
            copy.freeOrigin = NormalizedPoint(x: x, y: y)
        }
        return copy
    }

    var summary: String {
        let place = freeOrigin == nil ? position.label : "自由位置"
        return "\(Int((widthRatio * 100).rounded()))% · \(place)"
    }
}

struct ItemProperties: Codable, Hashable {
    var scale: Double = 1.0
    var rotation: Double = 0
    var opacity: Double = 1.0
    var volume: Double = 1.0
    var speed: Double = 1.0
    var fadeIn: Double = 0.5
    var fadeOut: Double = 0.5
    var textContent: String = ""
    var fontSize: Int = 28

    // MARK: 字幕 / 文字样式（按 1080p 画布为基准，渲染时按比例缩放）
    /// 文字颜色 0xRRGGBB
    var textColorHex: Int = 0xFFFFFF
    /// 文字底衬不透明度，0 表示无底衬
    var textBoxOpacity: Double = 0.42
    /// 文字距画面底部的比例（0 贴底，1 顶部）
    var textOffsetY: Double = 0.12
    var textBold: Bool = true

    /// 关键帧：key = AnimatableProperty.rawValue，时间相对片段起点
    var keyframes: [String: [Keyframe]] = [:]

    /// 画中画几何（只有落在 V2 层的视频片段才用得上）
    var pip: PiPStyle = PiPStyle()

    init() {}

    // 手写解码：新增字段在旧存档里缺失时回落到默认值
    enum CodingKeys: String, CodingKey {
        case scale, rotation, opacity, volume, speed, fadeIn, fadeOut
        case textContent, fontSize
        case textColorHex, textBoxOpacity, textOffsetY, textBold
        case keyframes, pip
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0.5
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0.5
        textContent = try c.decodeIfPresent(String.self, forKey: .textContent) ?? ""
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? 28
        textColorHex = try c.decodeIfPresent(Int.self, forKey: .textColorHex) ?? 0xFFFFFF
        textBoxOpacity = try c.decodeIfPresent(Double.self, forKey: .textBoxOpacity) ?? 0.42
        textOffsetY = try c.decodeIfPresent(Double.self, forKey: .textOffsetY) ?? 0.12
        textBold = try c.decodeIfPresent(Bool.self, forKey: .textBold) ?? true
        keyframes = try c.decodeIfPresent([String: [Keyframe]].self, forKey: .keyframes) ?? [:]
        pip = try c.decodeIfPresent(PiPStyle.self, forKey: .pip) ?? PiPStyle()
    }

    // MARK: 关键帧

    func keyframes(for property: AnimatableProperty) -> [Keyframe] {
        (keyframes[property.rawValue] ?? []).sorted { $0.time < $1.time }
    }

    mutating func setKeyframes(_ list: [Keyframe], for property: AnimatableProperty) {
        if list.isEmpty {
            keyframes[property.rawValue] = nil
        } else {
            keyframes[property.rawValue] = list.sorted { $0.time < $1.time }
        }
    }

    var hasAnyKeyframes: Bool {
        keyframes.values.contains { !$0.isEmpty }
    }

    /// 采样：没有关键帧时返回静态值；有则按时间线性插值（两端保持端点值）
    func animatedValue(_ property: AnimatableProperty, at time: Double) -> Double {
        let list = keyframes(for: property)
        guard let first = list.first, let last = list.last else {
            return property.staticValue(self)
        }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        for index in 1..<list.count {
            let a = list[index - 1]
            let b = list[index]
            if time >= a.time && time <= b.time {
                let span = b.time - a.time
                guard span > 0.0001 else { return b.value }
                // 缓动由「起点关键帧」决定，作用到这一段的进度上
                let ratio = a.easing.apply((time - a.time) / span)
                return a.value + (b.value - a.value) * ratio
            }
        }
        return last.value
    }

    /// 生成渲染用的采样点：片段起点、每个关键帧、片段终点
    /// AVFoundation 的 ramp 只能线性，所以缓动段要拆成若干小段来逼近曲线
    /// - Returns: [(相对片段时间, 值)]
    func animationSamples(_ property: AnimatableProperty, duration: Double) -> [(time: Double, value: Double)] {
        let list = keyframes(for: property).filter { $0.time <= duration + 0.001 }
        guard !list.isEmpty else { return [] }

        // 先把「关键帧 + 首尾」整理成基础节点
        var nodes: [(time: Double, value: Double, easing: Easing)] = [(0, animatedValue(property, at: 0), list.first?.easing ?? .linear)]
        for frame in list where frame.time > 0.001 && frame.time < duration - 0.001 {
            nodes.append((frame.time, frame.value, frame.easing))
        }
        nodes.append((duration, animatedValue(property, at: duration), .linear))

        // 缓动段再细分：每 0.06 s 一个点，最多 24 段
        var points: [(time: Double, value: Double)] = []
        for index in 0..<(nodes.count - 1) {
            let a = nodes[index]
            let b = nodes[index + 1]
            points.append((a.time, a.value))
            let span = b.time - a.time
            guard span > 0.001, a.easing != .linear else { continue }
            let steps = min(24, max(2, Int((span / 0.06).rounded())))
            for step in 1..<steps {
                let ratio = Double(step) / Double(steps)
                let eased = a.easing.apply(ratio)
                points.append((a.time + span * ratio, a.value + (b.value - a.value) * eased))
            }
        }
        if let last = nodes.last {
            points.append((last.time, last.value))
        }
        return points
    }
}

struct TimelineItem: Identifiable, Hashable, Codable {
    var id: UUID
    var assetID: UUID?
    var type: TimelineItemType
    var name: String
    var startTime: Double
    var duration: Double
    /// 素材内的入点（裁剪左边界时递增）
    var sourceStart: Double
    /// 入点转场
    var transition: TransitionType
    var transitionDuration: Double
    /// 同类轨道内的层号（音频 A1 / A2 …），0 为第一层
    var trackLane: Int
    var properties: ItemProperties
    var assetURL: URL?

    init(type: TimelineItemType,
         name: String,
         startTime: Double,
         duration: Double,
         assetID: UUID? = nil,
         assetURL: URL? = nil) {
        self.id = UUID()
        self.type = type
        self.name = name
        self.startTime = startTime
        self.duration = duration
        self.assetID = assetID
        self.assetURL = assetURL
        self.sourceStart = 0
        self.transition = .none
        self.transitionDuration = 0.6
        self.trackLane = 0
        self.properties = ItemProperties()
    }

    var endTime: Double { startTime + duration }

    var trackKind: TimelineTrack {
        switch type {
        case .video, .aiGenerated: return .video
        case .audio: return .audio
        case .subtitle, .text: return .subtitle
        }
    }

    /// 视频第二层（V2）上的片段是画中画：缩小浮在主画面之上，不占满画幅。
    /// 音频 / 字幕的层号是另一套含义，别混用。
    var isOverlay: Bool {
        trackKind == .video && trackLane >= 1
    }

    /// 该类型轨道最多支持几层
    static func laneCount(for kind: TimelineTrack) -> Int {
        switch kind {
        case .video: return 2
        case .audio: return 2
        case .subtitle: return 1
        }
    }

    /// 层号的显示名：视频 V1/V2，音频 A1/A2
    static func laneName(for kind: TimelineTrack, lane: Int) -> String {
        switch kind {
        case .video: return "V\(lane + 1)"
        case .audio: return "A\(lane + 1)"
        case .subtitle: return "S\(lane + 1)"
        }
    }

    // MARK: Codable（对旧版本文件保持容错）

    enum CodingKeys: String, CodingKey {
        case id, assetID, type, name, startTime, duration
        case sourceStart, transition, transitionDuration, trackLane, properties, assetURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        assetID = try c.decodeIfPresent(UUID.self, forKey: .assetID)
        type = try c.decode(TimelineItemType.self, forKey: .type)
        name = try c.decode(String.self, forKey: .name)
        startTime = try c.decode(Double.self, forKey: .startTime)
        duration = try c.decode(Double.self, forKey: .duration)
        sourceStart = try c.decodeIfPresent(Double.self, forKey: .sourceStart) ?? 0
        transition = try c.decodeIfPresent(TransitionType.self, forKey: .transition) ?? .none
        transitionDuration = try c.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? 0.6
        trackLane = try c.decodeIfPresent(Int.self, forKey: .trackLane) ?? 0
        properties = try c.decodeIfPresent(ItemProperties.self, forKey: .properties) ?? ItemProperties()
        assetURL = try c.decodeIfPresent(URL.self, forKey: .assetURL)
    }
}

// MARK: - AI 配置

struct AIConfig: Codable, Hashable {
    var openAIKey: String = ""
    var openAIBaseURL: String = "https://api.openai.com/v1"
    var imageModel: String = "dall-e-3"
    var whisperModel: String = "whisper-1"

    var ttsProvider: TTSProvider = .openAI
    var azureKey: String = ""
    var azureRegion: String = "eastasia"
    var xfyunAppID: String = ""
    var xfyunAPIKey: String = ""
    var xfyunAPISecret: String = ""
}

enum TTSProvider: String, Codable, CaseIterable, Hashable {
    case openAI = "OpenAI"
    case azure = "Azure"
    case xfyun = "讯飞"

    var summary: String {
        switch self {
        case .openAI: return "OpenAI TTS，简洁易用，音色自然"
        case .azure: return "微软 Azure，音色丰富，中英文优秀"
        case .xfyun: return "讯飞语音，中文效果好，支持情感语音"
        }
    }
}

// MARK: - 字幕

struct SubtitleEntry: Identifiable, Hashable {
    let id = UUID()
    var index: Int
    var startTime: Double
    var endTime: Double
    var text: String

    var timecode: String {
        SubtitleParser.formatSRTTime(startTime)
    }
}

enum SubtitleParser {
    static func parseSRT(_ srt: String) -> [SubtitleEntry] {
        var entries: [SubtitleEntry] = []
        let normalized = srt.replacingOccurrences(of: "\r\n", with: "\n")
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
            guard lines.count >= 2 else { continue }
            let index = Int(lines[0]) ?? entries.count + 1
            let times = lines[1].components(separatedBy: "-->")
            guard times.count == 2 else { continue }
            let start = parseTime(times[0])
            let end = parseTime(times[1])
            let text = lines.dropFirst(2).joined(separator: " ")
            guard !text.isEmpty else { continue }
            entries.append(SubtitleEntry(index: index, startTime: start, endTime: end, text: text))
        }
        return entries
    }

    static func toSRT(_ entries: [SubtitleEntry]) -> String {
        entries.enumerated().map { offset, entry in
            "\(offset + 1)\n\(formatSRTTime(entry.startTime)) --> \(formatSRTTime(entry.endTime))\n\(entry.text)\n"
        }.joined(separator: "\n")
    }

    static func parseTime(_ raw: String) -> Double {
        let cleaned = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.components(separatedBy: ":")
        guard parts.count == 3 else { return 0 }
        return (Double(parts[0]) ?? 0) * 3600
            + (Double(parts[1]) ?? 0) * 60
            + (Double(parts[2]) ?? 0)
    }

    static func formatSRTTime(_ time: Double) -> String {
        let h = Int(time) / 3600
        let m = Int(time) % 3600 / 60
        let s = Int(time) % 60
        let ms = Int((time - Double(Int(time))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}

// MARK: - 通用工具

/// 时间线排布计算（纯函数，便于单测）
enum TimelineLayout {
    /// 从期望位置开始，找一段不与已有片段重叠的起点。
    /// 冲突时把起点推到冲突片段的末尾，继续往后找。
    static func freeStart(existing: [TimelineItem], desired: Double, duration: Double) -> Double {
        guard duration > 0 else { return max(0, desired) }
        var start = max(0, desired)
        let sorted = existing.sorted { $0.startTime < $1.startTime }

        var moved = true
        var guardCount = 0
        while moved && guardCount < 200 {
            moved = false
            guardCount += 1
            for clip in sorted {
                let overlaps = start < clip.endTime - 0.001 && start + duration > clip.startTime + 0.001
                if overlaps {
                    start = clip.endTime
                    moved = true
                }
            }
        }
        return start
    }

    /// 两个时间区间是否重叠
    static func overlaps(_ aStart: Double, _ aEnd: Double, _ bStart: Double, _ bEnd: Double) -> Bool {
        aStart < bEnd - 0.001 && aEnd > bStart + 0.001
    }

    // MARK: 智能剪辑用到的纯函数

    /// 合并重叠 / 相邻的时间区间，并按起点排序
    static func mergeRanges(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        let sorted = ranges
            .map { max(0, $0.lowerBound)...max(0, $0.upperBound) }
            .filter { $0.upperBound - $0.lowerBound > 0.001 }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound + 0.001 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// 某时刻之前一共被删掉了多少秒
    static func removedBefore(_ time: Double, ranges: [ClosedRange<Double>]) -> Double {
        var total: Double = 0
        for range in ranges {
            if range.upperBound <= time {
                total += range.upperBound - range.lowerBound
            } else if range.lowerBound < time {
                total += time - range.lowerBound
            }
        }
        return total
    }

    /// 区间 [start, end) 减去要删掉的部分，返回保留下来的若干段
    static func subtract(_ start: Double, _ end: Double,
                         ranges: [ClosedRange<Double>]) -> [(start: Double, end: Double)] {
        guard end > start else { return [] }
        var kept: [(start: Double, end: Double)] = []
        var cursor = start
        for range in ranges where range.upperBound > start && range.lowerBound < end {
            if range.lowerBound > cursor {
                kept.append((cursor, min(end, range.lowerBound)))
            }
            cursor = max(cursor, range.upperBound)
            if cursor >= end { break }
        }
        if cursor < end { kept.append((cursor, end)) }
        return kept.filter { $0.end - $0.start > 0.05 }
    }

    /// 在若干时间点把片段切开（时间点须落在片段内部）
    static func split(_ item: TimelineItem, at times: [Double]) -> [TimelineItem] {
        let points = times
            .filter { $0 > item.startTime + 0.05 && $0 < item.endTime - 0.05 }
            .sorted()
        guard !points.isEmpty else { return [item] }

        let speed = max(0.1, item.properties.speed)
        var pieces: [TimelineItem] = []
        var cursor = item.startTime
        for point in points + [item.endTime] {
            guard point > cursor + 0.01 else { continue }
            var piece = item
            piece.id = UUID()
            piece.startTime = cursor
            piece.duration = point - cursor
            piece.sourceStart = item.sourceStart + (cursor - item.startTime) * speed
            piece.transition = .none
            pieces.append(piece)
            cursor = point
        }
        return pieces.isEmpty ? [item] : pieces
    }

    /// 波纹删除：删掉若干时间区间，并把后面的内容整体前移
    /// - 完全落在区间内的片段会被丢弃，被截断的片段会拆成多段
    static func rippleDelete(items: [TimelineItem], ranges: [ClosedRange<Double>]) -> [TimelineItem] {
        let cuts = mergeRanges(ranges)
        guard !cuts.isEmpty else { return items }

        var result: [TimelineItem] = []
        for item in items {
            let speed = max(0.1, item.properties.speed)
            let kept = subtract(item.startTime, item.endTime, ranges: cuts)
            guard !kept.isEmpty else { continue }

            if kept.count == 1,
               abs(kept[0].start - item.startTime) < 0.001,
               abs(kept[0].end - item.endTime) < 0.001 {
                // 完全没被切到，只需整体前移
                var moved = item
                moved.startTime = max(0, item.startTime - removedBefore(item.startTime, ranges: cuts))
                result.append(moved)
                continue
            }

            for part in kept {
                var piece = item
                piece.id = UUID()
                piece.startTime = max(0, part.start - removedBefore(part.start, ranges: cuts))
                piece.duration = part.end - part.start
                piece.sourceStart = item.sourceStart + (part.start - item.startTime) * speed
                piece.transition = .none
                result.append(piece)
            }
        }
        return result.sorted { $0.startTime < $1.startTime }
    }

    // MARK: 转场诊断用到的纯函数

    /// 相邻判定的容差，与 builder 保持一致
    static let transitionContiguity: Double = 0.06
    /// 低于这个重叠时长就不做转场了
    static let transitionMinOverlap: Double = 0.12
    /// 单次转场的最长时长
    static let transitionMaxOverlap: Double = 1.5

    /// 诊断某段片段的入场转场能不能生效。
    /// - Parameters:
    ///   - previous: 同轨道同层、起点更早的最近一段
    ///   - previousAssetDuration: 上一段素材的原始时长；拿不到时跳过「素材余量」检查
    static func transitionStatus(for item: TimelineItem,
                                 previous: TimelineItem?,
                                 previousAssetDuration: Double? = nil) -> TransitionStatus {
        guard item.transition != .none else { return .unset }
        guard let prev = previous else { return .noPrevious }

        // 1. 必须紧贴：重叠摆放不会生成转场指令
        let gap = item.startTime - prev.endTime
        if gap > transitionContiguity { return .gap(gap) }
        if gap < -transitionContiguity { return .overlap(-gap) }

        let prevSpeed = min(max(prev.properties.speed, 0.1), 4.0)
        var budget = min(item.transitionDuration, prev.duration * 0.5, item.duration * 0.5)

        // 2. 前一段必须还有没被用掉的素材，转场靠吃这段尾巴
        if let assetDuration = previousAssetDuration, assetDuration > 0 {
            let available = assetDuration - max(0, prev.sourceStart)
            let consumed = min(prev.duration, available / prevSpeed) * prevSpeed
            let extraSource = available - consumed
            guard extraSource > 0.02 else { return .noTail }
            budget = min(budget, extraSource / prevSpeed)
        }

        budget = min(budget, transitionMaxOverlap)
        guard budget >= transitionMinOverlap else { return .tooShort(max(0, budget)) }
        return .active(overlap: budget)
    }

    /// 把片段贴到前一段末尾后，是否会和后面的片段撞上
    /// - Returns: 吸附后的起点；撞车时返回 nil
    static func snappedStart(item: TimelineItem,
                             previousEnd: Double,
                             nextStart: Double) -> Double? {
        let target = max(0, previousEnd)
        guard abs(target - item.startTime) > 0.001 else { return nil }
        if nextStart.isFinite, target + item.duration > nextStart + 0.001 { return nil }
        return target
    }
}

func formatTimecode(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return String(format: "%02d:%02d", m, s)
}
