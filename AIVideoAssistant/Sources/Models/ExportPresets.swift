//
//  ExportPresets.swift
//  导出预设：一套分辨率 / 帧率 / 画质 / 画幅填充的组合
//
//  内置几套常用平台参数（横屏 1080p / 4K / 竖屏 / 方形），
//  用户也可以把当前设置存成自己的预设，存在
//  ~/Library/Application Support/AIVideoAssistant/export-presets.json。
//
//  内置预设用固定 UUID：这样「当前选中的是哪个预设」在重启后还对得上。
//

import Foundation

struct ExportPreset: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var resolution: ExportResolution
    var fps: Int
    var quality: ExportQuality
    var format: ExportFormat
    var fillMode: ExportFillMode
    var isBuiltin: Bool

    init(id: UUID = UUID(),
         name: String,
         resolution: ExportResolution,
         fps: Int = 30,
         quality: ExportQuality = .high,
         format: ExportFormat = .mp4,
         fillMode: ExportFillMode = .fit,
         isBuiltin: Bool = false) {
        self.id = id
        self.name = name
        self.resolution = resolution
        self.fps = fps
        self.quality = quality
        self.format = format
        self.fillMode = fillMode
        self.isBuiltin = isBuiltin
    }

    var settings: ExportSettings {
        ExportSettings(resolution: resolution,
                       fps: fps,
                       format: format,
                       quality: quality,
                       fillMode: fillMode)
    }

    /// 一行摘要：1080×1920 · 30fps · 高 · 填满
    var summary: String {
        "\(resolution.label) · \(fps)fps · \(quality.rawValue) · \(fillMode.shortLabel)"
    }

    /// 竖屏 / 方形画幅给个角标提示
    var aspectLabel: String { resolution.aspectLabel }

    func matches(_ settings: ExportSettings) -> Bool {
        self.settings == settings
    }
}

enum ExportPresetLibrary {

    // 固定 id，重启后「当前预设」还认得出
    private static let id1080 = UUID(uuidString: "E1A00000-0000-4000-8000-000000000001")!
    private static let id4K = UUID(uuidString: "E1A00000-0000-4000-8000-000000000002")!
    private static let idVertical = UUID(uuidString: "E1A00000-0000-4000-8000-000000000003")!
    private static let idVerticalDraft = UUID(uuidString: "E1A00000-0000-4000-8000-000000000004")!
    private static let idSquare = UUID(uuidString: "E1A00000-0000-4000-8000-000000000005")!
    private static let id60fps = UUID(uuidString: "E1A00000-0000-4000-8000-000000000006")!

    static let builtins: [ExportPreset] = [
        ExportPreset(id: id1080, name: "横屏 1080p",
                     resolution: .r1080p, fps: 30, quality: .high,
                     format: .mp4, fillMode: .fit, isBuiltin: true),
        ExportPreset(id: id4K, name: "横屏 4K",
                     resolution: .r4k, fps: 30, quality: .best,
                     format: .mp4, fillMode: .fit, isBuiltin: true),
        ExportPreset(id: idVertical, name: "竖屏 1080",
                     resolution: .vertical1080, fps: 30, quality: .high,
                     format: .mp4, fillMode: .fill, isBuiltin: true),
        ExportPreset(id: idVerticalDraft, name: "竖屏 720 草稿",
                     resolution: .vertical720, fps: 30, quality: .medium,
                     format: .mp4, fillMode: .fill, isBuiltin: true),
        ExportPreset(id: idSquare, name: "方形 1080",
                     resolution: .square1080, fps: 30, quality: .high,
                     format: .mp4, fillMode: .fill, isBuiltin: true),
        ExportPreset(id: id60fps, name: "横屏 60fps",
                     resolution: .r1080p, fps: 60, quality: .high,
                     format: .mp4, fillMode: .fit, isBuiltin: true)
    ]

    /// 当前设置正好等于某个预设时返回它（内置优先，因为内置排前面）
    static func matching(_ settings: ExportSettings,
                         in presets: [ExportPreset] = builtins) -> ExportPreset? {
        presets.first { $0.matches(settings) }
    }

    /// 把用户输入的名字整理成可用的预设名：
    /// 去首尾空白、空名字给默认值、重名自动加序号
    static func sanitizedName(_ raw: String, avoiding existing: [ExportPreset]) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "我的预设" }
        if name.count > 24 { name = String(name.prefix(24)) }
        let taken = Set(existing.map(\.name))
        guard taken.contains(name) else { return name }
        var index = 2
        while taken.contains("\(name) \(index)") { index += 1 }
        return "\(name) \(index)"
    }

    /// 用当前设置生成一个自定义预设
    static func makePreset(name: String,
                           settings: ExportSettings,
                           avoiding existing: [ExportPreset]) -> ExportPreset {
        ExportPreset(name: sanitizedName(name, avoiding: existing),
                     resolution: settings.resolution,
                     fps: settings.fps,
                     quality: settings.quality,
                     format: settings.format,
                     fillMode: settings.fillMode,
                     isBuiltin: false)
    }

    /// 同 id 覆盖，否则追加
    static func upserting(_ preset: ExportPreset, into presets: [ExportPreset]) -> [ExportPreset] {
        var result = presets
        if let index = result.firstIndex(where: { $0.id == preset.id }) {
            result[index] = preset
        } else {
            result.append(preset)
        }
        return result
    }

    static func removing(id: UUID, from presets: [ExportPreset]) -> [ExportPreset] {
        presets.filter { $0.id != id }
    }

    /// 内置 + 自定义
    static func all(custom: [ExportPreset]) -> [ExportPreset] {
        builtins + custom
    }
}

/// 自定义预设的落盘。`url` 参数留了注入口，测试可以写临时文件，不碰真实配置。
enum ExportPresetStore {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AIVideoAssistant/export-presets.json")
    }

    static func load(from url: URL? = nil) -> [ExportPreset] {
        let target = url ?? fileURL
        guard let data = try? Data(contentsOf: target) else { return [] }
        let presets = (try? JSONDecoder().decode([ExportPreset].self, from: data)) ?? []
        // 文件里混进内置预设时剔掉，免得出现两份同名预设
        return presets.filter { !$0.isBuiltin }
    }

    @discardableResult
    static func save(_ presets: [ExportPreset], to url: URL? = nil) -> Bool {
        let target = url ?? fileURL
        let custom = presets.filter { !$0.isBuiltin }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(custom)
            try data.write(to: target, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
