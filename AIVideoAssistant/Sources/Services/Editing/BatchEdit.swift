//
//  BatchEdit.swift
//  多选批量编辑
//
//  全部写成纯函数：输入整条时间线 + 要改的 id 集合，输出新数组 + 统计。
//  这样「套用到几个」「跳过了几个、为什么跳」都能在 harness 里直接断言，
//  不用去戳 AppState（那会触发自动保存，把测试目录写脏）。
//

import Foundation

/// 一次批量编辑的结果
struct BatchEditResult {
    /// 改完的整条时间线（没选中的片段原样带出来）
    var items: [TimelineItem]
    /// 真正套用到的片段数
    var applied: Int = 0
    /// 带调色关键帧、被跳过的片段数
    var skippedAnimated: Int = 0
    /// 类型不支持（音频 / 字幕 / 主画面）被跳过的片段数
    var skippedUnsupported: Int = 0
    /// 内容是不是真的变了——决定要不要往撤销栈里压快照
    var changed: Bool = false
}

enum BatchEdit {

    // MARK: - 能力判定

    /// 能调色的类型。字幕 / 纯音频没有画面，调色对它们没有意义
    static func canGrade(_ item: TimelineItem) -> Bool {
        item.type == .video || item.type == .aiGenerated
    }

    /// 能改外观（圆角 / 描边 / 投影）的只有画中画。
    /// 主画面是铺满画幅的，圆角裁出来只会得到四个黑角
    static func canDecorate(_ item: TimelineItem) -> Bool {
        item.isOverlay
    }

    // MARK: - 批量套用

    /// 统一调色。
    ///
    /// 传的是**逐分量修改闭包**而不是整个 `ColorGrade`：这样「只拖曝光」不会把
    /// 别的片段自己的对比度 / 饱和度一起抹平——多选时几个片段的其它参数往往并不相同。
    ///
    /// 带调色关键帧的片段直接跳过：静态值在有动画的片段上根本不参与渲染，
    /// 写进去等于「点了没反应」，不如报出来让用户先决定要不要清掉动画。
    static func applyGrade(to items: [TimelineItem],
                           ids: Set<UUID>,
                           _ mutate: (inout ColorGrade) -> Void) -> BatchEditResult {
        var result = BatchEditResult(items: items)
        for index in result.items.indices {
            let item = result.items[index]
            guard ids.contains(item.id) else { continue }
            guard canGrade(item) else {
                result.skippedUnsupported += 1
                continue
            }
            guard !item.properties.hasColorGradeKeyframes else {
                result.skippedAnimated += 1
                continue
            }
            var grade = item.properties.grade
            mutate(&grade)
            let clean = grade.sanitized
            result.applied += 1
            if clean != item.properties.grade {
                result.items[index].properties.grade = clean
                result.changed = true
            }
        }
        return result
    }

    /// 统一外观（圆角 / 描边 / 投影）。只作用于画中画
    static func applyDecoration(to items: [TimelineItem],
                                ids: Set<UUID>,
                                _ mutate: (inout PiPStyle) -> Void) -> BatchEditResult {
        var result = BatchEditResult(items: items)
        for index in result.items.indices {
            let item = result.items[index]
            guard ids.contains(item.id) else { continue }
            guard canDecorate(item) else {
                result.skippedUnsupported += 1
                continue
            }
            var style = item.properties.pip
            mutate(&style)
            let clean = style.sanitized
            result.applied += 1
            if clean != item.properties.pip {
                result.items[index].properties.pip = clean
                result.changed = true
            }
        }
        return result
    }

    /// 清掉所选片段的调色动画，并**把播放头那一帧的颜色留下来**当静态值。
    ///
    /// 直接清空关键帧的话，静态值多半是中性（0 / 1 / 1 / 0），画面会「啪」地
    /// 跳回原色——用户只是想解除动画，不是想丢掉这一镜的调色。
    static func clearGradeKeyframes(to items: [TimelineItem],
                                    ids: Set<UUID>,
                                    playhead: Double) -> BatchEditResult {
        var result = BatchEditResult(items: items)
        for index in result.items.indices {
            let item = result.items[index]
            guard ids.contains(item.id) else { continue }
            guard canGrade(item) else {
                result.skippedUnsupported += 1
                continue
            }
            guard item.properties.hasColorGradeKeyframes else { continue }

            // 播放头不在这一段里就取最近的那一端：在片段之前取首帧、
            // 之后取末帧——至少保证「清掉动画」不会让画面颜色凭空跳一下
            let local = min(max(playhead - item.startTime, 0), item.duration)
            result.items[index].properties.grade = item.properties.resolvedGrade(at: local).sanitized
            for property in AnimatableProperty.colorGradeProperties {
                result.items[index].properties.setKeyframes([], for: property)
            }
            result.applied += 1
            result.changed = true
        }
        return result
    }

    // MARK: - 多选面板要显示的「公共值」

    /// 一组数值的公共值。有任何一个不同就返回 nil（界面显示「混合」）
    static func commonValue(_ values: [Double], tolerance: Double = 0.005) -> Double? {
        guard let first = values.first else { return nil }
        return values.allSatisfy { abs($0 - first) <= tolerance } ? first : nil
    }

    static func commonGrade(of items: [TimelineItem]) -> ColorGrade? {
        let grades = items.filter(canGrade).map(\.properties.grade)
        guard let first = grades.first else { return nil }
        return grades.allSatisfy { $0.isClose(to: first) } ? first : nil
    }

    static func commonPiP(_ items: [TimelineItem],
                          _ keyPath: WritableKeyPath<PiPStyle, Double>) -> Double? {
        commonValue(items.filter(canDecorate).map { $0.properties.pip[keyPath: keyPath] })
    }

    static func commonPiPColor(_ items: [TimelineItem]) -> Int? {
        let hexes = items.filter(canDecorate).map(\.properties.pip.borderColorHex)
        guard let first = hexes.first else { return nil }
        return hexes.allSatisfy { $0 == first } ? first : nil
    }

    // MARK: - 计数

    static func countGradeable(_ items: [TimelineItem]) -> Int {
        items.filter(canGrade).count
    }

    static func countDecoratable(_ items: [TimelineItem]) -> Int {
        items.filter(canDecorate).count
    }

    static func countAnimatedGrade(_ items: [TimelineItem]) -> Int {
        items.filter { canGrade($0) && $0.properties.hasColorGradeKeyframes }.count
    }
}
