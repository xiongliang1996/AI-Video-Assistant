//
//  AssetRelinker.swift
//  素材重连：项目引用的文件被移动 / 改名后，把引用指回新位置
//
//  为什么需要：片段靠绝对路径找素材。文件一挪，画面就黑了；
//  而「删掉重新导入」会丢掉裁剪点、关键帧、转场、画中画参数、淡入淡出……
//  重连只改路径，其余字段一个不动。
//
//  匹配策略只认「同名文件」。改名猜不出来，硬猜会把不相干的素材接上去，
//  比找不到更糟——用户以为修好了，导出才发现全错。
//

import Foundation

enum AssetRelinker {

    /// 一条「找不到文件」的素材
    struct Missing: Identifiable, Hashable {
        /// 旧路径（绝对路径），也是去重键
        var path: String
        var name: String
        /// 时间线上有几个片段在用它
        var clipCount: Int
        /// 是否还在素材库里
        var inLibrary: Bool

        var id: String { path }

        /// 旧路径所在的文件夹，面板里显示出来能帮人想起文件挪哪去了
        var directory: String {
            (path as NSString).deletingLastPathComponent
        }
    }

    // MARK: - 扫描

    /// 找出所有找不到文件的素材。
    /// 同一个路径既在素材库又被片段引用时只算一条，`clipCount` 照常统计。
    static func missing(libraryPaths: [String],
                        timelinePaths: [String],
                        fileExists: (String) -> Bool) -> [Missing] {
        var clipCounts: [String: Int] = [:]
        for path in timelinePaths where !path.isEmpty {
            clipCounts[path, default: 0] += 1
        }

        var seen = Set<String>()
        var result: [Missing] = []

        func consider(_ path: String, inLibrary: Bool) {
            guard !path.isEmpty, !seen.contains(path) else { return }
            guard !fileExists(path) else { return }
            seen.insert(path)
            result.append(Missing(path: path,
                                  name: (path as NSString).lastPathComponent,
                                  clipCount: clipCounts[path] ?? 0,
                                  inLibrary: inLibrary))
        }

        for path in libraryPaths { consider(path, inLibrary: true) }
        for path in clipCounts.keys { consider(path, inLibrary: false) }

        // 有片段在用的排前面：它比「只是躺在素材库里」更急
        return result.sorted {
            if $0.clipCount != $1.clipCount { return $0.clipCount > $1.clipCount }
            let byName = $0.name.localizedStandardCompare($1.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return $0.path < $1.path
        }
    }

    // MARK: - 批量匹配

    /// 列目录（不递归，跳过隐藏文件）
    static func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    /// 在候选文件里按文件名给缺失素材找替身，返回「旧路径 → 新 URL」。
    /// 只认同名（忽略大小写，APFS 默认就是这样）。
    static func match(missing: [Missing],
                      candidates: [URL],
                      fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> [String: URL] {

        guard !missing.isEmpty, !candidates.isEmpty else { return [:] }

        // 同名有多个时保留先出现的那个，行为确定
        var byName: [String: URL] = [:]
        for url in candidates {
            let key = url.lastPathComponent.lowercased()
            if byName[key] == nil { byName[key] = url }
        }

        var result: [String: URL] = [:]
        for item in missing {
            guard let candidate = byName[item.name.lowercased()] else { continue }
            // 目录里列出来的不一定还在（列完就被删），再确认一次
            guard fileExists(candidate.path) else { continue }
            // 新路径就是旧路径说明文件其实没丢，跳过
            guard candidate.path != item.path else { continue }
            result[item.path] = candidate
        }
        return result
    }

    // MARK: - 应用

    /// 把「旧路径 → 新路径」套到时间线上，返回改了几条片段。
    /// 只动 `assetURL`，其余字段（含裁剪、关键帧、转场、画中画）原样保留。
    static func apply(_ map: [String: URL],
                      to timeline: [TimelineItem]) -> (items: [TimelineItem], changed: Int) {
        guard !map.isEmpty else { return (timeline, 0) }
        var changed = 0
        var result = timeline
        for index in result.indices {
            guard let old = result[index].assetURL?.path,
                  let new = map[old] else { continue }
            result[index].assetURL = new
            changed += 1
        }
        return (result, changed)
    }
}
