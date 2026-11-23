//
//  AIVideoAssistantApp.swift
//  AI Video Assistant — macOS 原生 AI 视频创作工具
//

import SwiftUI

@main
struct AIVideoAssistantApp: App {
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建项目") { appState.createProject() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("导入素材…") { appState.importMedia() }
                    .keyboardShortcut("i", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("导出视频…") { appState.exportVideo() }
                    .keyboardShortcut("e", modifiers: .command)
            }
            CommandMenu("AI") {
                Button("AI 生视频") { appState.selectedPanel = .generate }
                    .keyboardShortcut("g", modifiers: .command)
                Button("AI 配音") { appState.selectedPanel = .tts }
                    .keyboardShortcut("t", modifiers: .command)
                Button("AI 字幕") { appState.selectedPanel = .subtitle }
                    .keyboardShortcut("s", modifiers: .command)
                Divider()
                Button("设置…") { appState.showingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
