//
//  PropertiesPanel.swift
//  属性检查器
//

import SwiftUI

struct PropertiesPanel: View {
    @EnvironmentObject var appState: AppState

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
