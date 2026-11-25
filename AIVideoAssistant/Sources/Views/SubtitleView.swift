//
//  SubtitleView.swift
//  AI 字幕识别
//

import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct SubtitleView: View {
    @EnvironmentObject var appState: AppState

    @State private var videoURL: URL?
    @State private var language = "zh"
    @State private var mode = 0
    @State private var subtitles: [SubtitleEntry] = []
    @State private var isRecognizing = false
    @State private var errorText: String?
    /// 识别完成后的一句话交代（用了词级时间戳 / 拆了几条）
    @State private var recognizeNote: String?
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

    /// 选了时间线上的某个音频片段当配音（有值时优先于手动选的文件）
    @State private var timelineClipID: UUID?
    /// 当前在列表里选中的字幕条
    @State private var selectedSubtitleID: UUID?
    /// 对齐出来的原始时间，用于「复原」
    @State private var timingBaseline: [SubtitleEntry]?
    /// 拖动开始时的快照，避免连续 onChanged 累积误差
    @State private var dragBase: [SubtitleEntry]?
    /// 最近一次对齐用的语音分析（时间线时间），用于「吸附到语音」
    @State private var lastAnalysis: SpeechAnalysis?

    private let colors: [Color] = [.white, Color(hex: 0xFFD166), Color(hex: 0x7C6BFF), Color(hex: 0x12B76A)]
    private let colorHexes: [Int] = [0xFFFFFF, 0xFFD166, 0x7C6BFF, 0x12B76A]

    /// 初始状态只用于预览 / 截图验证，正常运行时是默认值
    init(initialSource: Int = 0,
         script: String = "",
         mediaURL: URL? = nil,
         subtitles: [SubtitleEntry] = [],
         report: SubtitleAligner.Report? = nil,
         selectedIndex: Int? = nil,
         timelineClip: TimelineItem? = nil,
         analysis: SpeechAnalysis? = nil,
         mode: Int = 0,
         note: String? = nil) {
        _source = State(initialValue: initialSource)
        _scriptText = State(initialValue: script)
        _videoURL = State(initialValue: timelineClip.flatMap { $0.assetURL } ?? mediaURL)
        _subtitles = State(initialValue: subtitles)
        _alignReport = State(initialValue: report)
        _timingBaseline = State(initialValue: subtitles.isEmpty ? nil : subtitles)
        _timelineClipID = State(initialValue: timelineClip?.id)
        _lastAnalysis = State(initialValue: analysis)
        _mode = State(initialValue: mode)
        _recognizeNote = State(initialValue: note)
        if let selectedIndex, subtitles.indices.contains(selectedIndex) {
            _selectedSubtitleID = State(initialValue: subtitles[selectedIndex].id)
        }
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
                                .overlay(Image(systemName: selectedClip == nil ? "film" : "waveform")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(selectedClip?.name ?? videoURL.lastPathComponent)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .lineLimit(1)
                                Text(selectedClip.map {
                                    "时间线 \(SubtitleTiming.compact($0.startTime)) → \(SubtitleTiming.compact($0.endTime))"
                                } ?? "已选择")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.text3)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Button {
                                clearSource()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.text3)
                            }
                            .buttonStyle(.plain)
                            .help("清除选择")
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft))
                    }

                    // 配音已经在时间线上时，不用再选一次文件
                    if source == 1 {
                        timelinePickRow
                    }
                }
                .padding(12)
            }
        }
    }

    /// 时间线上已有的音频片段，点一下直接当配音
    private var timelinePickRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.accent)
                Text("时间线配音")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                Spacer(minLength: 4)
                if !appState.audioClips.isEmpty {
                    Text("\(appState.audioClips.count) 段")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.text3)
                }
            }
            if appState.audioClips.isEmpty {
                Text("时间线上还没有音频片段，先把配音拖到音频轨")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(appState.audioClips) { clip in
                            Chip(text: chipTitle(clip),
                                 icon: "waveform",
                                 selected: timelineClipID == clip.id) {
                                useTimelineClip(clip)
                            }
                            .help("\(clip.name) · 时间线 \(SubtitleTiming.compact(clip.startTime)) 起")
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func chipTitle(_ clip: TimelineItem) -> String {
        let name = clip.name.count > 9 ? String(clip.name.prefix(9)) + "…" : clip.name
        return "\(name) \(SubtitleTiming.compact(clip.startTime))"
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
                Text(mode == 0
                     ? "按标点和长度断句，每条都卡在真实发音上"
                     : "一个词一条，适合做卡拉 OK 式逐字字幕")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
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

            if let recognizeNote {
                Text(recognizeNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                Text("先选一段配音（或从时间线挑一个音频片段），才能按停顿对齐")
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
                        LazyVStack(spacing: 0) {
                            ForEach(Array(subtitles.enumerated()), id: \.element.id) { index, entry in
                                subtitleRow(index: index, entry: entry)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let index = selectedSubtitleIndex {
                    timingBar(index: index)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
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

    // MARK: - 字幕行与微调

    private var selectedSubtitleIndex: Int? {
        guard let id = selectedSubtitleID else { return nil }
        return subtitles.firstIndex { $0.id == id }
    }

    /// 时间线总长度（不算字幕本身，否则最后一条永远没法往后拉）
    private var timelineTotal: Double {
        appState.timeline
            .filter { $0.type != .subtitle && $0.type != .text }
            .map(\.endTime)
            .max() ?? 0
    }

    private func subtitleRow(index: Int, entry: SubtitleEntry) -> some View {
        let isSelected = selectedSubtitleID == entry.id
        return HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? Theme.accent : Theme.text3)
                .frame(width: 18, alignment: .leading)
                .padding(.top, 2)

            // 时间码本身就是拖动把手：点一下选中，左右拖动整体平移
            Text(SubtitleTiming.label(entry))
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Theme.accent : Theme.text2)
                .frame(width: 104, alignment: .leading)
                .padding(.top, 1)
                .contentShape(Rectangle())
                .gesture(timeDrag(entry))
                .help("左右拖动整体平移；点一下选中，可在下方按 0.1 秒微调")

            TextField("字幕内容", text: Binding(
                get: { subtitles.indices.contains(index) ? subtitles[index].text : "" },
                set: { if subtitles.indices.contains(index) { subtitles[index].text = $0 } }
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
        .background(isSelected ? Theme.accentSoft.opacity(0.55) : Color.clear)
    }

    private func timeDrag(_ entry: SubtitleEntry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragBase == nil {
                    dragBase = subtitles
                    selectedSubtitleID = entry.id
                }
                guard let base = dragBase,
                      let index = base.firstIndex(where: { $0.id == entry.id }) else { return }
                // 拖多少点 → 多少秒，按 0.05 秒取整，避免出现 1.7300000000000002
                let delta = SubtitleTiming.delta(pixels: value.translation.width, step: 0.05)
                let moved = SubtitleTiming.shift(base, at: index, by: delta, total: timelineTotal)
                if moved != subtitles { subtitles = moved }
            }
            .onEnded { _ in dragBase = nil }
    }

    private func timingBar(index: Int) -> some View {
        let entry = subtitles[index]
        return VStack(spacing: 7) {
            HStack(spacing: 6) {
                Text("第 \(index + 1) 条")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.text2)
                Text(SubtitleTiming.label(entry))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                Text(String(format: "%.2f 秒", SubtitleTiming.duration(entry)))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.text3)
                Spacer(minLength: 4)
                if let baseline = timingBaseline,
                   SubtitleTiming.isModified(subtitles, from: baseline) {
                    Button {
                        subtitles = SubtitleTiming.restoreTimes(subtitles, from: baseline)
                    } label: {
                        Text("复原对齐")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("时间恢复成刚对齐完的样子，文本保留")
                }
                Button {
                    selectedSubtitleID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
                .buttonStyle(.plain)
                .help("收起微调")
            }

            HStack(spacing: 6) {
                timingButton("◀ 前移", "整体前移 0.1 秒") {
                    subtitles = SubtitleTiming.shift(subtitles, at: index,
                                                     by: -SubtitleTiming.step, total: timelineTotal)
                }
                timingButton("后移 ▶", "整体后移 0.1 秒") {
                    subtitles = SubtitleTiming.shift(subtitles, at: index,
                                                     by: SubtitleTiming.step, total: timelineTotal)
                }
                Rectangle()
                    .fill(Theme.line)
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 1)
                timingButton("缩短", "结尾提前 0.1 秒") {
                    subtitles = SubtitleTiming.resizeEnd(subtitles, at: index,
                                                         by: -SubtitleTiming.step, total: timelineTotal)
                }
                timingButton("加长", "结尾延后 0.1 秒") {
                    subtitles = SubtitleTiming.resizeEnd(subtitles, at: index,
                                                         by: SubtitleTiming.step, total: timelineTotal)
                }
                timingButton("吸附到语音", "把这一条的起止贴到最近的语音起止上",
                             enabled: canSnap) {
                    snapSelected(index)
                }
                Spacer(minLength: 0)
                Text(SubtitleTiming.roomLabel(subtitles, at: index, total: timelineTotal))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }

            // 整体偏了半秒这种系统性偏差，一条条按太麻烦
            HStack(spacing: 6) {
                Text("全部 \(subtitles.count) 条")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.text3)
                timingButton("◀ 0.1s", "全部前移 0.1 秒") {
                    subtitles = SubtitleTiming.shiftAll(subtitles, by: -SubtitleTiming.step,
                                                        total: timelineTotal)
                }
                timingButton("0.1s ▶", "全部后移 0.1 秒") {
                    subtitles = SubtitleTiming.shiftAll(subtitles, by: SubtitleTiming.step,
                                                        total: timelineTotal)
                }
                timingButton("全部吸附", "把每一条的起止都贴到最近的语音边界上",
                             enabled: canSnap) {
                    snapAll()
                }
                Spacer(minLength: 0)
                if lastAnalysis == nil {
                    Text("吸附需要先做一次文稿对齐")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.text3)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panel.opacity(0.55))
    }

    /// 自定义 ButtonStyle 不会自己变灰，禁用状态得手动压暗
    private func timingButton(_ title: String,
                              _ help: String,
                              enabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5))
        }
        .buttonStyle(SoftButtonStyle(height: 24))
        .opacity(enabled ? 1 : 0.38)
        .disabled(!enabled)
        .help(help)
    }

    /// 有语音分析才能吸附
    private var canSnap: Bool {
        !(lastAnalysis?.speech.isEmpty ?? true)
    }

    private func snapSelected(_ index: Int) {
        guard let analysis = lastAnalysis, !analysis.speech.isEmpty else {
            appState.notify("先做一次文稿对齐，才有语音边界可吸附")
            return
        }
        subtitles = SubtitleTiming.snapToSpeech(subtitles, at: index,
                                                speech: analysis.speech, total: timelineTotal)
    }

    private func snapAll() {
        guard let analysis = lastAnalysis, !analysis.speech.isEmpty else {
            appState.notify("先做一次文稿对齐，才有语音边界可吸附")
            return
        }
        let snapped = SubtitleTiming.snapAllToSpeech(subtitles, speech: analysis.speech,
                                                     total: timelineTotal)
        let moved = zip(snapped, subtitles).filter {
            abs($0.startTime - $1.startTime) > 0.001 || abs($0.endTime - $1.endTime) > 0.001
        }.count
        subtitles = snapped
        appState.notify(moved == 0 ? "都已经贴着语音边界了" : "已吸附 \(moved) 条到语音边界")
    }

    // MARK: - 动作

    private var selectedClip: TimelineItem? {
        guard let id = timelineClipID else { return nil }
        return appState.timeline.first { $0.id == id }
    }

    private func clearSource() {
        videoURL = nil
        timelineClipID = nil
        alignReport = nil
        alignNote = nil
        lastAnalysis = nil
    }

    /// 选时间线上的片段当配音：文件还是那个文件，只是字幕要对齐到它在时间线上的位置
    private func useTimelineClip(_ clip: TimelineItem) {
        guard let url = clipURL(clip) else {
            alignNote = "这个片段的文件找不到了：\(clip.name)"
            return
        }
        timelineClipID = clip.id
        videoURL = url
        alignReport = nil
        alignNote = nil
        lastAnalysis = nil
    }

    private func clipURL(_ clip: TimelineItem) -> URL? {
        if let url = clip.assetURL, FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let id = clip.assetID,
           let asset = appState.mediaLibrary.first(where: { $0.id == id }) {
            return asset.url
        }
        return clip.assetURL
    }

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = source == 0
            ? [.movie, .mpeg4Movie, .quickTimeMovie]
            : [.movie, .mpeg4Movie, .quickTimeMovie, .audio]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            videoURL = panel.url
            // 手动选了文件就不再跟时间线上的片段走
            timelineClipID = nil
            alignReport = nil
            alignNote = nil
            lastAnalysis = nil
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

        // 时间线片段：分析完要把文件时间映射成时间线时间
        let clip = selectedClip
        let clipRange = clip.map { (start: $0.startTime, source: $0.sourceStart, duration: $0.duration) }

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
            let raw = await Task.detached(priority: .userInitiated) {
                SilenceDetector.analyze(url: target) ?? SpeechAnalysis()
            }.value

            if let temporary { try? FileManager.default.removeItem(at: temporary) }

            let analysis = clipRange.map {
                SubtitleAligner.remap(raw,
                                      clipStart: $0.start,
                                      sourceStart: $0.source,
                                      duration: $0.duration)
            } ?? raw

            let entries = SubtitleAligner.align(lines: lines, analysis: analysis)
            let report = SubtitleAligner.report(lines: lines, entries: entries, analysis: analysis)

            await MainActor.run {
                subtitles = entries
                timingBaseline = entries
                selectedSubtitleID = nil
                lastAnalysis = analysis
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
        recognizeNote = nil

        // 时间线片段：识别完要把文件时间映射成时间线时间
        let clip = selectedClip
        let clipRange = clip.map { (start: $0.startTime, source: $0.sourceStart, duration: $0.duration) }
        let granularity: WhisperAlignment.Granularity = mode == 0 ? .sentence : .word

        Task {
            do {
                let audioURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("whisper-\(UUID().uuidString).m4a")
                try await VideoEditor.shared.extractAudio(from: videoURL, to: audioURL)

                let audioDuration = (try? await AVURLAsset(url: audioURL).load(.duration))
                    .map(CMTimeGetSeconds) ?? 0

                let service = OpenAIService(config: appState.aiConfig)
                // 词级时间戳总是要：整句模式下也靠它算准每条的真实起止
                let transcript = try await service.transcribe(audioURL: audioURL,
                                                              language: language.isEmpty ? nil : language,
                                                              wordTimestamps: true)
                try? FileManager.default.removeItem(at: audioURL)

                var entries: [SubtitleEntry]
                if transcript.words.isEmpty {
                    // 服务端没给词级时间戳：退回句级 + 重新断句
                    entries = WhisperAlignment.refine(transcript.segments)
                } else {
                    entries = WhisperAlignment.cues(from: transcript.words, granularity: granularity)
                }
                if entries.isEmpty { entries = transcript.segments }

                if let clipRange {
                    entries = WhisperAlignment.remap(entries,
                                                     clipStart: clipRange.start,
                                                     sourceStart: clipRange.source,
                                                     duration: clipRange.duration)
                }

                let limit = clipRange.map { $0.start + $0.duration } ?? audioDuration
                if limit > 0 {
                    entries = SubtitleTiming.sanitized(entries, total: limit)
                }

                let note = recognizeSummary(entries: entries,
                                            transcript: transcript,
                                            granularity: granularity)

                await MainActor.run {
                    subtitles = entries
                    timingBaseline = entries
                    selectedSubtitleID = nil
                    lastAnalysis = nil
                    isRecognizing = false
                    recognizeNote = note
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

    /// 识别结果的一句话交代：用了什么时间戳、拆了多少条
    private func recognizeSummary(entries: [SubtitleEntry],
                                  transcript: WhisperTranscript,
                                  granularity: WhisperAlignment.Granularity) -> String {
        var parts: [String] = ["\(entries.count) 条字幕"]
        if transcript.words.isEmpty {
            parts.append("服务端没给词级时间戳，按句级重新断句")
        } else {
            parts.append("词级时间戳 \(transcript.words.count) 个")
            parts.append(granularity == .word ? "逐字" : "整句")
        }
        if let clip = selectedClip {
            parts.append("已按片段 \(SubtitleTiming.compact(clip.startTime)) 换算")
        }
        return parts.joined(separator: " · ")
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
