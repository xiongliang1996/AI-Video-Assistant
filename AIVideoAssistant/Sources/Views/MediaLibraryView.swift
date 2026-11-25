//
//  MediaLibraryView.swift
//  媒体库：搜索 / 排序 / 分组 / 未使用清理
//

import SwiftUI
import AppKit

struct MediaLibraryView: View {
    @EnvironmentObject var appState: AppState

    @State private var query: MediaQuery
    @State private var selected: Set<UUID> = []
    @State private var grouped: Bool
    @State private var confirmRemove = false
    @State private var confirmCleanup = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    /// 初始筛选条件只用于预览 / 截图验证，正常运行时是默认值
    init(initialQuery: MediaQuery = MediaQuery(), grouped: Bool = true) {
        _query = State(initialValue: initialQuery)
        _grouped = State(initialValue: grouped)
    }

    // MARK: - 派生数据

    private var usage: MediaUsage { appState.mediaUsage }

    private var counts: MediaTypeCounts {
        MediaShelf.counts(for: appState.mediaLibrary, query: query, usage: usage)
    }

    private var visible: [MediaAsset] {
        MediaShelf.apply(query, to: appState.mediaLibrary, usage: usage)
    }

    private var sections: [MediaSection] {
        MediaShelf.sections(visible, grouped: grouped)
    }

    private var unusedCount: Int {
        MediaShelf.unusedIDs(appState.mediaLibrary, usage: usage).count
    }

