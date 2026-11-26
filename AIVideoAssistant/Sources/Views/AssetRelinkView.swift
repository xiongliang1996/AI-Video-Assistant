//
//  AssetRelinkView.swift
//  素材重连面板：文件被移动 / 改名后，把引用指回新位置
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AssetRelinkView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    /// 逐条定位时正在处理哪一条（用来在按钮上转圈）
    @State private var busyPath: String?

    private var candidates: [AssetRelinker.Missing] { appState.relinkCandidates }

    var body: some View {
        VStack(spacing: 0) {
            header

            if candidates.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(candidates) { item in
                            row(item)
                        }
                    }
                    .padding(14)
                }
            }

            footer
        }
        .frame(width: 580, height: 470)
        .background(Theme.panel)
    }

    // MARK: 头

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: candidates.isEmpty ? "link.circle" : "link.badge.plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(candidates.isEmpty ? Theme.ok : Theme.warning)

            VStack(alignment: .leading, spacing: 1) {
                Text("重连缺失素材")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
            }

            Spacer()

            Button {
                appState.relinkCandidates = appState.scanMissingAssets()
            } label: {
                Label("重新扫描", systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(SoftButtonStyle(height: 24))

            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 22))
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(Theme.panel2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var subtitle: String {
        guard !candidates.isEmpty else { return "所有素材都在原位" }
        let clips = candidates.reduce(0) { $0 + $1.clipCount }
        if clips > 0 {
            return "\(candidates.count) 个素材找不到文件，影响 \(clips) 个片段"
        }
        return "\(candidates.count) 个素材找不到文件"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 24))
                .foregroundStyle(Theme.ok)
            Text("没有缺失的素材")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text2)
            Text("文件被移动或改名后会出现在这里")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 单条

    private func row(_ item: AssetRelinker.Missing) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.clipCount > 0 ? "exclamationmark.triangle.fill" : "questionmark.folder")
                .font(.system(size: 11))
                .foregroundStyle(item.clipCount > 0 ? Theme.danger : Theme.warning)
                .frame(width: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if item.clipCount > 0 {
                        Text("\(item.clipCount) 个片段")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.danger)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.danger.opacity(0.12)))
                    }

                    if !item.inLibrary {
                        Text("仅时间线")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.text3)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.text3.opacity(0.12)))
                    }

                    Spacer(minLength: 0)
                }

                Text(item.directory)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path)
            }

            Button {
                pickFile(for: item)
            } label: {
                Text(busyPath == item.path ? "定位中…" : "定位…")
                    .font(.system(size: 11))
                    .frame(minWidth: 42)
            }
            .buttonStyle(SoftButtonStyle(height: 24))
            .disabled(busyPath != nil)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
    }

    // MARK: 底

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                pickDirectory()
            } label: {
                Label("选择文件夹自动匹配…", systemImage: "folder.badge.questionmark")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(SoftButtonStyle(height: 30))
            .disabled(candidates.isEmpty)
            .help("按文件名在所选文件夹里找同名文件，一次修完整个目录")

            Spacer()

            Button("关闭") { dismiss() }
                .buttonStyle(SoftButtonStyle(height: 30))
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(Theme.panel2)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: 选择文件

    private func pickFile(for item: AssetRelinker.Missing) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择「\(item.name)」的新位置"
        panel.prompt = "重连"
        panel.directoryURL = URL(fileURLWithPath: item.directory)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        busyPath = item.path
        let changed = appState.relinkAsset(oldPath: item.path, to: url)
        busyPath = nil

        if changed == 0 && !appState.relinkCandidates.contains(where: { $0.path == item.path }) {
            // 没有片段在用这条素材，只修了素材库；同样算成功
            appState.notify("已重连「\(item.name)」")
        }
        if appState.relinkCandidates.isEmpty { dismiss() }
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择素材所在的新文件夹，会按文件名自动匹配"
        panel.prompt = "自动匹配"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.relinkAssets(inDirectory: url)
        if appState.relinkCandidates.isEmpty { dismiss() }
    }
}
