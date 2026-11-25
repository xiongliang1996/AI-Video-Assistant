//
//  MediaShelf.swift
//  素材库的检索 / 排序 / 分组规则
//
//  全部是纯函数：不碰 SwiftUI、不碰 AppState，方便直接跑单测。
//

import Foundation

// MARK: - 排序方式

enum MediaSort: String, CaseIterable, Identifiable {
    case added
    case name
    case duration
    case type

    var id: String { rawValue }

    var label: String {
        switch self {
        case .added: return "导入顺序"
        case .name: return "名称"
        case .duration: return "时长"
        case .type: return "类型"
        }
    }

    var icon: String {
        switch self {
        case .added: return "clock.arrow.circlepath"
        case .name: return "textformat.abc"
        case .duration: return "timer"
        case .type: return "square.grid.2x2"
        }
    }

    /// 「导入顺序」反着排就是最新在前，语义清楚，其余都允许双向
    var supportsDescending: Bool { self != .added }
}

// MARK: - 查询条件

struct MediaQuery: Equatable {
    var search: String = ""
    var type: MediaType?
    var unusedOnly: Bool = false
    /// 只看某个素材集合里的成员
    var collectionID: UUID?
    var sort: MediaSort = .added
    var descending: Bool = false

    /// 搜索词按空白切分，必须全部命中（AND）。
    /// 这样「采访 1080」这类多条件能直接叠着打。
    var keywords: [String] {
        search
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased() }
    }

    var isFiltering: Bool {
        !keywords.isEmpty || type != nil || unusedOnly || collectionID != nil
    }
}

// MARK: - 引用统计

/// 时间线上每个素材被用了多少次。
/// 优先按 assetID 对；老项目里 assetID 可能没存，再退回按文件路径对。
struct MediaUsage {
    var byID: [UUID: Int] = [:]
    var byPath: [String: Int] = [:]

    static let empty = MediaUsage()

    func count(_ asset: MediaAsset) -> Int {
        byID[asset.id] ?? byPath[asset.url.path] ?? 0
    }

    var isEmpty: Bool { byID.isEmpty && byPath.isEmpty }
}

/// 集合胶囊上显示的信息（数量只算库里还在的成员）
struct CollectionInfo: Identifiable, Hashable {
    let id: UUID
    let name: String
    let count: Int
}

// MARK: - 分组结果
struct MediaSection: Identifiable {
    /// nil 表示不分组（平铺）
    let type: MediaType?
    let assets: [MediaAsset]

    var id: String { type?.rawValue ?? "all" }

    var title: String { type?.label ?? "全部素材" }

    var icon: String { type?.icon ?? "square.stack" }
}

// MARK: - 各类素材的数量（给筛选胶囊用）

struct MediaTypeCounts {
    var video = 0
    var audio = 0
    var image = 0

    var total: Int { video + audio + image }

    /// type == nil 表示「全部」
    subscript(type: MediaType?) -> Int {
        switch type {
        case .none: return total
        case .some(.video): return video
        case .some(.audio): return audio
        case .some(.image): return image
        }
    }
}

// MARK: - 规则本体

enum MediaShelf {

    /// 统计时间线引用
    static func usage(in timeline: [TimelineItem]) -> MediaUsage {
        var result = MediaUsage()
        for item in timeline {
            if let id = item.assetID {
                result.byID[id, default: 0] += 1
            }
            if let url = item.assetURL {
                result.byPath[url.path, default: 0] += 1
            }
        }
        return result
    }

    /// 搜索词是否命中：文件名包含关键词，或者关键词正好是类型名
    static func matches(_ asset: MediaAsset, keywords: [String]) -> Bool {
        guard !keywords.isEmpty else { return true }
        let haystack = asset.name.lowercased()
        for keyword in keywords {
            // 类型名只认全等，避免打一个 "a" 就把所有 audio 都匹配出来
            if keyword == asset.type.label || keyword == asset.type.rawValue { continue }
            if haystack.contains(keyword) { continue }
            return false
        }
        return true
    }

    /// 按当前条件过滤（忽略类型筛选），用来算每个类型胶囊上的数字
    static func counts(for assets: [MediaAsset],
                       query: MediaQuery,
                       usage: MediaUsage,
                       collections: [MediaCollection] = []) -> MediaTypeCounts {
        let members = memberIDs(query.collectionID, in: collections)
        var result = MediaTypeCounts()
        for asset in assets {
            guard matches(asset, keywords: query.keywords) else { continue }
            if query.unusedOnly, usage.count(asset) > 0 { continue }
            if let members, !members.contains(asset.id) { continue }
            switch asset.type {
            case .video: result.video += 1
            case .audio: result.audio += 1
            case .image: result.image += 1
            }
        }
        return result
    }