    /// 已选里有多少个还被时间线用着（移出前提示用）
    private var selectedInUse: Int {
        let u = usage
        return appState.mediaLibrary.filter { selected.contains($0.id) && u.count($0) > 0 }.count
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 10) {
                filterRow
                content
            }
            .padding(16)
        }
        .background(Theme.bg)
        .alert("移出素材库？", isPresented: $confirmRemove) {
            Button("移出", role: .destructive) {
                appState.removeMedia(ids: selected)
                selected.removeAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(removeMessage)
        }
    }

    private var removeMessage: String {
        var text = "将从素材库移除 \(selected.count) 个素材。磁盘上的文件不会被删除"
        if selectedInUse > 0 {
            text += "，其中 \(selectedInUse) 个仍被时间线使用，片段会保留但不再显示在素材库"
        }
        return text + "。"
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("媒体库")
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
            }

            Spacer(minLength: 12)

            searchField
            sortControl
            directionButton
            groupButton

            Button {
                appState.importMedia()
            } label: {
                Label("导入素材", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Theme.panel.opacity(0.72))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var subtitle: String {
        guard !appState.mediaLibrary.isEmpty else { return "还没有素材" }
        if query.isFiltering {
            return "筛出 \(visible.count) / \(appState.mediaLibrary.count) 个"
        }
        if unusedCount > 0 {
            return "\(appState.mediaLibrary.count) 个素材 · \(unusedCount) 个未使用"
        }
        return "\(appState.mediaLibrary.count) 个素材 · 全部已使用"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
            TextField("搜索名称 / 类型", text: $query.search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 150)
            if !query.search.isEmpty {
                Button {
                    query.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.panel))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.line2, lineWidth: 1)
        )
    }

    private var sortControl: some View {
        Menu {
            ForEach(MediaSort.allCases) { sort in
                Button {
                    query.sort = sort
                } label: {
                    if query.sort == sort {
                        Label(sort.label, systemImage: "checkmark")
                    } else {
                        Text(sort.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: query.sort.icon)
                    .font(.system(size: 10.5))
                Text(query.sort.label)
                    .font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.panel))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.line2, lineWidth: 1)
            )
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("排序方式")
    }

    private var directionButton: some View {
        Button {
            query.descending.toggle()
        } label: {
            Image(systemName: query.descending ? "arrow.down" : "arrow.up")
                .font(.system(size: 10.5, weight: .semibold))
        }
        .buttonStyle(IconButtonStyle(size: 28))
        .disabled(!query.sort.supportsDescending)
        .opacity(query.sort.supportsDescending ? 1 : 0.3)
        .help(query.descending ? "当前倒序，点一下改成正序" : "当前正序，点一下改成倒序")
    }

    private var groupButton: some View {
        Button {
            grouped.toggle()
        } label: {
            Image(systemName: grouped ? "rectangle.grid.1x2" : "square.grid.2x2")
                .font(.system(size: 11.5))
        }
        .buttonStyle(IconButtonStyle(active: grouped, size: 28))
        .help(grouped ? "已按类型分组，点一下平铺" : "平铺显示，点一下按类型分组")
    }

    // MARK: - 筛选行

    private var filterRow: some View {
        HStack(spacing: 6) {
            typeChip(nil, text: "全部")
            typeChip(.video, text: "视频")
            typeChip(.audio, text: "音频")
            typeChip(.image, text: "图片")

            Rectangle()
                .fill(Theme.line2)
                .frame(width: 1, height: 16)
                .padding(.horizontal, 2)

            Chip(text: "未使用 \(unusedCount)",
                 icon: "circle.dashed",
                 selected: query.unusedOnly) {
                query.unusedOnly.toggle()
            }
            .disabled(unusedCount == 0 && !query.unusedOnly)
            .opacity(unusedCount == 0 && !query.unusedOnly ? 0.45 : 1)

            Spacer(minLength: 8)

            if selected.isEmpty {
                if !visible.isEmpty {
                    Button {
                        selected = Set(visible.map(\.id))
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .help("选中当前筛选结果")
                }
                cleanupButton
            } else {
                Text("已选 \(selected.count) 项")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                Button {
                    for asset in appState.mediaLibrary where selected.contains(asset.id) {
                        appState.addToTimeline(asset)
                    }
                    selected.removeAll()
                } label: {
                    Label("加入时间线", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(SoftButtonStyle(height: 26))
                Button {
                    confirmRemove = true
                } label: {
                    Label("移出素材库", systemImage: "minus.circle")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.danger)
                }
                .buttonStyle(SoftButtonStyle(height: 26))
                Button {
                    selected.removeAll()
                } label: {
                    Text("取消")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(SoftButtonStyle(height: 26))
            }
        }
    }

    private func typeChip(_ type: MediaType?, text: String) -> some View {
        let count = counts[type]
        let dimmed = count == 0 && query.type != type
        let action: (() -> Void)? = dimmed ? nil : { query.type = type }
        return Chip(text: "\(text) \(count)",
                    selected: query.type == type,
                    action: action)
            .opacity(dimmed ? 0.45 : 1)
    }

    private var cleanupButton: some View {
        Button {
            confirmCleanup = true
        } label: {
            Label("清理未使用", systemImage: "trash.slash")
                .font(.system(size: 11.5, weight: .medium))
        }
        .buttonStyle(SoftButtonStyle(height: 26))
        .disabled(unusedCount == 0)
        .opacity(unusedCount == 0 ? 0.45 : 1)
        .help(unusedCount == 0 ? "所有素材都在时间线里用到了" : "移出 \(unusedCount) 个没被时间线使用的素材")
        .alert("清理未使用素材？", isPresented: $confirmCleanup) {
            Button("移出 \(unusedCount) 个", role: .destructive) {
                appState.removeUnusedMedia()
                selected.removeAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会从素材库移除这 \(unusedCount) 个素材，磁盘上的文件保留，随时可以重新导入。")
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if appState.mediaLibrary.isEmpty {
            Card {
                EmptyHint(icon: "photo.on.rectangle.angled",
                          title: "媒体库是空的",
                          subtitle: "导入视频、音频或图片开始创作")
            }
        } else if visible.isEmpty {
            Card {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Theme.text3)
                    Text("没有匹配的素材")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                    Text(emptyHintText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                    Button {
                        resetFilters()
                    } label: {
                        Text("清除筛选条件")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(SoftButtonStyle(height: 26))
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(sections) { section in
                        if let type = section.type {
                            sectionHeader(type: type, count: section.assets.count)
                        }
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(Array(section.assets.enumerated()), id: \.element.id) { index, asset in
                                LibraryCard(asset: asset,
                                            index: index,
                                            selected: selected.contains(asset.id),
                                            usageCount: usage.count(asset)) {
                                    toggleSelection(asset)
                                } onAdd: {
                                    appState.addToTimeline(asset)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private var emptyHintText: String {
        var parts: [String] = []
        if !query.search.isEmpty { parts.append("关键词「\(query.search)」") }
        if let type = query.type { parts.append(type.label) }
        if query.unusedOnly { parts.append("只看未使用") }
        return parts.isEmpty ? "试试换个关键词" : parts.joined(separator: " · ") + " 下没有结果"
    }

    private func sectionHeader(type: MediaType, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: type.icon)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
            Text(type.label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
            Text("\(count)")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)
        }
        .padding(.top, 2)
    }

    // MARK: - 操作

    private func toggleSelection(_ asset: MediaAsset) {
        if selected.contains(asset.id) {
            selected.remove(asset.id)
        } else {
            selected.insert(asset.id)
        }
    }

    private func resetFilters() {
        query.search = ""
        query.type = nil
        query.unusedOnly = false
    }
}

// MARK: - 卡片

struct LibraryCard: View {
    @ObservedObject var asset: MediaAsset
    let index: Int
    let selected: Bool
    /// 被时间线引用了多少次
    var usageCount: Int = 0
    let onToggle: () -> Void
    let onAdd: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack {
            if let image = asset.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.thumb(index)
            }

            LinearGradient(colors: [.clear, .black.opacity(0.7)],
                           startPoint: .center, endPoint: .bottom)

            VStack {
                HStack(alignment: .top) {
                    usageBadge
                    Spacer()
                    Button(action: onToggle) {
                        ZStack {
                            Circle()
                                .fill(selected ? Theme.accent : Color.black.opacity(0.25))
                                .frame(width: 16, height: 16)
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering || selected ? 1 : 0)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 1) {
                    Text(asset.name)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                    Text(metaText)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(7)

            if hovering {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: onAdd) {
                            Label("加入时间线", systemImage: "plus")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(SoftButtonStyle(height: 24))
                    }
                }
                .padding(7)
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? Theme.accent : Theme.line, lineWidth: selected ? 2 : 1)
        )
        .onHover { hovering = $0 }
        .mediaSkim(asset, cornerRadius: 9)
        .onDrag {
            NSItemProvider(contentsOf: asset.url) ?? NSItemProvider()
        } preview: {
            MediaDragPreview(asset: asset, index: index)
        }
        .onTapGesture(count: 2) {
            onAdd()
        }
        .help(helpText)
    }

    /// 左上角：被时间线用了几次。没用到的素材不显示，避免整屏都是标签
    @ViewBuilder
    private var usageBadge: some View {
        if usageCount > 0 {
            HStack(spacing: 2.5) {
                Image(systemName: "timeline.selection")
                    .font(.system(size: 7.5, weight: .semibold))
                Text(usageCount > 1 ? "×\(usageCount)" : "已用")
                    .font(.system(size: 8.5, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(.black.opacity(0.42)))
            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
        }
    }

    /// 图片没有时长，显示分辨率更有用
    private var metaText: String {
        if asset.type == .image {
            let w = Int(asset.resolution.width.rounded())
            let h = Int(asset.resolution.height.rounded())
            return w > 0 && h > 0 ? "\(w)×\(h) · \(asset.type.label)" : asset.type.label
        }
        return "\(asset.durationText) · \(asset.type.label)"
    }

    private var helpText: String {
        var text = "\(asset.name) · \(metaText)"
        text += usageCount > 0 ? " · 时间线用了 \(usageCount) 次" : " · 未使用"
        return text
    }
}
