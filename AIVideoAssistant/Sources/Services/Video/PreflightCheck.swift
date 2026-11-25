//
//  PreflightCheck.swift
//  导出前体检：把「能导出、但成片不是你要的」这类静默问题一次列清楚
//
//  为什么需要：转场不生效、素材丢了、片段比素材长、字幕跑到片尾之后……
//  这些都不会让导出报错，成片出来才发现，改一轮就要重导一遍。
//
//  纯逻辑集中在 `inspect`：素材信息（时长 / 画幅）由外部喂进来，
//  所以不碰网络、不碰磁盘也能直接跑断言。
//

import Foundation
import AVFoundation
import CoreGraphics

// MARK: - 报告

enum PreflightSeverity: Int, Comparable, Hashable {
    case info = 0
    case warning = 1
    case error = 2

    static func < (lhs: PreflightSeverity, rhs: PreflightSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .info: return "提示"
        case .warning: return "注意"
        case .error: return "会出错"
        }
    }

    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

struct PreflightIssue: Identifiable, Hashable {
    let id = UUID()
    var severity: PreflightSeverity
    /// 一句话说清问题
    var title: String
    /// 会看到什么现象 / 怎么改
    var detail: String
    /// 相关片段名（可能为 nil）
    var clipName: String?
}

struct PreflightReport: Identifiable, Hashable {
    let id = UUID()
    var issues: [PreflightIssue] = []

    var errorCount: Int { issues.filter { $0.severity == .error }.count }
    var warningCount: Int { issues.filter { $0.severity == .warning }.count }
    var infoCount: Int { issues.filter { $0.severity == .info }.count }

    /// 有任何一条（用来决定要不要弹窗）
    var hasIssues: Bool { !issues.isEmpty }
    /// 有会直接导致失败的问题
    var blocksExport: Bool { errorCount > 0 }

    var headline: String {
        if errorCount > 0 { return "\(errorCount) 处会导致导出失败" }
        if warningCount > 0 { return "\(warningCount) 处可能不是你想要的效果" }
        if infoCount > 0 { return "\(infoCount) 条提示，可以直接导出" }
        return "没有发现问题"
    }

    /// 按严重程度从重到轻排好
    static func sorted(_ issues: [PreflightIssue]) -> [PreflightIssue] {
        issues.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return ($0.clipName ?? "") < ($1.clipName ?? "")
        }
    }
}

// MARK: - 检查

enum PreflightCheck {

    /// 素材元信息。读不出来的素材不会出现在字典里。
    struct AssetInfo: Hashable {
        var duration: Double
        /// 已按 preferredTransform 摆正的画幅
        var naturalSize: CGSize
    }

    /// 单条字幕短于这个值就提醒（比 SubtitleTiming 的 0.1 宽松，0.3 才是能看清的下限）
    static let readableSubtitleDuration: Double = 0.3
    /// 空隙超过这个值才提示（小的缝隙观众看不出来）
    static let noticeableGap: Double = 0.5

    // MARK: 入口

    static func run(items: [TimelineItem], settings: ExportSettings) async -> PreflightReport {
        let assets = await loadAssetInfo(items: items)
        return inspect(items: items,
                       settings: settings,
                       assets: assets,
                       fileExists: { FileManager.default.fileExists(atPath: $0.path) })
    }

