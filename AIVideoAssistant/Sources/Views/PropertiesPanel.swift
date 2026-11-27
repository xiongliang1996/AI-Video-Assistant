//
//  PropertiesPanel.swift
//  属性检查器
//

import SwiftUI

struct PropertiesPanel: View {
    @EnvironmentObject var appState: AppState

    /// 每个片段记住自己上次看的关键帧属性
    @State private var selectedProperty: [UUID: AnimatableProperty] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("属性")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(headerSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Rectangle().fill(Theme.line).frame(height: 1)

            if let item = appState.selectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        basics(item)
                        divider
                        if item.isOverlay {
                            pip(item)
                            pipAppearance(item)
                            divider
                        }
                        transform(item)
                        divider
                        audio(item)
                        divider
                        effects(item)
                        if item.type == .video || item.type == .aiGenerated {
                            divider
                            grade(item)
                        }
                        if item.type != .subtitle {
                            divider
                            keyframes(item)
                        }
                        if item.type == .subtitle || item.type == .text {
                            divider
                            textSettings(item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            } else if appState.hasMultiSelection {
                multiSelection
            } else {
                EmptyHint(icon: "slider.horizontal.3",
                          title: "未选中片段",
                          subtitle: "点击时间线上的片段查看属性")
            }
        }
        .frame(width: 288)
        .background(Theme.panel2)
    }

    // MARK: 多选

    private var headerSubtitle: String {
        if let item = appState.selectedItem { return item.name }
        if appState.hasMultiSelection { return "已选 \(appState.selectedItemIDs.count) 个片段" }
        return "未选择"
    }

    private var multiSelection: some View {
        let items = appState.selectedItems
        let start = items.map(\.startTime).min() ?? 0
        let end = items.map(\.endTime).max() ?? 0
        let total = items.reduce(0) { $0 + $1.duration }
        let videoCount = items.filter { $0.trackKind == .video }.count
        let audioCount = items.filter { $0.trackKind == .audio }.count
        let textCount = items.filter { $0.trackKind == .subtitle }.count
        let gradeCount = BatchEdit.countGradeable(items)
        let decorCount = BatchEdit.countDecoratable(items)

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                groupHeader("square.stack.3d.up", "多选")
                infoRow("片段数", "\(items.count)")
                infoRow("时间跨度", "\(formatTimecode(start)) – \(formatTimecode(end))")
                infoRow("片段总长", String(format: "%.1f s", total))
                if videoCount > 0 { infoRow("视频", "\(videoCount)") }
                if audioCount > 0 { infoRow("音频", "\(audioCount)") }
                if textCount > 0 { infoRow("字幕", "\(textCount)") }

                if gradeCount > 0 {
                    divider.padding(.vertical, 10)
                    batchGradeSection(items)
                }

                if decorCount > 0 {
                    divider.padding(.vertical, 10)
                    batchAppearanceSection(items)
                }

                divider.padding(.vertical, 10)

                Button {
                    appState.removeSelectedItem()
                } label: {
                    Label("删除所选 \(items.count) 个片段", systemImage: "trash")
                        .font(.system(size: 11.5))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SoftButtonStyle(height: 30, fullWidth: true))

                Button {
                    appState.clearSelection()
                } label: {
                    Text("取消选择")
                        .font(.system(size: 11.5))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SoftButtonStyle(height: 28, fullWidth: true))
                .padding(.top, 6)

                Text("拖动任意选中片段可整组移动；⌘ 点击增减选择。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
    }

    // MARK: 批量调色 / 外观

    /// 批量调色。只改**静态调色**：带调色动画的片段静态值根本不参与渲染，
    /// 硬写进去等于「点了没反应」，所以跳过并单独给一个清动画的入口。
    private func batchGradeSection(_ items: [TimelineItem]) -> some View {
        let count = BatchEdit.countGradeable(items)
        let animated = BatchEdit.countAnimatedGrade(items)
        let common = BatchEdit.commonGrade(of: items)
        let shown = common ?? ColorGrade()
        let presetIndex = common.flatMap { value in
            ColorGrade.presets.firstIndex { $0.grade.isClose(to: value) }
        }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                groupHeader("camera.filters", "批量调色")
                Spacer(minLength: 0)
                Text("\(count) 个画面片段")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text3)
                    .padding(.top, 4)
            }

            SliderRow(label: "曝光",
                      value: batchGradeBinding(items, \.exposure, 0),
                      range: ColorGrade.exposureRange,
                      display: common == nil ? "混合" : String(format: "%+.1f EV", shown.exposure))

            SliderRow(label: "对比度",
                      value: batchGradeBinding(items, \.contrast, 1),
                      range: ColorGrade.contrastRange,
                      display: common == nil ? "混合" : "\(Int((shown.contrast * 100).rounded()))%")

            SliderRow(label: "饱和度",
                      value: batchGradeBinding(items, \.saturation, 1),
                      range: ColorGrade.saturationRange,
                      display: common == nil ? "混合" : "\(Int((shown.saturation * 100).rounded()))%")

