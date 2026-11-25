//
//  SubtitleView.swift
//  AI 字幕识别
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SubtitleView: View {
    @EnvironmentObject var appState: AppState

    @State private var videoURL: URL?
    @State private var language = "zh"
    @State private var mode = 0
    @State private var subtitles: [SubtitleEntry] = []
    @State private var isRecognizing = false
    @State private var errorText: String?
    @State private var fontSize: Double = 28
    @State private var textColor = 0

    /// 0 = Whisper 识别，1 = 文稿对齐
    @State private var source = 0
    /// 文稿对齐：粘贴的稿子
    @State private var scriptText = ""
    /// 每行最多多少字（视觉长度）
    @State private var maxChars: Double = 18
    @State private var isAligning = false
    @State private var alignReport: SubtitleAligner.Report?
    @State private var alignNote: String?

    private let colors: [Color] = [.white, Color(hex: 0xFFD166), Color(hex: 0x7C6BFF), Color(hex: 0x12B76A)]
    private let colorHexes: [Int] = [0xFFFFFF, 0xFFD166, 0x7C6BFF, 0x12B76A]

    /// 初始状态只用于预览 / 截图验证，正常运行时是默认值
    init(initialSource: Int = 0,
         script: String = "",
         mediaURL: URL? = nil,
         subtitles: [SubtitleEntry] = [],
         report: SubtitleAligner.Report? = nil) {
        _source = State(initialValue: initialSource)
        _scriptText = State(initialValue: script)
        _videoURL = State(initialValue: mediaURL)
        _subtitles = State(initialValue: subtitles)
        _alignReport = State(initialValue: report)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(alignment: .top, spacing: 16) {
                leftColumn
                listCard
            }
            .padding(16)
        }
        .background(Theme.bg)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xF59E0B), Color(hex: 0xFBBF24)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 22, height: 22)
                    .overlay(Image(systemName: "captions.bubble")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white))
                Text("AI 字幕")
                    .font(.system(size: 14, weight: .semibold))
                Text(source == 0 ? "Whisper 自动识别 · 可逐条校对" : "文稿自动断句 · 按停顿对齐时间轴")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
            Button {
                exportSRT()
            } label: {
                Label("导出 SRT", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12.5))
            }
            .buttonStyle(SoftButtonStyle())
            .disabled(subtitles.isEmpty)

            Button {
                appState.addSubtitles(subtitles, fontSize: Int(fontSize), colorHex: colorHexes[textColor])
            } label: {
                Label("全部加入时间线", systemImage: "plus")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(subtitles.isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Theme.panel.opacity(0.72))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var leftColumn: some View {
        ScrollView {
            VStack(spacing: 12) {
                sourceCard
                settingsCard
                styleCard
            }
        }
        .scrollIndicators(.never)
        .frame(width: 330)
    }

    private var sourceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Text(source == 0 ? "源视频" : "配音音频 / 视频")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

                VStack(spacing: 8) {
                    Button {
                        pickVideo()
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.accent)
                            Text(source == 0 ? "点击选择视频" : "点击选择配音")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.text)
                            Text(source == 0 ? "或拖拽文件到此处 · MP4 / MOV" : "MP4 / MOV / M4A / WAV / MP3")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.text3)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Theme.accentSoft.opacity(0.6))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(Theme.accent.opacity(0.35),
                                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                        )
                    }
                    .buttonStyle(.plain)

                    if let videoURL {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.thumb(videoURL.lastPathComponent.hashValue))
                                .frame(width: 28, height: 28)
                                .overlay(Image(systemName: "film")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(videoURL.lastPathComponent)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .lineLimit(1)
                                Text("已选择")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.text3)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ok)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft))
                    }
                }
                .padding(12)
            }
        }
    }

    private var settingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Text("生成方式")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

                VStack(alignment: .leading, spacing: 10) {
                    SegmentedControl(options: [0, 1],
                                     title: { $0 == 0 ? "AI 识别" : "文稿对齐" },
                                     selection: $source)

                    if source == 0 {
                        recognizeSettings
                    } else {
                        alignSettings
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: - 识别设置

    private var recognizeSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("语言")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                SegmentedControl(options: ["zh", "en", ""],
                                 title: { $0 == "zh" ? "中文" : ($0 == "en" ? "English" : "自动") },
                                 selection: $language)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("分段方式")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                SegmentedControl(options: [0, 1],
                                 title: { $0 == 0 ? "整句" : "逐字" },
                                 selection: $mode)
            }

            Button {
                recognize()
            } label: {
                HStack(spacing: 6) {
                    if isRecognizing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "captions.bubble")
                    }
                    Text(isRecognizing ? "识别中…" : "开始识别")
                }
            }
            .buttonStyle(PrimaryButtonStyle(height: 34, fullWidth: true))
            .disabled(videoURL == nil || isRecognizing)

            if let errorText {
                Text(errorText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 文稿对齐设置

    private var alignSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("文稿")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                    Spacer()
                    Text("\(scriptText.count) 字")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.text3)
                    Button("导入 txt") { importScript() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                }
                TextEditor(text: $scriptText)
                    .font(.system(size: 11.5))
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .frame(height: 116)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7).stroke(Theme.line2, lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if scriptText.isEmpty {
                            Text("把口播稿粘进来，会按标点自动断句")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.text3)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }
            }

            SliderRow(label: "每行最多",
                      value: $maxChars,
                      range: 10...30,
                      display: "\(Int(maxChars)) 字")

            if !scriptText.isEmpty {
                let preview = SubtitleBreaker.breakText(scriptText, options: breakerOptions)
                HStack(spacing: 4) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 9))
                    Text(preview.isEmpty
                         ? "没有可断的内容"
                         : "会断成 \(preview.count) 条 · 首条「\(preview[0])」")
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.text3)
            }

            Button {
                alignScript()
            } label: {
                HStack(spacing: 6) {
                    if isAligning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text(isAligning ? "对齐中…" : "断句并对齐")
                }
            }
            .buttonStyle(PrimaryButtonStyle(height: 34, fullWidth: true))
            .disabled(scriptText.isEmpty || videoURL == nil || isAligning)

            if videoURL == nil {
                Text("先选一段配音（或带音轨的视频），才能按停顿对齐")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let alignNote {
                Text(alignNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let alignReport {
                reportView(alignReport)
            }
        }
    }

    private func reportView(_ report: SubtitleAligner.Report) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: report.warnings.isEmpty
                      ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(report.warnings.isEmpty ? Theme.ok : Color(hex: 0xF59E0B))
                Text(report.oneToOne ? "一句一停，已精确对齐" : "已生成 \(report.count) 条")
                    .font(.system(size: 10.5, weight: .medium))
                Spacer()
                if report.averageDuration > 0 {
                    Text("均 \(String(format: "%.1f", report.averageDuration)) 秒/条")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.text3)
                }
            }
            ForEach(report.warnings, id: \.self) { warning in
                Text("· \(warning)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
    }

    private var breakerOptions: SubtitleBreaker.Options {
        SubtitleBreaker.Options(maxLength: maxChars, minLength: max(3, maxChars * 0.3))
    }

    private var styleCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Text("字幕样式")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

                VStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Theme.stageGradient)
                        Text("用 AI 讲一个好故事")
                            .font(.system(size: fontSize * 0.46, weight: .semibold))
                            .foregroundStyle(colors[textColor])
                            .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                    }
                    .frame(height: 62)

                    SliderRow(label: "字号",
                              value: $fontSize,
                              range: 14...48,
                              display: "\(Int(fontSize))px")

                    HStack {
                        Text("颜色")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text2)
                        Spacer()
                        HStack(spacing: 6) {
                            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                                Button {
                                    textColor = index
                                } label: {
                                    Circle()
                                        .fill(color)
                                        .frame(width: 20, height: 20)
                                        .overlay(Circle().stroke(Color.black.opacity(0.1), lineWidth: 1))
                                        .overlay(
                                            Circle()
                                                .stroke(Theme.accent, lineWidth: textColor == index ? 2 : 0)
                                                .padding(-2.5)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: 24)
                }
                .padding(12)
            }
        }
    }

    private var listCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("字幕列表")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(subtitles.isEmpty ? "" : "\(subtitles.count) 条")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

                if subtitles.isEmpty {
                    EmptyHint(icon: "captions.bubble",
                              title: "还没有字幕",
                              subtitle: source == 0
                                  ? "选择视频后点击「开始识别」"
                                  : "选配音、粘文稿，然后点「断句并对齐」")
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(subtitles.enumerated()), id: \.element.id) { index, entry in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.text3)
                                        .frame(width: 18, alignment: .leading)
                                        .padding(.top, 2)
                                    Text(entry.timecode)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 92, alignment: .leading)
                                        .padding(.top, 1)
                                    TextField("字幕内容", text: Binding(
                                        get: { subtitles[index].text },
                                        set: { subtitles[index].text = $0 }
                                    ))
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    Button {
                                        appState.currentTime = entry.startTime
                                    } label: {
                                        Image(systemName: "play.circle")
                                            .font(.system(size: 12))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.text3)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                HStack {
                    Text(subtitles.isEmpty
                         ? (source == 0 ? "等待识别" : "等待对齐")
                         : "共 \(subtitles.count) 条字幕")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                    Spacer()
                    Button {
                        appState.addSubtitles(subtitles, fontSize: Int(fontSize), colorHex: colorHexes[textColor])
                    } label: {
                        Label("加入时间线", systemImage: "plus")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(SoftButtonStyle(height: 26))
                    .disabled(subtitles.isEmpty)
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
        }
    }

    // MARK: - 动作

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = source == 0
            ? [.movie, .mpeg4Movie, .quickTimeMovie]
            : [.movie, .mpeg4Movie, .quickTimeMovie, .audio]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            videoURL = panel.url
            alignReport = nil
            alignNote = nil
        }
    }

    private func importScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        scriptText = text
    }

    /// 扩展名判断音频：音频直接分析，视频要先抽音轨
    private func isAudioFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .audio)
    }

    private func alignScript() {
        guard let videoURL else { return }
        let lines = SubtitleBreaker.breakText(scriptText, options: breakerOptions)
        guard !lines.isEmpty else {
            alignNote = "文稿里没有可用的内容"
            return
        }
        isAligning = true
        alignNote = nil
        alignReport = nil
        errorText = nil

        Task {
            // 视频要先抽出音轨才能分析停顿
            var target = videoURL
            var temporary: URL?
            if !isAudioFile(videoURL) {
                let output = FileManager.default.temporaryDirectory
                    .appendingPathComponent("align-\(UUID().uuidString).m4a")
                do {
                    try await VideoEditor.shared.extractAudio(from: videoURL, to: output)
                    target = output
                    temporary = output
                } catch {
                    await MainActor.run {
                        isAligning = false
                        alignNote = "抽不出音轨：\(error.localizedDescription)"
                    }
                    return
                }
            }

            // 分析整段音频要几百毫秒到几秒，放后台
            let analysis = await Task.detached(priority: .userInitiated) {
                SilenceDetector.analyze(url: target) ?? SpeechAnalysis()
            }.value

            if let temporary { try? FileManager.default.removeItem(at: temporary) }

            let entries = SubtitleAligner.align(lines: lines, analysis: analysis)
            let report = SubtitleAligner.report(lines: lines, entries: entries, analysis: analysis)

            await MainActor.run {
                subtitles = entries
                alignReport = report
                isAligning = false
                appState.notify("已对齐 \(entries.count) 条字幕")
            }
        }
    }

    private func recognize() {
        guard let videoURL else { return }
        isRecognizing = true
        errorText = nil

        Task {
            do {
                let audioURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("whisper-\(UUID().uuidString).m4a")
                try await VideoEditor.shared.extractAudio(from: videoURL, to: audioURL)

                let service = OpenAIService(config: appState.aiConfig)
                let srt = try await service.transcribe(audioURL: audioURL,
                                                       language: language.isEmpty ? nil : language)
                let entries = SubtitleParser.parseSRT(srt)
                try? FileManager.default.removeItem(at: audioURL)

                await MainActor.run {
                    subtitles = entries
                    isRecognizing = false
                    appState.notify("识别完成，共 \(entries.count) 条字幕")
                }
            } catch {
                await MainActor.run {
                    isRecognizing = false
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func exportSRT() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "subtitles.srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = SubtitleParser.toSRT(subtitles)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        appState.notify("已导出 \(url.lastPathComponent)")
    }
}