    /// 读素材时长与画幅。同一路径只读一次。
    static func loadAssetInfo(items: [TimelineItem]) async -> [String: AssetInfo] {
        var result: [String: AssetInfo] = [:]
        var seen = Set<String>()

        for item in items {
            guard let url = item.assetURL else { continue }
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { continue }

            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else { continue }
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { continue }

            var size = CGSize.zero
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                let natural = (try? await track.load(.naturalSize)) ?? .zero
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let rect = CGRect(origin: .zero, size: natural).applying(transform)
                size = CGSize(width: abs(rect.width), height: abs(rect.height))
            }
            result[key] = AssetInfo(duration: seconds, naturalSize: size)
        }
        return result
    }

    // MARK: 纯逻辑

    static func inspect(items: [TimelineItem],
                        settings: ExportSettings,
                        assets: [String: AssetInfo],
                        fileExists: (URL) -> Bool) -> PreflightReport {
        var issues: [PreflightIssue] = []
        let renderSize = settings.resolution.size

        func info(for item: TimelineItem) -> AssetInfo? {
            guard let url = item.assetURL else { return nil }
            return assets[url.standardizedFileURL.path]
        }

        let visual = items.filter { ($0.type == .video || $0.type == .aiGenerated) }
            .sorted { $0.startTime < $1.startTime }
        // V1 是主画面、V2 是画中画，两者互不抢位置，很多检查要分开算
        let mainVisual = visual.filter { !$0.isOverlay }
        let overlayVisual = visual.filter { $0.isOverlay }
        let audios = items.filter { $0.type == .audio }.sorted { $0.startTime < $1.startTime }
        let subtitles = items.filter { $0.type == .subtitle || $0.type == .text }
            .sorted { $0.startTime < $1.startTime }

        // 成片时长只看画面与声音，字幕自己不算
        let total = (visual + audios).map(\.endTime).max() ?? 0

        // E1 没有画面
        if visual.isEmpty {
            issues.append(PreflightIssue(severity: .error,
                                         title: "时间线上没有视频片段",
                                         detail: "只有音频和字幕的话导不出画面，先把视频拖到 V1 轨道。",
                                         clipName: nil))
        } else if mainVisual.isEmpty {
            issues.append(PreflightIssue(severity: .info,
                                         title: "V1 主画面是空的",
                                         detail: "时间线上只有画中画，成片会是一块黑底上浮着画中画。",
                                         clipName: nil))
        }

        // E2/E3 素材文件 + 元信息
        for item in visual + audios {
            guard let url = item.assetURL else {
                issues.append(PreflightIssue(severity: .error,
                                             title: "「\(item.name)」没有指向任何文件",
                                             detail: "这一段导出时会被跳过。重新从素材库拖一次，或删掉它。",
                                             clipName: item.name))
                continue
            }
            guard fileExists(url) else {
                issues.append(PreflightIssue(severity: .error,
                                             title: "「\(item.name)」的文件找不到了",
                                             detail: "路径：\(url.path)。文件被移动或删除后，这一段导不出来。",
                                             clipName: item.name))
                continue
            }
            if let asset = info(for: item) {
                if asset.duration <= 0.05 {
                    issues.append(PreflightIssue(severity: .error,
                                                 title: "「\(item.name)」读不出时长",
                                                 detail: "文件可能损坏，或者根本不是媒体文件。",
                                                 clipName: item.name))
                }
                // W7 片段比素材余量长
                if item.type == .video || item.type == .aiGenerated {
                    let speed = min(max(item.properties.speed, 0.1), 4.0)
                    let available = asset.duration - max(0, item.sourceStart)
                    let usable = available / speed
                    if item.duration > usable + 0.05 {
                        issues.append(PreflightIssue(
                            severity: .warning,
                            title: "「\(item.name)」比素材可用长度长",
                            detail: String(format: "片段 %.2f s，素材只剩 %.2f s，导出时会自动截短，后面可能露出黑场。",
                                           item.duration, max(0, usable)),
                            clipName: item.name))
                    }
                }
            }
        }

        // W1 转场不生效（画中画不参与转场，跳过）
        for (index, clip) in mainVisual.enumerated() where clip.transition != .none {
            let previous = index > 0 ? mainVisual[index - 1] : nil
            let assetDuration = previous.flatMap { info(for: $0)?.duration }
            let status = TimelineLayout.transitionStatus(for: clip,
                                                         previous: previous,
                                                         previousAssetDuration: assetDuration)
            guard status.isProblem else { continue }
            issues.append(PreflightIssue(severity: .warning,
                                         title: "「\(clip.name)」的转场不会生效",
                                         detail: "\(status.label)。成片里这里是硬切。",
                                         clipName: clip.name))
        }

        // W2 同轨重叠
        func overlaps(_ list: [TimelineItem], label: String) {
            guard list.count > 1 else { return }
            for index in 1..<list.count {
                let previous = list[index - 1]
                let gap = list[index].startTime - previous.endTime
                if gap < -0.01 {
                    issues.append(PreflightIssue(
                        severity: .warning,
                        title: "「\(list[index].name)」和「\(previous.name)」重叠了",
                        detail: String(format: "%@同一时刻只能放一段，重叠的 %.2f s 会被前一段盖住。", label, -gap),
                        clipName: list[index].name))
                }
            }
        }
        overlaps(mainVisual, label: "V1 视频轨")
        overlaps(overlayVisual, label: "V2 画中画轨")
        overlaps(audios, label: "音频轨")

        // W8 画中画压在黑场上
        for clip in overlayVisual {
            let covered = mainVisual.contains { $0.startTime < clip.endTime - 0.01 && $0.endTime > clip.startTime + 0.01 }
            guard !covered else { continue }
            issues.append(PreflightIssue(
                severity: .info,
                title: "「\(clip.name)」下面没有主画面",
                detail: "这段画中画所在的时间段 V1 是空的，背景会是黑的。",
                clipName: clip.name))
        }

        // W9 画中画太小
        for clip in overlayVisual where clip.properties.pip.widthRatio < 0.15 {
            issues.append(PreflightIssue(
                severity: .info,
                title: "「\(clip.name)」画中画偏小",
                detail: String(format: "只占画幅宽度的 %.0f%%，手机上看不清内容。", clip.properties.pip.widthRatio * 100),
                clipName: clip.name))
        }

        // W3/W4/W5 字幕
        for clip in subtitles {
            if total > 0, clip.startTime >= total - 0.01 {
                issues.append(PreflightIssue(severity: .warning,
                                             title: "「\(clip.name)」在成片之后",
                                             detail: String(format: "它从 %.2f s 开始，成片只有 %.2f s，这一段不会出现在画面里。", clip.startTime, total),
                                             clipName: clip.name))
            } else if total > 0, clip.endTime > total + 0.01 {
                issues.append(PreflightIssue(severity: .info,
                                             title: "「\(clip.name)」超出了片尾",
                                             detail: String(format: "超出 %.2f s 的部分不会被画出来。", clip.endTime - total),
                                             clipName: clip.name))
            }
            if clip.duration < readableSubtitleDuration {
                issues.append(PreflightIssue(
                    severity: .warning,
                    title: "「\(clip.name)」显示时间太短",
                    detail: String(format: "只有 %.2f s，观众来不及看清。建议至少 %.1f s。", clip.duration, readableSubtitleDuration),
                    clipName: clip.name))
            }
        }
        if subtitles.count > 1 {
            for index in 1..<subtitles.count {
                let previous = subtitles[index - 1]
                if subtitles[index].startTime < previous.endTime - 0.01 {
                    issues.append(PreflightIssue(
                        severity: .warning,
                        title: "「\(subtitles[index].name)」和上一条字幕重叠",
                        detail: "两条同时显示会糊在一起，调一下时间码。",
                        clipName: subtitles[index].name))
                }
            }
        }

        // W6 画幅不一致（画中画保持自身比例，不参与这条）
        if renderSize.width > 1, renderSize.height > 1 {
            let renderAspect = renderSize.width / renderSize.height
            var reported = Set<String>()
            for clip in mainVisual {
                guard let asset = info(for: clip),
                      asset.naturalSize.width > 1, asset.naturalSize.height > 1 else { continue }
                let sourceAspect = asset.naturalSize.width / asset.naturalSize.height
                guard abs(sourceAspect / renderAspect - 1) > 0.02 else { continue }
                guard reported.insert(clip.name).inserted else { continue }

                let wider = sourceAspect > renderAspect
                let detail: String
                switch settings.fillMode {
                case .fit:
                    detail = wider
                        ? "素材比画幅宽，上下会留黑边。想要铺满可以切到「填满」。"
                        : "素材比画幅窄，左右会留黑边。想要铺满可以切到「填满」。"
                case .fill:
                    detail = wider
                        ? "素材比画幅宽，「填满」会裁掉左右两边。"
                        : "素材比画幅窄，「填满」会裁掉上下两边。"
                }
                issues.append(PreflightIssue(severity: .info,
                                             title: "「\(clip.name)」画幅和成片不一致",
                                             detail: detail,
                                             clipName: clip.name))
            }
        }

        // I1 画面空隙（只看主画面：画中画本身不负责铺满画幅）
        if mainVisual.count > 1 {
            for index in 1..<mainVisual.count {
                let gap = mainVisual[index].startTime - mainVisual[index - 1].endTime
                if gap > noticeableGap {
                    issues.append(PreflightIssue(
                        severity: .info,
                        title: String(format: "%.2f s 的画面空隙", gap),
                        detail: "空隙会渲染成黑场。如果不是故意的，可以用「吸附到上一段」贴上去。",
                        clipName: mainVisual[index].name))
                }
            }
        }

        return PreflightReport(issues: PreflightReport.sorted(issues))
    }
}
