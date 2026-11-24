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
                        transform(item)
                        divider
                        audio(item)
                        divider
                        effects(item)
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

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                groupHeader("square.stack.3d.up", "多选")
                infoRow("片段数", "\(items.count)")
                infoRow("时间跨度", "\(formatTimecode(start)) – \(formatTimecode(end))")
                infoRow("片段总长", String(format: "%.1f s", total))
                if videoCount > 0 { infoRow("视频", "\(videoCount)") }
                if audioCount > 0 { infoRow("音频", "\(audioCount)") }
                if textCount > 0 { infoRow("字幕", "\(textCount)") }

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
                                     title: { "A\($0 + 1)" },
                                     selection: Binding(
                                        get: { item.trackLane },
                                        set: { appState.moveToLane(item, lane: $0) }
                                     ))
                }
                .frame(height: 27)
            }
        }
    }

    private func transform(_ item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader("arrow.up.left.and.arrow.down.right", "变换")

            SliderRow(label: "缩放",
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
        }
    }

    private func effects(_ item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader("sparkles", "转场")

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

            groupHeader("circle.dotted", "淡入淡出")

            SliderRow(label: "淡入",
                      value: prop(item, \.fadeIn),
                      range: 0...2,
                      display: String(format: "%.1f s", item.properties.fadeIn))

            SliderRow(label: "淡出",
                      value: prop(item, \.fadeOut),
                      range: 0...2,
                      display: String(format: "%.1f s", item.properties.fadeOut))
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

            SegmentedControl(options: availableProperties(for: item),
                             title: { $0.label },
                             selection: Binding(
                                get: { property },
                                set: { selectedProperty[item.id] = $0 }
                             ))

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
        default: return [.scale, .opacity, .volume]
        }
    }

    private func kfProperty(for item: TimelineItem) -> AnimatableProperty {
        let allowed = availableProperties(for: item)
        if let stored = selectedProperty[item.id], allowed.contains(stored) { return stored }
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