            SliderRow(label: "色温",
                      value: batchGradeBinding(items, \.temperature, 0),
                      range: ColorGrade.temperatureRange,
                      display: common == nil
                          ? "混合"
                          : (abs(shown.temperature) < 0.02
                             ? "原样"
                             : "\(shown.temperature > 0 ? "暖" : "冷") \(Int((abs(shown.temperature) * 100).rounded()))%"))

            chipGrid(ColorGrade.presets.map(\.label),
                     activeIndex: presetIndex,
                     columns: ColorGrade.presets.count) { index in
                let preset = ColorGrade.presets[index]
                appState.batchGrade { $0 = preset.grade }
            }

            if animated > 0 {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text("\(animated) 个片段带调色动画，静态调色对它们无效，已跳过")
                        .font(.system(size: 10))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.text3)
                .padding(.top, 6)

                Button {
                    appState.batchClearGradeKeyframes()
                } label: {
                    Text("清掉这些片段的调色动画")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SoftButtonStyle(height: 26, fullWidth: true))
                .padding(.top, 5)
            }

            Text("只改调色本身：每个片段原本的对比度、饱和度不会被「拖曝光」抹平。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    /// 批量外观（圆角 / 描边 / 投影）。只有画中画有这些参数，
    /// 主画面铺满画幅，裁圆角只会得到四个黑角
    private func batchAppearanceSection(_ items: [TimelineItem]) -> some View {
        let count = BatchEdit.countDecoratable(items)
        let corner = BatchEdit.commonPiP(items, \.cornerRadius)
        let border = BatchEdit.commonPiP(items, \.borderWidth)
        let shadow = BatchEdit.commonPiP(items, \.shadowRadius)
        let color = BatchEdit.commonPiPColor(items)
        let presets: [(String, Double)] = [("直角", 0), ("小", 0.06), ("大", 0.16), ("胶囊", 0.5)]

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                groupHeader("rectangle.on.rectangle", "批量外观")
                Spacer(minLength: 0)
                Text("\(count) 个画中画")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text3)
                    .padding(.top, 4)
            }

            SliderRow(label: "圆角",
                      value: batchPiPBinding(items, \.cornerRadius, 0),
                      range: PiPStyle.cornerRange,
                      display: corner == nil
                          ? "混合"
                          : (corner! < 0.005 ? "直角" : "\(Int((corner! * 100).rounded()))%"))

            presetGrid(presets, selected: corner ?? -1, columns: presets.count) { value in
                appState.batchDecoration { $0.cornerRadius = value }
            }

            SliderRow(label: "描边",
                      value: batchPiPBinding(items, \.borderWidth, 0),
                      range: PiPStyle.borderRange,
                      display: border == nil
                          ? "混合"
                          : (border! < 0.0005 ? "关" : String(format: "%.1f%%", border! * 100)))

            HStack(spacing: 7) {
                ForEach(PiPStyle.borderPalette, id: \.self) { hex in
                    let active = color == hex
                    Button {
                        appState.batchDecoration {
                            $0.borderColorHex = hex
                            if $0.borderWidth < 0.004 { $0.borderWidth = 0.02 }
                        }
                    } label: {
                        Circle()
                            .fill(Color(hex: UInt32(hex)))
                            .frame(width: 17, height: 17)
                            .overlay(Circle().stroke(Theme.text3.opacity(0.45), lineWidth: 1))
                            .overlay(
                                Circle()
                                    .stroke(Theme.accent, lineWidth: active ? 2 : 0)
                                    .padding(-2.5)
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(hex == 0xFFFFFF ? "白" : hex == 0x000000 ? "黑" : hex == 0x7C6BFF ? "品牌紫" : "暖黄")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 7)

            SliderRow(label: "投影",
                      value: batchPiPBinding(items, \.shadowRadius, 0),
                      range: PiPStyle.shadowRange,
                      display: shadow == nil
                          ? "混合"
                          : (shadow! < 0.0005 ? "关" : "\(Int((shadow! * 100).rounded()))%"))

            presetGrid(PiPStyle.shadowPresets.map { ($0.label, $0.radius) },
                       selected: shadow ?? -1,
                       columns: PiPStyle.shadowPresets.count) { radius in
                let preset = PiPStyle.shadowPresets.first { abs($0.radius - radius) < 0.0001 }
                appState.batchDecoration {
                    $0.shadowRadius = radius
                    if radius > 0.0005, let preset { $0.shadowOffset = preset.offset }
                }
            }

            Text("只作用于画中画（V2）。主画面铺满画幅，圆角只会裁出四个黑角。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    /// 批量调色滑杆。多选里数值不一致时显示「混合」，拖它就只改这一个分量
    private func batchGradeBinding(_ items: [TimelineItem],
                                   _ keyPath: WritableKeyPath<ColorGrade, Double>,
                                   _ fallback: Double) -> Binding<Double> {
        Binding(
            get: { BatchEdit.commonGrade(of: items)?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                appState.batchGrade { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    /// 批量外观滑杆
    private func batchPiPBinding(_ items: [TimelineItem],
                                 _ keyPath: WritableKeyPath<PiPStyle, Double>,
                                 _ fallback: Double) -> Binding<Double> {
        Binding(
            get: { BatchEdit.commonPiP(items, keyPath) ?? fallback },
            set: { newValue in
                appState.batchDecoration { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
    }

    // MARK: 分组

    private func groupHeader(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.text3)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text2)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text2)
            Spacer()
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Theme.panel)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
                )
        }
        .frame(height: 26)
    }

    private func basics(_ item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader("info.circle", "基础")
            infoRow("类型", item.type.label)
            infoRow("时长", String(format: "%.1f s", item.duration))
            infoRow("起点", formatTimecode(item.startTime))
            if item.sourceStart > 0.01 {
                infoRow("源入点", formatTimecode(item.sourceStart))
            }

            if TimelineItem.laneCount(for: item.trackKind) > 1 {
                HStack(spacing: 8) {
                    Text("轨道")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 52, alignment: .leading)
                    SegmentedControl(options: Array(0..<TimelineItem.laneCount(for: item.trackKind)),
                                     title: { TimelineItem.laneName(for: item.trackKind, lane: $0) },
                                     selection: Binding(
                                        get: { item.trackLane },
                                        set: { appState.moveToLane(item, lane: $0) }
                                     ))
                }
                .frame(height: 27)
            }
        }
    }

    /// 画中画：只有落在 V2 层的视频片段才显示这一组
    private func pip(_ item: TimelineItem) -> some View {
        let style = item.properties.pip
        return VStack(alignment: .leading, spacing: 0) {
            groupHeader("rectangle.on.rectangle", "画中画")

            SliderRow(label: "尺寸",
                      value: Binding(
                        get: { item.properties.pip.widthRatio },
                        set: { newValue in
                            var copy = item
                            copy.properties.pip.widthRatio = newValue
                            appState.updateItem(copy, recordUndo: true)
                        }
                      ),
                      range: PiPStyle.widthRange,
                      display: "\(Int((style.widthRatio * 100).rounded()))%")

            SliderRow(label: "留白",
                      value: Binding(
                        get: { item.properties.pip.margin },
                        set: { newValue in
                            var copy = item
                            copy.properties.pip.margin = newValue
                            appState.updateItem(copy, recordUndo: true)
                        }
                      ),
                      range: PiPStyle.marginRange,
                      display: "\(Int((style.margin * 100).rounded()))%")

            Text("位置")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text2)
                .padding(.top, 6)
                .padding(.bottom, 5)

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    positionButton(item, .topLeading)
                    positionButton(item, .topTrailing)
                }
                HStack(spacing: 4) {
                    positionButton(item, .bottomLeading)
                    positionButton(item, .bottomTrailing)
                }
                positionButton(item, .center, fullWidth: true)
            }

            HStack(spacing: 5) {
                Image(systemName: style.freeOrigin == nil ? "hand.draw" : "hand.draw.fill")
                    .font(.system(size: 9))
                Text(style.freeOrigin == nil
                     ? "也能在预览台上直接拖动画中画"
                     : "自由位置 · 点九宫格或双击画中画可复位")
                    .font(.system(size: 10))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(style.freeOrigin == nil ? Theme.text3 : Theme.accent)
            .padding(.top, 6)

            Text("画中画浮在主画面之上，自身不做转场。拖回 V1 即恢复为主画面。")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    /// 圆角 / 描边 / 投影。设了任意一项就会让这条项目改走自绘合成器，
    /// 所以文案里写一句「会多花点导出时间」，省得用户以为是卡住了。
    private func pipAppearance(_ item: TimelineItem) -> some View {
        let style = item.properties.pip

        func apply(_ mutate: (inout PiPStyle) -> Void) {
            var copy = item
            mutate(&copy.properties.pip)
            copy.properties.pip = copy.properties.pip.sanitized
            appState.updateItem(copy, recordUndo: true)
        }

        let presets: [(String, Double)] = [("直角", 0), ("小", 0.06), ("大", 0.16), ("胶囊", 0.5)]

        return VStack(alignment: .leading, spacing: 0) {
            Text("外观")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text2)
                .padding(.top, 8)
                .padding(.bottom, 5)

            SliderRow(label: "圆角",
                      value: Binding(
                        get: { item.properties.pip.cornerRadius },
                        set: { newValue in apply { $0.cornerRadius = newValue } }
                      ),
                      range: PiPStyle.cornerRange,
                      display: style.cornerRadius < 0.005
                          ? "直角"
                          : "\(Int((style.cornerRadius * 100).rounded()))%")

            presetGrid(presets,
                       selected: style.cornerRadius,
                       columns: presets.count) { value in
                apply { $0.cornerRadius = value }
            }

            SliderRow(label: "描边",
                      value: Binding(
                        get: { item.properties.pip.borderWidth },
                        set: { newValue in apply { $0.borderWidth = newValue } }
                      ),
                      range: PiPStyle.borderRange,
                      display: style.borderWidth < 0.0005
                          ? "关"
                          : String(format: "%.1f%%", style.borderWidth * 100))

            HStack(spacing: 7) {
                ForEach(PiPStyle.borderPalette, id: \.self) { hex in
                    let active = style.borderColorHex == hex
                    Button {
                        // 只点颜色、宽度还是 0 的话看起来「没反应」，
                        // 顺手给一个能看见的最小宽度
                        apply {
                            $0.borderColorHex = hex
                            if $0.borderWidth < 0.004 { $0.borderWidth = 0.02 }
                        }
                    } label: {
                        Circle()
                            .fill(Color(hex: UInt32(hex)))
                            .frame(width: 17, height: 17)
                            // 纯白和纯黑都用同一条中性描边：换主题时才不会有一个消失
                            .overlay(Circle().stroke(Theme.text3.opacity(0.45), lineWidth: 1))
                            .overlay(
                                Circle()
                                    .stroke(Theme.accent, lineWidth: active ? 2 : 0)
                                    .padding(-2.5)
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(hex == 0xFFFFFF ? "白" : hex == 0x000000 ? "黑" : hex == 0x7C6BFF ? "品牌紫" : "暖黄")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 7)

            SliderRow(label: "投影",
                      value: Binding(
                        get: { item.properties.pip.shadowRadius },
                        set: { newValue in apply { $0.shadowRadius = newValue } }
                      ),
                      range: PiPStyle.shadowRange,
                      display: style.shadowRadius < 0.0005
                          ? "关"
                          : "\(Int((style.shadowRadius * 100).rounded()))%")

            presetGrid(PiPStyle.shadowPresets.map { ($0.label, $0.radius) },
                       selected: style.shadowRadius,
                       columns: PiPStyle.shadowPresets.count) { radius in
                let preset = PiPStyle.shadowPresets.first { abs($0.radius - radius) < 0.0001 }
                apply {
                    $0.shadowRadius = radius
                    if radius > 0.0005, let preset { $0.shadowOffset = preset.offset }
                }
            }

            // 深浅只在开着投影时才露面：关着的时候调它没有任何反馈，
            // 只会让面板看起来比实际能用到的长
            if style.hasShadow {
                SliderRow(label: "投影深浅",
                          value: Binding(
                            get: { item.properties.pip.shadowOpacity },
                            set: { newValue in apply { $0.shadowOpacity = newValue } }
                          ),
                          range: PiPStyle.shadowOpacityRange,
                          display: "\(Int((style.shadowOpacity * 100).rounded()))%")
                    .padding(.top, 6)
            }

            Text("圆角、描边和投影会在导出时逐帧合成，比纯拼接略慢一点。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    /// 预设按钮网格（按数值匹配选中项）
    ///
    /// 不用 HStack 均分：`frame(maxWidth: .infinity)` 的按钮在 3 列时会被算得
    /// 比可用宽度略宽，最右一个的右圆角正好被容器裁掉（4 列时又刚好放得下）。
    /// 网格的列宽是容器算出来的，列数怎么变都不会溢出。
    private func presetGrid(_ options: [(String, Double)],
                            selected: Double,
                            columns: Int,
                            action: @escaping (Double) -> Void) -> some View {
        // selected 传 -1（「混合」）时一个都不高亮
        let active = options.firstIndex { abs(selected - $0.1) < 0.005 }
        return chipGrid(options.map(\.0), activeIndex: active, columns: columns) { index in
            action(options[index].1)
        }
    }

    /// 预设按钮网格（按序号匹配选中项）。
    /// 调色预设没法用一个 Double 表示，所以单开一层按序号走
    private func chipGrid(_ labels: [String],
                          activeIndex: Int?,
                          columns: Int,
                          action: @escaping (Int) -> Void) -> some View {
        // GridItem 的 spacing 是「这一列与下一列之间」，最后一列也带上就会
        // 让整行比容器宽一个 spacing，最右那个按钮的右圆角正好被裁掉
        let count = max(columns, 1)
        let gridColumns = (0..<count).map { index in
            GridItem(.flexible(minimum: 0), spacing: index == count - 1 ? 0 : 4)
        }
        return LazyVGrid(columns: gridColumns, spacing: 4) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                let active = activeIndex == index
                Button {
                    action(index)
                } label: {
                    Text(label)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(active ? Theme.accent.opacity(0.16) : Theme.panel)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(active ? Theme.accent.opacity(0.55) : Theme.line,
                                                lineWidth: 1)
                                )
                        )
                        .foregroundStyle(active ? Theme.accent : Theme.text2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 5)
    }

    private func positionButton(_ item: TimelineItem,
                                _ position: PiPPosition,
                                fullWidth: Bool = false) -> some View {
        // 自由位置时九宫格一个都不高亮：拖歪了还亮着「右下」会让人以为没拖成功
        let active = item.properties.pip.position == position
            && item.properties.pip.freeOrigin == nil
        return Button {
            var copy = item
            copy.properties.pip.position = position
            copy.properties.pip.freeOrigin = nil
            appState.updateItem(copy, recordUndo: true)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: position.icon)
                    .font(.system(size: 9.5))
                Text(position.label)
                    .font(.system(size: 11))
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: 24)
            .frame(minWidth: fullWidth ? 0 : 84)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Theme.accent.opacity(0.16) : Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(active ? Theme.accent.opacity(0.55) : Theme.line, lineWidth: 1)
                    )
            )
            .foregroundStyle(active ? Theme.accent : Theme.text2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 调色。只有画面片段才有意义——字幕 / 文字是烧录上去的，
    /// 不经过视频合成，给它们调色只会让人以为调了没用。
    private func grade(_ item: TimelineItem) -> some View {
        let keyed = item.properties.hasColorGradeKeyframes
        let local = max(0, min(item.duration, appState.currentTime - item.startTime))
        // 有关键帧时，滑杆显示的是「播放头这一时刻」的值，不是静态值——
        // 否则会出现「画面明明在变、滑杆却停在原处」的错觉
        let style = keyed ? item.properties.resolvedGrade(at: local) : item.properties.grade

        func reset() {
            var copy = item
            copy.properties.grade = ColorGrade()
            for property in AnimatableProperty.colorGradeProperties {
                copy.properties.setKeyframes([], for: property)
            }
            appState.updateItem(copy, recordUndo: true)
        }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                groupHeader("camera.filters", "调色")
                Spacer(minLength: 0)
                if keyed {
                    Text("动画中")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.accentSoft))
                }
            }

            SliderRow(label: "曝光",
                      value: gradeBinding(item, \.exposure, .exposure),
                      range: ColorGrade.exposureRange,
                      display: String(format: "%+.1f EV", style.exposure))

            SliderRow(label: "对比度",
                      value: gradeBinding(item, \.contrast, .contrast),
                      range: ColorGrade.contrastRange,
                      display: "\(Int((style.contrast * 100).rounded()))%")

            SliderRow(label: "饱和度",
                      value: gradeBinding(item, \.saturation, .saturation),
                      range: ColorGrade.saturationRange,
                      display: "\(Int((style.saturation * 100).rounded()))%")

            SliderRow(label: "色温",
                      value: gradeBinding(item, \.temperature, .temperature),
                      range: ColorGrade.temperatureRange,
                      display: abs(style.temperature) < 0.02
                          ? "原样"
                          : "\(style.temperature > 0 ? "暖" : "冷") \(Int((abs(style.temperature) * 100).rounded()))%")

            HStack(spacing: 6) {
                Button {
                    reset()
                } label: {
                    Text("还原")
                        .font(.system(size: 10.5))
                        .frame(height: 22)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.panel)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Theme.line, lineWidth: 1)
                                )
                        )
                        .foregroundStyle(style.isNeutral && !keyed ? Theme.text3 : Theme.text2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(style.isNeutral && !keyed)

                Text(style.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.top, 6)

            if keyed {
                Text("这段调色有关键帧：拖滑杆会写进播放头所在的关键帧（没有就插一个）。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            } else if !style.isNeutral {
                Text("调色会让这条项目改走逐帧合成，导出比纯拼接略慢。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            } else {
                Text("想让颜色随时间变，去下面的「关键帧」里选曝光 / 饱和度。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            }
        }
    }

    /// 调色滑杆的绑定。
    ///
    /// 有关键帧时**写的是播放头那一时刻的关键帧**，不是静态值——
    /// 静态值在有调色关键帧时根本不参与渲染，改它等于石沉大海。
    private func gradeBinding(_ item: TimelineItem,
                              _ keyPath: WritableKeyPath<ColorGrade, Double>,
                              _ property: AnimatableProperty) -> Binding<Double> {
        Binding(
            get: {
                if item.properties.hasColorGradeKeyframes {
                    let local = max(0, min(item.duration, appState.currentTime - item.startTime))
                    return item.properties.resolvedGrade(at: local)[keyPath: keyPath]
                }
                return item.properties.grade[keyPath: keyPath]
            },
            set: { newValue in
                var copy = item
                copy.properties.grade[keyPath: keyPath] = newValue
                if copy.properties.hasColorGradeKeyframes {
                    let local = max(0, min(copy.duration, appState.currentTime - copy.startTime))
                    var list = copy.properties.keyframes(for: property)
                    if let index = list.firstIndex(where: { abs($0.time - local) < 0.05 }) {
                        list[index].value = newValue
                    } else {
                        list.append(Keyframe(time: local, value: newValue))
                    }
                    copy.properties.setKeyframes(list, for: property)
                }
                copy.properties.grade = copy.properties.grade.sanitized
                appState.updateItem(copy, recordUndo: true)
            }
        )
    }


    private func transform(_ item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader("arrow.up.left.and.arrow.down.right", "变换")

            // 画中画的「缩放」是尺寸的倍率，标签写清楚免得和上面那栏混淆
            SliderRow(label: item.isOverlay ? "缩放×" : "缩放",
                      value: prop(item, \.scale),
                      range: 0.1...3.0,
                      display: "\(Int(item.properties.scale * 100))%")

            SliderRow(label: "旋转",
                      value: prop(item, \.rotation),
                      range: -180...180,
                      display: "\(Int(item.properties.rotation))°")

            SliderRow(label: "不透明度",
                      value: prop(item, \.opacity),
                      range: 0...1,
                      display: "\(Int(item.properties.opacity * 100))%")
        }
    }

    private func audio(_ item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader("speaker.wave.1", "音频")

            SliderRow(label: "音量",
                      value: prop(item, \.volume),
                      range: 0...2,
                      display: "\(Int(item.properties.volume * 100))%")

            HStack(spacing: 8) {
                Text("变速")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 52, alignment: .leading)

                SegmentedControl(options: [0.5, 1.0, 2.0],
                                 title: { String(format: "%.1f×", $0) },
                                 selection: Binding(
                                    get: { item.properties.speed },
                                    set: { newValue in
                                        var copy = item
                                        copy.properties.speed = newValue
                                        appState.updateItem(copy, recordUndo: true)
                                    }
                                 ))
            }
            .frame(height: 27)

            if item.type == .audio {
                Button {
                    appState.presentAutoDuck(for: item)
                } label: {
                    Label("自动闪避…", systemImage: "waveform.badge.mic")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SoftButtonStyle(height: 26, active: true))
                .help("按配音的语音区间或字幕时间，给这段生成音量包络")
                .padding(.top, 8)

                Text("配音响的时候把这段压下去，说完再抬回来。参考可以是另一条音频轨的语音，也可以是字幕时间。生成的是音量关键帧，之后还能手动改。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            }
        }
    }

    private func effects(_ item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader("sparkles", "转场")

            if item.isOverlay {
                // 画中画只做「浮在上面」，不参与转场；硬要给它做交叉溶解
                // 会把主画面的合成指令切碎，收益为零
                Text("画中画不参与转场。需要淡入淡出请调下面的淡入 / 淡出或关键帧。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            } else {
                transitionControls(item)
            }

            groupHeader("circle.dotted", "淡入淡出")

            // 上限和合成器一致：单侧最多片段时长的一半，拖过一半画面不会更淡
            let fadeCap = max(0.2, FadeGeometry.maxLength(duration: item.duration, other: 0))

            SliderRow(label: "淡入",
                      value: prop(item, \.fadeIn),
                      range: 0...fadeCap,
                      display: String(format: "%.1f s", item.properties.fadeIn))

            SliderRow(label: "淡出",
                      value: prop(item, \.fadeOut),
                      range: 0...fadeCap,
                      display: String(format: "%.1f s", item.properties.fadeOut))

            if item.type != .subtitle {
                let keyed = item.type == .audio
                    ? !item.properties.keyframes(for: .volume).isEmpty
                    : !item.properties.keyframes(for: .opacity).isEmpty
                if keyed {
                    fadeNote("这段已经有关键帧，淡入淡出不再叠加。")
                } else if item.transition != .none,
                          appState.transitionStatus(for: item).isActive {
                    fadeNote("入场转场生效时，淡入由转场接管。")
                } else {
                    fadeNote("也可以直接在时间线片段上边缘拖圆点调。")
                }
            }
        }
    }

    private func fadeNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.text3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 3)
    }

    /// 转场类型 + 过渡时长（画中画不显示这一组）
    @ViewBuilder
    private func transitionControls(_ item: TimelineItem) -> some View {
        HStack(spacing: 8) {
            Text("类型")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text2)
                .frame(width: 52, alignment: .leading)

            Menu {
                ForEach(TransitionType.allCases, id: \.self) { type in
                    Button {
                        var copy = item
                        copy.transition = type
                        if type == .none { copy.transitionDuration = 0 }
                        else if copy.transitionDuration <= 0 { copy.transitionDuration = 0.6 }
                        appState.updateItem(copy, recordUndo: true)
                    } label: {
                        if item.transition == type {
                            Label(type.label, systemImage: "checkmark")
                        } else {
                            Text(type.label)
                        }
                    }
                }
            } label: {
                FieldBox {
                    HStack(spacing: 5) {
                        Image(systemName: item.transition.icon)
                            .font(.system(size: 9.5))
                            .foregroundStyle(item.transition == .none ? Theme.text3 : Theme.accent)
                        Text(item.transition.label)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.text3)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .frame(height: 27)

        if item.transition != .none {
            SliderRow(label: "过渡时长",
                      value: Binding(
                        get: { item.transitionDuration },
                        set: { newValue in
                            var copy = item
                            copy.transitionDuration = newValue
                            appState.updateItem(copy, recordUndo: true)
                        }
                      ),
                      range: 0.15...1.5,
                      display: String(format: "%.1f s", item.transitionDuration))

            transitionStatusRow(item)
        }
    }

    /// 转场能不能生效，直接在面板里说清楚，别让人以为是渲染坏了
    @ViewBuilder
    private func transitionStatusRow(_ item: TimelineItem) -> some View {
        // 转场只作用于视频轨，音频 / 字幕轨不显示诊断（它们的转场本来就不参与合成）
        if item.trackKind == .video {
            transitionStatusBody(appState.transitionStatus(for: item), item: item)
        }
    }

    @ViewBuilder
    private func transitionStatusBody(_ status: TransitionStatus, item: TimelineItem) -> some View {
        if status.isProblem {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.warning)
                        .padding(.top, 1)
                    Text(status.label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                if let hint = status.hint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 15)
                }

                if status.canSnap {
                    Button {
                        appState.snapToPrevious(item.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.left.to.line")
                                .font(.system(size: 9))
                            Text("吸附到上一段")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 15)
                    .padding(.top, 1)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.warning.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.warning.opacity(0.26), lineWidth: 1))
            .padding(.top, 8)

        } else if case .active(let overlap) = status {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.ok)
                Text(String(format: "转场生效 · 与前一段重叠 %.1f s", overlap))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text2)
                Spacer(minLength: 0)
            }
            .padding(.top, 7)
        }
    }

    private func textSettings(_ item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader("textformat", "文字")

            TextField("文字内容", text: Binding(
                get: { item.properties.textContent },
                set: { newValue in
                    var copy = item
                    copy.properties.textContent = newValue
                    appState.updateItem(copy, recordUndo: true)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11.5))

            Stepper(value: Binding(
                get: { item.properties.fontSize },
                set: { newValue in
                    var copy = item
                    copy.properties.fontSize = newValue
                    appState.updateItem(copy, recordUndo: true)
                }
            ), in: 8...200) {
                Text("字号 \(item.properties.fontSize) px")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
            }
            .padding(.top, 8)

            HStack(spacing: 8) {
                Text("颜色")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 52, alignment: .leading)
                HStack(spacing: 6) {
                    ForEach(Array(Self.textColors.enumerated()), id: \.offset) { _, hex in
                        Button {
                            var copy = item
                            copy.properties.textColorHex = hex
                            appState.updateItem(copy, recordUndo: true)
                        } label: {
                            Circle()
                                .fill(Color(hex: UInt32(hex)))
                                .frame(width: 17, height: 17)
                                .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 1))
                                .overlay(
                                    Circle()
                                        .stroke(Theme.accent, lineWidth: item.properties.textColorHex == hex ? 2 : 0)
                                        .padding(-2.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 28)

            SliderRow(label: "底衬",
                      value: Binding(
                        get: { item.properties.textBoxOpacity },
                        set: { newValue in
                            var copy = item
                            copy.properties.textBoxOpacity = newValue
                            appState.updateItem(copy, recordUndo: true)
                        }
                      ),
                      range: 0...0.9,
                      display: "\(Int(item.properties.textBoxOpacity * 100))%")

            SliderRow(label: "位置",
                      value: Binding(
                        get: { item.properties.textOffsetY },
                        set: { newValue in
                            var copy = item
                            copy.properties.textOffsetY = newValue
                            appState.updateItem(copy, recordUndo: true)
                        }
                      ),
                      range: 0.02...0.6,
                      display: String(format: "%.0f%%", item.properties.textOffsetY * 100))

            HStack(spacing: 8) {
                Text("字重")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 52, alignment: .leading)
                SegmentedControl(options: [true, false],
                                 title: { $0 ? "粗体" : "常规" },
                                 selection: Binding(
                                    get: { item.properties.textBold },
                                    set: { newValue in
                                        var copy = item
                                        copy.properties.textBold = newValue
                                        appState.updateItem(copy, recordUndo: true)
                                    }
                                 ))
            }
            .frame(height: 27)
        }
    }

    // MARK: 关键帧

    private func keyframes(_ item: TimelineItem) -> some View {
        let property = kfProperty(for: item)
        let list = item.properties.keyframes(for: property)
        let localTime = max(0, min(item.duration, appState.currentTime - item.startTime))

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                groupHeader("point.topleft.down.to.point.bottomright.curvepath", "关键帧")
                Spacer()
                if !list.isEmpty {
                    Button {
                        var copy = item
                        copy.properties.setKeyframes([], for: property)
                        appState.updateItem(copy, recordUndo: true)
                    } label: {
                        Text("清空")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.text3)
                    }
                    .buttonStyle(.plain)
                }
            }

            // 属性分两行：上面是几何 / 不透明度 / 音量，下面是调色四个分量。
            // 七个挤一行的话「不透明度」会被压成「不透…」
            let allowed = availableProperties(for: item)
            let basic = allowed.filter { !$0.isColorGrade }
            let colorGrade = allowed.filter { $0.isColorGrade }
            VStack(spacing: 4) {
                SegmentedControl(options: basic,
                                 title: { $0.label },
                                 selection: Binding(
                                    get: { property },
                                    set: { selectedProperty[item.id] = $0 }
                                 ))
                if !colorGrade.isEmpty {
                    SegmentedControl(options: colorGrade,
                                     title: { $0.label },
                                     selection: Binding(
                                        get: { property },
                                        set: { selectedProperty[item.id] = $0 }
                                     ))
                }
            }

            // 曲线预览：把整段属性值画成折线，播放头位置画一条竖线
            curvePreview(item: item, property: property)

            HStack(spacing: 6) {
                Text(String(format: "播放头 %.2fs", localTime))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Button {
                    addKeyframe(item: item, property: property, at: localTime)
                } label: {
                    Label("加关键帧", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(SoftButtonStyle(height: 26, active: true))
            }

            if list.isEmpty {
                Text("还没有关键帧。把播放头移到片段内，点「加关键帧」记录当前值，再加一个就会自动补间。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(list) { frame in
                        HStack(spacing: 6) {
                            Text(String(format: "%.2fs", frame.time))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.text2)
                            Text(String(format: "%.2f%@", frame.value, property.unit))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.text3)
                            // 这个关键帧到下一个关键帧的补间方式
                            Menu {
                                ForEach(Easing.allCases) { option in
                                    Button {
                                        updateEasing(item: item, property: property,
                                                     frameID: frame.id, easing: option)
                                    } label: {
                                        Label(option.label, systemImage: option.icon)
                                    }
                                }
                            } label: {
                                Text(frame.easing == .linear ? "线性" : frame.easing.label)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(frame.easing == .linear ? Theme.text3 : Theme.accent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(
                                        Capsule().fill(frame.easing == .linear
                                                       ? Color.black.opacity(0.05)
                                                       : Theme.accentSoft)
                                    )
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("这个关键帧到下一个关键帧的补间方式")
                            Spacer()
                            Button {
                                appState.seek(to: item.startTime + frame.time)
                            } label: {
                                Image(systemName: "arrow.right.to.line")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.text3)
                            }
                            .buttonStyle(.plain)
                            Button {
                                var copy = item
                                copy.properties.setKeyframes(list.filter { $0.id != frame.id }, for: property)
                                appState.updateItem(copy, recordUndo: true)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.text3)
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(height: 24)
                        .padding(.horizontal, 8)
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func curvePreview(item: TimelineItem, property: AnimatableProperty) -> some View {
        let duration = max(0.1, item.duration)
        let range = property.range
        let samples = item.properties.keyframes(for: property)
        let headX = min(1, max(0, (appState.currentTime - item.startTime) / duration))

        return GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Theme.panel2)
                RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1)

                // 折线
                Path { path in
                    let steps = 40
                    for step in 0...steps {
                        let t = duration * Double(step) / Double(steps)
                        let value = item.properties.animatedValue(property, at: t)
                        let norm = (value - range.lowerBound) / max(0.0001, range.upperBound - range.lowerBound)
                        let x = w * CGFloat(step) / CGFloat(steps)
                        let y = h - CGFloat(min(1, max(0, norm))) * h
                        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Theme.accent, lineWidth: 1.5)

                // 关键帧点
                ForEach(samples) { frame in
                    let norm = (frame.value - range.lowerBound) / max(0.0001, range.upperBound - range.lowerBound)
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 5, height: 5)
                        .position(x: w * CGFloat(frame.time / duration),
                                  y: h - CGFloat(min(1, max(0, norm))) * h)
                }

                // 播放头
                Rectangle()
                    .fill(Theme.danger.opacity(0.6))
                    .frame(width: 1)
                    .offset(x: w * CGFloat(headX))
            }
        }
        .frame(height: 46)
    }

    private func addKeyframe(item: TimelineItem, property: AnimatableProperty, at time: Double) {
        var list = item.properties.keyframes(for: property)
        let value = item.properties.animatedValue(property, at: time)
        if let index = list.firstIndex(where: { abs($0.time - time) < 0.02 }) {
            list[index].value = value
        } else {
            list.append(Keyframe(time: time, value: value))
        }
        var copy = item
        copy.properties.setKeyframes(list, for: property)
        appState.updateItem(copy, recordUndo: true)
        appState.notify("已在 \(String(format: "%.2f", time))s 记录\(property.label)关键帧")
    }

    private func updateEasing(item: TimelineItem,
                              property: AnimatableProperty,
                              frameID: UUID,
                              easing: Easing) {
        var list = item.properties.keyframes(for: property)
        guard let index = list.firstIndex(where: { $0.id == frameID }) else { return }
        list[index].easing = easing
        var copy = item
        copy.properties.setKeyframes(list, for: property)
        appState.updateItem(copy, recordUndo: true)
        appState.notify("补间改为「\(easing.label)」")
    }

    private func availableProperties(for item: TimelineItem) -> [AnimatableProperty] {
        switch item.type {
        case .audio: return [.volume]
        case .subtitle: return [.opacity]
        case .video, .aiGenerated:
            return [.scale, .opacity, .volume] + AnimatableProperty.colorGradeProperties
        default: return [.scale, .opacity, .volume]
        }
    }

    private func kfProperty(for item: TimelineItem) -> AnimatableProperty {
        let allowed = availableProperties(for: item)
        if let stored = selectedProperty[item.id], allowed.contains(stored) { return stored }
        // 没记忆时优先选「已经有关键帧」的那条：给曝光打了动画、
        // 切走再切回来，不该看到一片空白让人以为动画丢了
        if let animated = allowed.first(where: { !item.properties.keyframes(for: $0).isEmpty }) {
            return animated
        }
        return allowed.first ?? .opacity
    }

    static let textColors: [Int] = [0xFFFFFF, 0xFFD166, 0x7C6BFF, 0x12B76A, 0xFF5A5F, 0x111318]

    // MARK: 属性绑定

    private func prop(_ item: TimelineItem,
                      _ keyPath: WritableKeyPath<ItemProperties, Double>) -> Binding<Double> {
        Binding(
            get: { item.properties[keyPath: keyPath] },
            set: { newValue in
                var copy = item
                copy.properties[keyPath: keyPath] = newValue
                appState.updateItem(copy, recordUndo: true)
            }
        )
    }
}
