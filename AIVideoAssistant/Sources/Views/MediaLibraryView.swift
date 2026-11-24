//
//  MediaLibraryView.swift
//  媒体库
//

import SwiftUI
import AppKit

struct MediaLibraryView: View {
    @EnvironmentObject var appState: AppState

    @State private var filter: Filter = .all
    @State private var selected: Set<UUID> = []

    enum Filter: String, CaseIterable {
        case all = "全部"
        case video = "视频"
        case audio = "音频"
        case image = "图片"
    }

    private var filtered: [MediaAsset] {
        switch filter {
        case .all: return appState.mediaLibrary
        case .video: return appState.mediaLibrary.filter { $0.type == .video }
        case .audio: return appState.mediaLibrary.filter { $0.type == .audio }
        case .image: return appState.mediaLibrary.filter { $0.type == .image }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            VStack(alignment: .leading, spacing: 12) {
                filterRow
                if appState.mediaLibrary.isEmpty {
                    Card {
                        EmptyHint(icon: "photo.on.rectangle.angled",
                                  title: "媒体库是空的",
                                  subtitle: "导入视频、音频或图片开始创作")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                                  spacing: 12) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, asset in
                                LibraryCard(asset: asset,
                                            index: index,
                                            selected: selected.contains(asset.id)) {
                                    if selected.contains(asset.id) {
                                        selected.remove(asset.id)
                                    } else {
                                        selected.insert(asset.id)
                                    }
                                } onAdd: {
                                    appState.addToTimeline(asset)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("媒体库")
                    .font(.system(size: 14, weight: .semibold))
                Text("· \(appState.mediaLibrary.count) 个素材")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
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

    private var filterRow: some View {
        HStack(spacing: 6) {
            ForEach(Filter.allCases, id: \.self) { item in
                Chip(text: item.rawValue, selected: filter == item) {
                    filter = item
                }
            }
            Spacer()
            if !selected.isEmpty {
                Text("已选 \(selected.count) 项")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                Button("加入时间线") {
                    for asset in appState.mediaLibrary where selected.contains(asset.id) {
                        appState.addToTimeline(asset)
                    }
                    selected.removeAll()
                }
                .buttonStyle(SoftButtonStyle(height: 25))
            }
        }
    }
}

struct LibraryCard: View {
    @ObservedObject var asset: MediaAsset
    let index: Int
    let selected: Bool
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
                HStack {
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
                    Text("\(asset.durationText) · \(asset.type.rawValue)")
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
        .help("\(asset.name) · \(asset.durationText)")
    }
}
