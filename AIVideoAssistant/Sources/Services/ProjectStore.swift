//
//  ProjectStore.swift
//  项目文件读写：~/Library/Application Support/AIVideoAssistant/Projects
//

import Foundation
import AppKit

/// 素材引用（不持久化 NSImage / 播放状态，只存路径）
struct MediaRef: Codable, Hashable {
    var id: UUID
    var path: String
    var name: String
    var type: MediaType
}

/// 素材集合：素材库里的自定义分组（一个素材可以同时属于多个集合）
struct MediaCollection: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    /// 按加入顺序保存，方便以后做手动排序
    var assetIDs: [UUID]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, assetIDs: [UUID] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.assetIDs = assetIDs
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, assetIDs, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名集合"
        assetIDs = try c.decodeIfPresent([UUID].self, forKey: .assetIDs) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    func contains(_ assetID: UUID) -> Bool {
        assetIDs.contains(assetID)
    }
}

struct ProjectSnapshot: Codable {
    var version: Int
    var project: VideoProject
    var media: [MediaRef]
    var timeline: [TimelineItem]
    var currentTime: Double
    var selectedItemID: UUID?
    /// v1.13 新增：老项目文件里没有这个字段，解码时补空数组
    var collections: [MediaCollection]

    init(project: VideoProject,
         media: [MediaRef] = [],
         timeline: [TimelineItem] = [],
         currentTime: Double = 0,
         selectedItemID: UUID? = nil,
         collections: [MediaCollection] = []) {
        self.version = 1
        self.project = project
        self.media = media
        self.timeline = timeline
        self.currentTime = currentTime
        self.selectedItemID = selectedItemID
        self.collections = collections
    }

    private enum CodingKeys: String, CodingKey {
        case version, project, media, timeline, currentTime, selectedItemID, collections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        project = try c.decode(VideoProject.self, forKey: .project)
        media = try c.decodeIfPresent([MediaRef].self, forKey: .media) ?? []
        timeline = try c.decodeIfPresent([TimelineItem].self, forKey: .timeline) ?? []
        currentTime = try c.decodeIfPresent(Double.self, forKey: .currentTime) ?? 0
        selectedItemID = try c.decodeIfPresent(UUID.self, forKey: .selectedItemID)
        collections = try c.decodeIfPresent([MediaCollection].self, forKey: .collections) ?? []
    }
}

struct ProjectSummary: Identifiable, Hashable {
    var id: UUID
    var project: VideoProject
    var clipCount: Int
    var duration: Double
}

final class ProjectStore {
    static let shared = ProjectStore()

    private let fm = FileManager.default

    private init() {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var directory: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AIVideoAssistant/Projects", isDirectory: true)
    }

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).aiva.json")
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func save(_ snapshot: ProjectSnapshot) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: url(for: snapshot.project.id), options: .atomic)
    }

    func load(id: UUID) throws -> ProjectSnapshot {
        try load(from: url(for: id))
    }

    func load(from url: URL) throws -> ProjectSnapshot {
        let data = try Data(contentsOf: url)
        return try decoder.decode(ProjectSnapshot.self, from: data)
    }

    func list() -> [ProjectSummary] {
        guard let files = try? fm.contentsOfDirectory(at: directory,
                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else {
            return []
        }
        var summaries: [ProjectSummary] = []
        for file in files where file.pathExtension == "json" {
            guard let snapshot = try? load(from: file) else { continue }
            let duration = snapshot.timeline.map(\.endTime).max() ?? 0
            summaries.append(ProjectSummary(id: snapshot.project.id,
                                            project: snapshot.project,
                                            clipCount: snapshot.timeline.count,
                                            duration: duration))
        }
        return summaries.sorted { $0.project.updatedAt > $1.project.updatedAt }
    }

    func delete(id: UUID) {
        try? fm.removeItem(at: url(for: id))
    }

    func reveal(id: UUID) {
        NSWorkspace.shared.activateFileViewerSelecting([url(for: id)])
    }
}
