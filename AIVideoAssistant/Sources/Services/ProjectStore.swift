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

struct ProjectSnapshot: Codable {
    var version: Int
    var project: VideoProject
    var media: [MediaRef]
    var timeline: [TimelineItem]
    var currentTime: Double
    var selectedItemID: UUID?

    init(project: VideoProject,
         media: [MediaRef] = [],
         timeline: [TimelineItem] = [],
         currentTime: Double = 0,
         selectedItemID: UUID? = nil) {
        self.version = 1
        self.project = project
        self.media = media
        self.timeline = timeline
        self.currentTime = currentTime
        self.selectedItemID = selectedItemID
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
