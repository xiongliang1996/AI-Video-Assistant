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
                .frame(minWidth: 1180, minHeight: 800)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建项目") { appState.createProject() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("打开项目…") { appState.openProject() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("导入素材…") { appState.importMedia() }
                    .keyboardShortcut("i", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存项目") {
                    appState.saveNow()
                    appState.notify("已保存到本地")
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("导出项目副本…") { appState.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("在访达中显示项目文件") { appState.revealProjectFile() }

                Button("导出视频…") { appState.exportVideo() }
                    .keyboardShortcut("e", modifiers: .command)

                Button("导出队列…") { appState.showingExportQueue = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { appState.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!appState.canUndo)
                Button("重做") { appState.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!appState.canRedo)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("全选片段") { appState.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                Button("取消选择") { appState.clearSelection() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("删除所选片段") { appState.removeSelectedItem() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(appState.selectedItemIDs.isEmpty)
                Button("复制一份") { appState.duplicateSelection() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(appState.selectedItemIDs.isEmpty)

                Divider()

                Button("吸附所有转场片段") { appState.snapAllTransitions() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandMenu("显示") {
                Button("放大时间线") { appState.zoomTimeline(by: 1.25) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("缩小时间线") { appState.zoomTimeline(by: 0.8) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("时间线实际大小") { appState.resetTimelineZoom() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            CommandMenu("AI") {
                Button("AI 生视频") { appState.selectedPanel = .generate }
                    .keyboardShortcut("g", modifiers: .command)
                Button("AI 配音") { appState.selectedPanel = .tts }
                    .keyboardShortcut("t", modifiers: .command)
                Button("AI 字幕") { appState.selectedPanel = .subtitle }
                    .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("智能剪辑（按停顿）…") { appState.showingSmartCut = true }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("设置…") { appState.showingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
