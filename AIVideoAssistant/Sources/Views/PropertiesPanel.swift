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
                Text(appState.selectedItem?.name ?? "未选择")
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
            } else {
                EmptyHint(icon: "slider.horizontal.3",
                          title: "未选中片段",
                          subtitle: "点击时间线上的片段查看属性")
            }
        }
        .frame(width: 288)
        .background(Theme.panel2)
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
                                        appState.updateItem(copy)
                                    }
                                 ))
            }
            .frame(height: 27)
        }
    }

    private func effects(_ item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader("sparkles", "效果")

            HStack(spacing: 8) {
                Text("转场")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 52, alignment: .leading)
                FieldBox {
                    HStack {
                        Text("交叉溶解").foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.text3)
                    }
                }
            }
            .frame(height: 27)

            HStack(spacing: 8) {
                Text("滤镜")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 52, alignment: .leading)
                FieldBox {
                    HStack {
                        Text("电影暖调").foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.text3)
                    }
                }
            }
            .frame(height: 27)
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
                    appState.updateItem(copy)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11.5))

            Stepper(value: Binding(
                get: { item.properties.fontSize },
                set: { newValue in
                    var copy = item
                    copy.properties.fontSize = newValue
                    appState.updateItem(copy)
                }
            ), in: 8...200) {
                Text("字号 \(item.properties.fontSize) px")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
            }
            .padding(.top, 8)
        }
    }

    // MARK: 属性绑定

    private func prop(_ item: TimelineItem,
                      _ keyPath: WritableKeyPath<ItemProperties, Double>) -> Binding<Double> {
        Binding(
            get: { item.properties[keyPath: keyPath] },
            set: { newValue in
                var copy = item
                copy.properties[keyPath: keyPath] = newValue
                appState.updateItem(copy)
            }
        )
    }
}