    /// 过滤 + 排序
    static func apply(_ query: MediaQuery,
                      to assets: [MediaAsset],
                      usage: MediaUsage = .empty,
                      collections: [MediaCollection] = []) -> [MediaAsset] {
        let members = memberIDs(query.collectionID, in: collections)
        let result = assets.filter { asset in
            guard matches(asset, keywords: query.keywords) else { return false }
            if let type = query.type, asset.type != type { return false }
            if query.unusedOnly, usage.count(asset) > 0 { return false }
            if let members, !members.contains(asset.id) { return false }
            return true
        }
        return sorted(result, by: query.sort, descending: query.descending)
    }

    // MARK: - 集合

    /// 选中的集合里有哪些素材；没选集合（或集合已被删）时返回 nil 表示不限制
    static func memberIDs(_ collectionID: UUID?, in collections: [MediaCollection]) -> Set<UUID>? {
        guard let collectionID,
              let collection = collections.first(where: { $0.id == collectionID }) else { return nil }
        return Set(collection.assetIDs)
    }

    /// 集合列表上要显示的数字：只算素材库里还在的成员（陈旧 id 不计）
    static func collectionInfos(_ collections: [MediaCollection],
                                library: [MediaAsset]) -> [CollectionInfo] {
        let alive = Set(library.map(\.id))
        return collections.map { collection in
            CollectionInfo(id: collection.id,
                           name: collection.name,
                           count: collection.assetIDs.filter { alive.contains($0) }.count)
        }
    }

    /// 去掉已经不在素材库里的成员，避免集合越攒越脏
    static func sanitized(_ collections: [MediaCollection],
                          library: [MediaAsset]) -> [MediaCollection] {
        let alive = Set(library.map(\.id))
        return collections.map { collection in
            var copy = collection
            copy.assetIDs = collection.assetIDs.filter { alive.contains($0) }
            return copy
        }
    }

    /// 把素材加进集合：已在里面的跳过，返回实际新增的数量
    @discardableResult
    static func add(_ assetIDs: [UUID],
                    to collection: inout MediaCollection) -> Int {
        var added = 0
        for id in assetIDs where !collection.assetIDs.contains(id) {
            collection.assetIDs.append(id)
            added += 1
        }
        return added
    }

    /// 稳定排序：比较结果相等时保持原有（导入）顺序
    static func sorted(_ assets: [MediaAsset],
                       by sort: MediaSort,
                       descending: Bool) -> [MediaAsset] {
        guard sort != .added else {
            return descending ? assets.reversed() : assets
        }
        let indexed = Array(assets.enumerated())
        let result = indexed.sorted { lhs, rhs in
            let order = compare(lhs.element, rhs.element, by: sort)
            if order == .orderedSame { return lhs.offset < rhs.offset }
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
        return result.map(\.element)
    }

    private static func compare(_ a: MediaAsset, _ b: MediaAsset, by sort: MediaSort) -> ComparisonResult {
        switch sort {
        case .added:
            return .orderedSame
        case .name:
            return a.name.localizedStandardCompare(b.name)
        case .duration:
            // 等长时返回 orderedSame，交给稳定排序保持导入顺序；
            // 不要在比较里再按名字二级排序，否则切换正/倒序时等值项也会跟着换位
            if a.duration == b.duration { return .orderedSame }
            return a.duration < b.duration ? .orderedAscending : .orderedDescending
        case .type:
            if a.type.sortOrder == b.type.sortOrder { return .orderedSame }
            return a.type.sortOrder < b.type.sortOrder ? .orderedAscending : .orderedDescending
        }
    }

    /// 按类型切成若干段；grouped == false 时返回单段
    static func sections(_ assets: [MediaAsset], grouped: Bool) -> [MediaSection] {
        guard grouped else {
            return assets.isEmpty ? [] : [MediaSection(type: nil, assets: assets)]
        }
        let order: [MediaType] = [.video, .audio, .image]
        return order.compactMap { type in
            let bucket = assets.filter { $0.type == type }
            return bucket.isEmpty ? nil : MediaSection(type: type, assets: bucket)
        }
    }

    /// 「移出未使用素材」要删哪些（只从素材库移除，不碰磁盘文件，也不碰时间线）
    static func unusedIDs(_ assets: [MediaAsset], usage: MediaUsage) -> Set<UUID> {
        Set(assets.filter { usage.count($0) == 0 }.map(\.id))
    }
}
