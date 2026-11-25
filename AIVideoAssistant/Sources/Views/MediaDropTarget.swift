//
//  MediaDropTarget.swift
//  拖放落点：集合胶囊（拖素材入组）、卡片（集合内拖动排序）
//
//  素材卡片拖出去带的是 fileURL（时间线也认这个格式），
//  所以这里统一把落下来的 fileURL 换算成素材库里的素材。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 解析拖入的 URL

enum MediaDrop {

    /// 把拖放的 item provider 解析成文件 URL 列表（可能为空）
    static func urls(from providers: [NSItemProvider],
                     completion: @escaping ([URL]) -> Void) {
        guard !providers.isEmpty else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = resolve(item) {
                    lock.lock()
                    collected.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(collected)
        }
    }

    private static func resolve(_ item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = item as? String { return URL(string: string) }
        return nil
    }
}

// MARK: - 集合胶囊（可接收拖放）

/// 比普通 Chip 多一层：拖素材上来时描边高亮 + 轻微放大，松手就入组
struct CollectionChip: View {
    let info: CollectionInfo
    let selected: Bool
    var onTap: () -> Void
    var onDropURLs: ([URL]) -> Void

    @State private var targeted = false

    var body: some View {
        Chip(text: "\(info.name) \(info.count)",
             icon: "folder.fill",
             selected: selected,
             action: onTap)
            .overlay(
                Capsule()
                    .stroke(Theme.accent, lineWidth: targeted ? 2 : 0)
                    .padding(-2.5)
            )
            .shadow(color: Theme.accent.opacity(targeted ? 0.28 : 0),
                    radius: targeted ? 6 : 0,
                    y: 1)
            .scaleEffect(targeted ? 1.06 : 1)
            .animation(.easeOut(duration: 0.12), value: targeted)
            .contentShape(Capsule())
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                MediaDrop.urls(from: providers, completion: onDropURLs)
                return true
            }
            .help(targeted
                  ? "松手把素材加入「\(info.name)」"
                  : "「\(info.name)」· \(info.count) 个素材 · 可以把素材卡片拖到这里加入")
    }
}

// MARK: - 卡片上的排序落点

/// 只在「集合顺序」模式下挂上：把拖过来的素材挪到这张卡片的位置
struct ReorderDropModifier: ViewModifier {
    let onDropURLs: (([URL]) -> Void)?

    @State private var targeted = false

    func body(content: Content) -> some View {
        if let onDropURLs {
            content
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Theme.accent, lineWidth: targeted ? 2.5 : 0)
                )
                .scaleEffect(targeted ? 1.025 : 1)
                .animation(.easeOut(duration: 0.1), value: targeted)
                .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                    MediaDrop.urls(from: providers, completion: onDropURLs)
                    return true
                }
        } else {
            content
        }
    }
}
