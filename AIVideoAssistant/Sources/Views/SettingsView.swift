//
//  SettingsView.swift
//  API 配置
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var tab = 0
    @State private var draft = AIConfig()
    @State private var testResult: String?
    @State private var presetSheet = false

    /// initialTab 只用于预览 / 截图验证
    init(initialTab: Int = 0) {
        _tab = State(initialValue: initialTab)
    }

    private let tabs: [(String, String)] = [
        ("OpenAI", "sparkles"),
        ("AI 配音", "speaker.wave.2"),
        ("导出", "film"),
        ("关于", "info.circle")
    ]

    var body: some View {
        HStack(spacing: 0) {
            nav
            Rectangle().fill(Theme.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(Theme.line).frame(height: 1)
                ScrollView {
                    Group {
                        switch tab {
                        case 0: openAIPane
                        case 1: ttsPane
                        case 2: exportPane
                        default: aboutPane
                        }
                    }
                    .padding(16)
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                footer
            }
        }
        .frame(width: 648, height: 470)
        .background(Theme.panel)
        .onAppear { draft = appState.aiConfig }
    }

    private var nav: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("设置")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 9)
                .padding(.top, 8)
                .padding(.bottom, 8)

            ForEach(Array(tabs.enumerated()), id: \.offset) { index, item in
                Button {
                    tab = index
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.1)
                            .font(.system(size: 11.5))
                            .frame(width: 14)
                        Text(item.0)
                            .font(.system(size: 12, weight: tab == index ? .medium : .regular))
                        Spacer()
                    }
                    .foregroundStyle(tab == index ? Theme.text : Theme.text2)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(tab == index ? Theme.panel : Color.clear)
                            .shadow(color: .black.opacity(tab == index ? 0.06 : 0), radius: 1, y: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: 158)
        .background(Theme.sidebar)
    }

    private var header: some View {
        HStack {
            Text("\(tabs[tab].0) 配置")
                .font(.system(size: 12.5, weight: .semibold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 24))
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("测试连接") { testConnection() }
                .buttonStyle(SoftButtonStyle())
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(SoftButtonStyle())
            Button("保存") {
                appState.aiConfig = draft
                AIConfigManager.shared.save(draft)
                appState.notify("设置已保存到钥匙串")
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(Theme.panel2)
    }

    // MARK: - OpenAI

    private var openAIPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            formField("API Key") {
                SecureField("sk-...", text: $draft.openAIKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            note("密钥保存在系统钥匙串，不会明文落盘", icon: "lock")

            formField("Base URL") {
                TextField("https://api.openai.com/v1", text: $draft.openAIBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            HStack(spacing: 10) {
                formField("图像模型") {
                    Picker("", selection: $draft.imageModel) {
                        Text("DALL·E 3").tag("dall-e-3")
                        Text("DALL·E 2").tag("dall-e-2")
                    }
                    .labelsHidden()
                }
                formField("语音识别") {
                    Picker("", selection: $draft.whisperModel) {
                        Text("Whisper-1").tag("whisper-1")
                    }
                    .labelsHidden()
                }
            }

            if let testResult {
                Text(testResult)
                    .font(.system(size: 10.5))
                    .foregroundStyle(testResult.contains("成功") ? Theme.ok : Theme.danger)
            }
        }
    }

    // MARK: - TTS

    private var ttsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            formField("默认引擎") {
                Picker("", selection: $draft.ttsProvider) {
                    ForEach(TTSProvider.allCases, id: \.self) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .labelsHidden()
            }
            note(draft.ttsProvider.summary, icon: "info.circle")

            groupTitle("Azure TTS")
            formField("API Key") {
                SecureField("Azure Key", text: $draft.azureKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            formField("区域") {
                TextField("eastasia", text: $draft.azureRegion)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            groupTitle("讯飞语音")
            formField("App ID") {
                TextField("App ID", text: $draft.xfyunAppID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            formField("API Key") {
                SecureField("API Key", text: $draft.xfyunAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            formField("API Secret") {
                SecureField("API Secret", text: $draft.xfyunAPISecret)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
    }

    // MARK: - 导出

    private var exportPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            presetSection

            Divider()

            HStack(alignment: .top, spacing: 12) {
                formField("分辨率") {
                    Picker("", selection: Binding(
                        get: { appState.currentProject.settings.resolution },
                        set: { value in
                            appState.updateExportSettings { $0.resolution = value }
                        }
                    )) {
                        ForEach(ExportResolution.allCases, id: \.self) { res in
                            Text("\(res.rawValue) · \(res.label)").tag(res)
                        }
                    }
                    .labelsHidden()
                }

                formField("帧率") {
                    Picker("", selection: Binding(
                        get: { appState.currentProject.settings.fps },
                        set: { value in
                            appState.updateExportSettings { $0.fps = value }
                        }
                    )) {
                        Text("24 fps").tag(24)
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .labelsHidden()
                }

                formField("画质") {
                    Picker("", selection: Binding(
                        get: { appState.currentProject.settings.quality },
                        set: { value in
                            appState.updateExportSettings { $0.quality = value }
                        }
                    )) {
                        ForEach(ExportQuality.allCases, id: \.self) { q in
                            Text(q.rawValue).tag(q)
                        }
                    }
                    .labelsHidden()
                }
            }

            formField("画幅填充") {
                VStack(alignment: .leading, spacing: 6) {
                    SegmentedControl(options: ExportFillMode.allCases,
                                     title: { $0.shortLabel },
                                     selection: Binding(
                                        get: { appState.currentProject.settings.fillMode },
                                        set: { value in
                                            appState.updateExportSettings { $0.fillMode = value }
                                        }
                                     ))
                    note(appState.currentProject.settings.fillMode.label,
                         icon: appState.currentProject.settings.fillMode.icon)
                }
            }

            if appState.currentProject.settings.resolution.isPortraitOrSquare {
                note("素材是 16:9 时，选「填满」会裁掉左右两边；选「适应」会上下留黑边", icon: "info.circle")
            } else {
                note("导出使用 AVFoundation 硬件编码，H.264 / ProRes 自动选择", icon: "info.circle")
            }
        }
    }

    /// 预设：一排胶囊 + 存为预设 / 删除
    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("导出预设")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text2)
                if let active = appState.activeExportPreset {
                    Text(active.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.text3)
                } else {
                    Text("当前是自定义参数")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.warning)
                }
                Spacer()
                Button {
                    presetSheet = true
                } label: {
                    Text("存为预设")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(SoftButtonStyle(height: 24))
                .help("把当前分辨率 / 帧率 / 画质 / 填充方式存成一套预设")

                if let active = appState.activeExportPreset, !active.isBuiltin {
                    Button {
                        appState.deleteExportPreset(active.id)
                    } label: {
                        Text("删除")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(SoftButtonStyle(height: 24))
                    .help("删除预设「\(active.name)」")
                }
            }

            // 用自适应网格而不是横向滚动：预设一般就六七个，
            // 横滑会在右边切出半截胶囊，看着像坏了
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 6, alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(appState.exportPresets) { preset in
                    Chip(text: preset.name,
                         icon: preset.isBuiltin ? "film" : "square.stack.3d.up",
                         selected: appState.activeExportPreset?.id == preset.id) {
                        appState.applyExportPreset(preset)
                    }
                    .help("\(preset.summary) · \(preset.aspectLabel)")
                }
            }
        }
        .sheet(isPresented: $presetSheet) {
            CollectionNameSheet(title: "存为导出预设",
                                placeholder: "例如：客户交付 / 抖音竖屏",
                                confirmTitle: "保存",
                                icon: "square.stack.3d.up") { name in
                appState.saveExportPreset(named: name)
                presetSheet = false
            } onCancel: {
                presetSheet = false
            }
        }
    }

    // MARK: - 关于

    private var aboutPane: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.brandGradient)
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white))
                .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 6)

            Text("AI 视频助手")
                .font(.system(size: 18, weight: .semibold))
            Text("版本 1.0.0 · macOS 13+")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text3)
            Text("用 AI 讲一个好故事")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text2)

            HStack(spacing: 8) {
                Chip(text: "SwiftUI", icon: "swift")
                Chip(text: "AVFoundation", icon: "film")
                Chip(text: "OpenAI", icon: "sparkles")
            }
            .padding(.top, 6)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    // MARK: - 组件

    private func formField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text2)
            content()
        }
    }

    private func note(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
            Text(text)
                .font(.system(size: 10.5))
        }
        .foregroundStyle(Theme.text3)
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.text3)
            .padding(.top, 4)
    }

    private func testConnection() {
        testResult = "测试中…"
        Task {
            do {
                var urlString = draft.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                while urlString.hasSuffix("/") { urlString.removeLast() }
                guard let url = URL(string: urlString + "/models") else {
                    throw AIError.requestFailed("Base URL 无效")
                }
                var request = URLRequest(url: url)
                request.setValue("Bearer \(draft.openAIKey)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 12
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    testResult = code == 200 ? "连接成功" : "连接失败（HTTP \(code)）"
                }
            } catch {
                await MainActor.run {
                    testResult = "连接失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
