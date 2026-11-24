//
//  MainWindowView.swift
//  应用外壳：侧边栏 + 内容区 + 全局反馈
//

import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
            Rectangle()
                .fill(Theme.line)
                .frame(width: 1)
            content
        }
        .background(Theme.bg)
        .sheet(isPresented: $appState.showingSettings) {
            SettingsView()
                .environmentObject(appState)
        }
        .overlay(alignment: .bottom) { toastLayer }
        .overlay { processingLayer }
        .alert("提示", isPresented: errorBinding) {
            Button("好", role: .cancel) { appState.clearError() }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appState.selectedPanel {
        case .editor:
            EditorView()
        case .generate:
            AIGenerateView()
        case .tts:
            TTSView()
        case .subtitle:
            SubtitleView()
        case .library:
            MediaLibraryView()
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.clearError() } }
        )
    }

    @ViewBuilder
    private var toastLayer: some View {
        if let toast = appState.toast {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0x4ADE80))
                Text(toast)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(Color(hex: 0x161822, alpha: 0.94))
            )
            .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            .padding(.bottom, 26)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var processingLayer: some View {
        if let state = appState.processing {
            ZStack {
                Color(hex: 0xF7F8FB, alpha: 0.72)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                        .scaleEffect(1.1)
                    Text(state.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(state.message)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                    ProgressView(value: min(max(state.progress, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                        .frame(width: 240)
                }
                .padding(24)
                .frame(width: 320)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Theme.panel)
                        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
                )
            }
        }
    }
}

// MARK: - 侧边栏

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            brand
            ScrollView {
                VStack(spacing: 1) {
                    SectionLabel(text: "当前项目")
                    projectRow

                    SectionLabel(text: "创作")
                    ForEach([Panel.editor, .generate, .tts, .subtitle]) { panel in
                        navRow(panel, badge: panel == .generate ? "AI" : nil)
                    }

                    SectionLabel(text: "素材")
                    navRow(.library, trailing: "\(appState.mediaLibrary.count)")
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
            footer
        }
        .frame(width: 216)
        .background(Theme.sidebar)
    }

    private var brand: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.brandGradient)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                )
                .shadow(color: Theme.accent.opacity(0.35), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text("AI 视频助手")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("v1.0 · 个人版")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var projectRow: some View {
        Menu {
            ForEach(appState.projects) { project in
                Button {
                    appState.selectProject(project)
                } label: {
                    if project.id == appState.currentProject.id {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
            Divider()
            Button("新建项目…") { appState.createProject() }
            Button("打开项目…") { appState.openProject() }
            Divider()
            Button("在访达中显示项目文件") { appState.revealProjectFile() }
            Button("删除当前项目", role: .destructive) {
                appState.deleteProject(appState.currentProject)
            }
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.thumb(for: appState.currentProject.id))
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.currentProject.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text("\(appState.currentProject.settings.resolution.rawValue) · \(appState.currentProject.settings.fps)fps")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.text3)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 10)
    }

    private func navRow(_ panel: Panel, badge: String? = nil, trailing: String? = nil) -> some View {
        let isOn = appState.selectedPanel == panel
        return Button {
            appState.selectedPanel = panel
        } label: {
            HStack(spacing: 9) {
                Image(systemName: panel.icon)
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 15)
                Text(panel.rawValue)
                    .font(.system(size: 12.5, weight: isOn ? .medium : .regular))
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.brandGradient))
                }
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                }
            }
            .foregroundStyle(isOn ? Theme.accent : Color(hex: 0x3A3D48))
            .padding(.horizontal, 9)
            .frame(height: 31)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? Theme.accentSoft : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    private var footer: some View {
        VStack(spacing: 1) {
            Rectangle().fill(Theme.line).frame(height: 1).padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("本地缓存")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.text3)
                    Spacer()
                    Text("0 / 20 GB")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.text3)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.08))
                        Capsule().fill(Theme.brandGradient).frame(width: geo.size.width * 0.02)
                    }
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 17)
            .padding(.bottom, 8)

            Button {
                appState.showingSettings = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .frame(width: 15)
                    Text("设置")
                        .font(.system(size: 12.5))
                    Spacer()
                    Text("⌘,")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                }
                .foregroundStyle(Color(hex: 0x3A3D48))
                .padding(.horizontal, 9)
                .frame(height: 31)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
}
