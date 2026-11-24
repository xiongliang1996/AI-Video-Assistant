//
//  SmartCutView.swift
//  智能剪辑：分析语音停顿，按停顿切片或直接剪掉停顿
//

import SwiftUI

struct SmartCutView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var clipID: UUID?

    private var clip: TimelineItem? {
        if let id = clipID, let item = appState.timeline.first(where: { $0.id == id }) { return item }
        return appState.defaultSpeechClip
    }

    private var audioClips: [TimelineItem] {
        appState.timeline.filter { $0.type == .audio }.sorted { $0.startTime < $1.startTime }
    }

    private var pauses: [ClosedRange<Double>] {
        guard let clip else { return [] }
        return appState.pauses(in: clip)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    clipSection
                    divider
                    parameterSection
                    divider
                    resultSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }

            footer
        }
        .frame(width: 430, height: 540)
        .background(Theme.panel)
        .onAppear {
            if clipID == nil { clipID = appState.defaultSpeechClip?.id }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("智能剪辑")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 22))
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Theme.panel2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: 目标片段

    private var clipSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("要分析的片段")

            if audioClips.isEmpty {
                Text("时间线上还没有音频片段，先导入配音或音乐")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .padding(.vertical, 6)
            } else {
                Picker("", selection: Binding(
                    get: { clip?.id ?? audioClips[0].id },
                    set: { clipID = $0 }
                )) {
                    ForEach(audioClips) { item in
                        Text("\(item.name) · \(formatTimecode(item.startTime))")
                            .tag(item.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                if let clip {
                    HStack(spacing: 10) {
                        meta("轨道", clip.trackLane == 1 ? "A2 配音" : "A1 音乐")
                        meta("时长", String(format: "%.1f s", clip.duration))
                        meta("起点", formatTimecode(clip.startTime))
                    }
                }
            }
        }
        .padding(.vertical, 14)
    }

    // MARK: 参数

    private var parameterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("检测参数")

            sliderRow("静音阈值",
                      value: Binding(
                        get: { Double(appState.silenceThresholdDB) },
                        set: { appState.silenceThresholdDB = Float($0) }
                      ),
                      range: -60...(-16),
                      unit: "dB",
                      format: "%.0f")

            sliderRow("最短停顿",
                      value: $appState.minPauseDuration,
                      range: 0.15...1.5,
                      unit: "s",
                      format: "%.2f")

            sliderRow("最短语句",
                      value: $appState.minSpeechDuration,
                      range: 0.1...1.0,
                      unit: "s",
                      format: "%.2f")

            Text("低于阈值的段落算静音；短于「最短停顿」的静音会被忽略，短于「最短语句」的语音会被当成停顿。")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await appState.analyzeSpeech(for: clip) }
            } label: {
                HStack(spacing: 6) {
                    if appState.isAnalyzingSpeech {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 11))
                    }
                    Text(appState.isAnalyzingSpeech ? "分析中…" : "开始分析")
                }
            }
            .buttonStyle(SoftButtonStyle(height: 30, fullWidth: true, active: true))
            .disabled(clip == nil || appState.isAnalyzingSpeech)
        }
        .padding(.vertical, 14)
    }

    // MARK: 结果

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("分析结果")

            if let analysis = appState.speechAnalysis, !pauses.isEmpty {
                HStack(spacing: 8) {
                    stat("语音", "\(analysis.speech.count) 段")
                    stat("停顿", "\(pauses.count) 处")
                    stat("可剪掉", String(format: "%.1f s", pauses.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }))
                }

                VStack(spacing: 0) {
                    ForEach(Array(pauses.enumerated()), id: \.offset) { _, range in
                        Button {
                            appState.seek(to: range.lowerBound)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "speaker.slash")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Theme.text3)
                                Text("\(fineTime(range.lowerBound)) – \(fineTime(range.upperBound))")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.text2)
                                Spacer()
                                Text(String(format: "%.2f s", range.upperBound - range.lowerBound))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.text3)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
                .frame(maxHeight: 170)
                .clipped()

                Text("「删除停顿并前移」会把所有轨道一起前移，画面与字幕保持同步。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let analysis = appState.speechAnalysis {
                Text("片段内没有检测到停顿（语音 \(analysis.speech.count) 段）。可以调高静音阈值再试。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("点「开始分析」后这里会列出每一处停顿，点一条可以跳到对应位置。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 14)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Button("关闭") { dismiss() }
                .buttonStyle(SoftButtonStyle(height: 30))

            Spacer()

            Button {
                appState.splitAtPauses()
                dismiss()
            } label: {
                Label("按停顿切片", systemImage: "scissors")
                    .font(.system(size: 12))
            }
            .buttonStyle(SoftButtonStyle(height: 30))
            .disabled(pauses.isEmpty)

            Button {
                appState.rippleDeletePauses()
                dismiss()
            } label: {
                Label("删除停顿并前移", systemImage: "arrow.left.to.line")
                    .font(.system(size: 12))
            }
            .buttonStyle(SoftButtonStyle(height: 30, active: true))
            .disabled(pauses.isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(Theme.panel2)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: 小部件

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.text2)
    }

    /// 停顿通常不到一秒，时间码要精确到 0.01 s
    private func fineTime(_ time: Double) -> String {
        let total = max(0, time)
        let minutes = Int(total) / 60
        let seconds = total - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, seconds)
    }

    private func meta(_ title: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(Theme.text3)
            Text(value).foregroundStyle(Theme.text2)
        }
        .font(.system(size: 10.5))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
    }

    private func sliderRow(_ title: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           unit: String,
                           format: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2)
                .frame(width: 56, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
                .tint(Theme.accent)
            Text(String(format: format, value.wrappedValue) + " " + unit)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.text3)
                .frame(width: 52, alignment: .trailing)
        }
    }
}
