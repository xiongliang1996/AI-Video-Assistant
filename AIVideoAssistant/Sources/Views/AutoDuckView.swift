//
//  AutoDuckView.swift
//  音乐自动闪避：按配音的语音区间，给背景音乐生成音量包络
//

import SwiftUI

struct AutoDuckView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let targetID: UUID

    @State private var voiceSpeech: [ClosedRange<Double>] = []
    @State private var analyzing = true
    @State private var presetIndex = 1
    @State private var attack: Double = AudioDucker.Options.medium.attack
    @State private var release: Double = AudioDucker.Options.medium.release
    @State private var holdGap: Double = AudioDucker.Options.medium.holdGap

    private var target: TimelineItem? {
        appState.timeline.first { $0.id == targetID }
    }

    private var references: [TimelineItem] {
        guard let target else { return [] }
        return appState.duckReferenceClips(for: target)
    }

    private var subtitleClips: [TimelineItem] {
        appState.spokenSubtitleClips
    }

    /// 参考来源记在 AppState 里：连着给几段音乐闪避时不用每次重选
    private var source: AudioDucker.ReferenceSource { appState.duckReferenceSource }

    private var sourceBinding: Binding<AudioDucker.ReferenceSource> {
        Binding(get: { appState.duckReferenceSource },
                set: { appState.duckReferenceSource = $0 })
    }

    /// 当前来源的语音区间。字幕这条路是同步算的，改「保留停顿」会立刻跟着变
    private var speech: [ClosedRange<Double>] {
        switch source {
        case .voiceTrack:
            return voiceSpeech
        case .subtitles:
            return appState.subtitleIntervals(options: options)
        }
    }

    private var options: AudioDucker.Options {
        var opts = AudioDucker.Options.presets[presetIndex].options
        opts.attack = attack
        opts.release = release
        opts.holdGap = holdGap
        return opts.sanitized
    }

    private var envelope: [AudioDucker.Point] {
        guard let target else { return [] }
        return AudioDucker.envelope(speech: speech,
                                    clipStart: target.startTime,
                                    clipEnd: target.endTime,
                                    baseLevel: target.properties.volume,
                                    fadeIn: target.properties.fadeIn,
                                    fadeOut: target.properties.fadeOut,
                                    options: options)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    targetSection
                    divider
                    referenceSection
                    divider
                    parameterSection
                    divider
                    previewSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }

            footer
        }
        .frame(width: 470, height: 720)
        .background(Theme.panel)
        .task(id: targetID) {
            analyzing = true
            voiceSpeech = await appState.speechIntervals(inReference: references)
            analyzing = false
        }
    }

    // MARK: 头

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("自动闪避")
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

    // MARK: 目标

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("要压音量的片段")

            if let target {
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                    Text(target.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    meta("轨道", target.trackLane == 1 ? "A2 配音" : "A1 音乐")
                    meta("时长", String(format: "%.1f s", target.duration))
                    meta("音量", "\(Int(target.properties.volume * 100))%")
                }

                let existing = target.properties.keyframes(for: .volume).count
                if existing > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8.5))
                        Text("这段已经有 \(existing) 个音量关键帧，生成会覆盖掉")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(Theme.warning)
                }
            } else {
                Text("片段已经不在时间线上了")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(.vertical, 14)
    }

    // MARK: 参考

    private var referenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionLabel("参考来源")
                Spacer()
                if !speech.isEmpty {
                    Text("\(speech.count) 段 · \(String(format: "%.1f", speechDuration)) 秒")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.text3)
                }
            }

            SegmentedControl(options: AudioDucker.ReferenceSource.allCases,
                             title: { option in
                                 switch option {
                                 case .voiceTrack:
                                     return "配音语音"
                                 case .subtitles:
                                     return subtitleClips.isEmpty ? "字幕时间" : "字幕时间 \(subtitleClips.count)"
                                 }
                             },
                             selection: sourceBinding)
                .frame(height: 26)

            switch source {
            case .voiceTrack:
                voiceReferenceBody
            case .subtitles:
                subtitleReferenceBody
            }
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var voiceReferenceBody: some View {
        if analyzing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在分析语音…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            .frame(height: 26)
        } else if references.isEmpty {
            Text("另一条音频轨上没有片段。把配音放到 A2（或 A1），音乐放另一条轨，再回来闪避。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(references) { clip in
                HStack(spacing: 6) {
                    Image(systemName: "mic")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.text3)
                    Text(clip.name)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                    Text(clip.trackLane == 1 ? "A2" : "A1")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.text3.opacity(0.12)))
                    Spacer(minLength: 0)
                    Text(formatTimecode(clip.startTime))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.text3)
                }
            }

            if voiceSpeech.isEmpty {
                Text("这些片段里没检测到语音（可能整段是静音，或者本来就是音乐）。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("按波形找出的语音区间。有字幕的项目可以直接切到「字幕时间」，更快也更贴。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var subtitleReferenceBody: some View {
        if subtitleClips.isEmpty {
            Text("时间线上还没有字幕。先用 AI 字幕（⌘L）识别一遍，或者导入 SRT，再回来用字幕时间闪避。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(Array(subtitleClips.prefix(3))) { clip in
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.text3)
                    Text(subtitleText(clip))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(secondsLabel(clip.startTime))–\(secondsLabel(clip.endTime))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.text3)
                }
            }

            if subtitleClips.count > 3 {
                Text("… 还有 \(subtitleClips.count - 3) 条")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
            }

            if speech.isEmpty {
                Text("字幕时间和这段音乐没有重叠，压不到东西。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("直接用字幕的显示区间当语音区间：不解码音频，字幕改了重新打开面板就跟着变。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 字幕条目通常只有一两秒，mm:ss 太糊，用带一位小数的秒
    private func secondsLabel(_ value: Double) -> String {
        String(format: "%.1fs", value)
    }

    private var emptyMessage: String {
        switch source {
        case .voiceTrack:
            return "没有可闪避的语音"
        case .subtitles:
            return subtitleClips.isEmpty ? "时间线上还没有字幕" : "字幕和这段音乐没有重叠"
        }
    }

    private func subtitleText(_ clip: TimelineItem) -> String {
        let text = clip.properties.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? clip.name : text
    }

    private var speechDuration: Double {
        speech.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    // MARK: 参数

    private var parameterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("闪避强度")

            HStack(spacing: 8) {
                SegmentedControl(options: Array(0..<AudioDucker.Options.presets.count),
                                 title: { AudioDucker.Options.presets[$0].title },
                                 selection: Binding(
                                    get: { presetIndex },
                                    set: { presetIndex = $0 }
                                 ))
                Text(String(format: "%.1f dB", options.duckDecibels))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 58, alignment: .trailing)
            }
            .frame(height: 26)

            sliderRow("提前量", value: $attack, range: 0...0.6, format: "%.2f s")
            sliderRow("恢复", value: $release, range: 0...1.2, format: "%.2f s")
            sliderRow("保留停顿", value: $holdGap, range: 0...1.5, format: "%.2f s")

            Text("语音开始前「提前量」秒开始压；说完「恢复」秒内回到原音量。两句之间太短的间隔不恢复——抬起来听不清就又下去，反而像抽搐。")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
    }

    // MARK: 预览

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("音量包络")
                Spacer()
                Text("\(envelope.count) 个关键帧")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.text3)
            }

            envelopeChart
                .frame(height: 88)
        }
        .padding(.top, 14)
    }

    private var envelopeChart: some View {
        let points = envelope
        let base = max(0.001, target?.properties.volume ?? 1)
        let duck = base * options.duckRatio
        let duration = max(0.001, target?.duration ?? 1)

        return Canvas { context, size in
            let inset: CGFloat = 4
            let w = size.width - inset * 2
            let h = size.height - inset * 2
            guard w > 4, h > 4 else { return }

            func x(_ time: Double) -> CGFloat { inset + w * CGFloat(min(1, max(0, time / duration))) }
            func y(_ value: Double) -> CGFloat {
                // 音量 0 在底部，base 在顶部
                inset + h * (1 - CGFloat(min(1, max(0, value / base))))
            }

            // 底板
            let board = Path(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                             cornerRadius: 7)
            context.fill(board, with: .color(Theme.panel2))

            // 参考线：原音量 / 闪避电平
            for (value, dash) in [(base, [CGFloat(3), 3]), (duck, [CGFloat(2), 4])] {
                var line = Path()
                line.move(to: CGPoint(x: inset, y: y(value)))
                line.addLine(to: CGPoint(x: inset + w, y: y(value)))
                context.stroke(line,
                               with: .color(Theme.text3.opacity(value == base ? 0.28 : 0.45)),
                               style: StrokeStyle(lineWidth: 0.8, dash: dash))
            }

            guard points.count >= 2 else {
                var hint = Path()
                hint.move(to: CGPoint(x: inset, y: y(base)))
                hint.addLine(to: CGPoint(x: inset + w, y: y(base)))
                context.stroke(hint, with: .color(Theme.text3.opacity(0.4)), lineWidth: 1)
                return
            }

            // 折线
            var line = Path()
            for (index, point) in points.enumerated() {
                let pt = CGPoint(x: x(point.time), y: y(point.value))
                if index == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }

            // 填充「曲线与原音量之间」的差值区，而不是从底部铺起：
            // 从底部铺的话，抬起来的那段反而像被压了，读起来是反的
            var dip = Path()
            dip.move(to: CGPoint(x: x(points[0].time), y: y(base)))
            for point in points {
                dip.addLine(to: CGPoint(x: x(point.time), y: y(point.value)))
            }
            dip.addLine(to: CGPoint(x: x(points[points.count - 1].time), y: y(base)))
            dip.closeSubpath()

            context.fill(dip, with: .color(Theme.accent.opacity(0.22)))
            context.stroke(line, with: .color(Theme.accent),
                           style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))

            // 折点
            for point in points {
                let pt = CGPoint(x: x(point.time), y: y(point.value))
                let dot = Path(ellipseIn: CGRect(x: pt.x - 1.5, y: pt.y - 1.5, width: 3, height: 3))
                context.fill(dot, with: .color(Theme.accent.opacity(0.85)))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Theme.line, lineWidth: 1)
        )
        .overlay(alignment: .bottomLeading) {
            Text("阴影 = 音乐被压低的地方")
                .font(.system(size: 9))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 6)
                .padding(.bottom, 3)
        }
    }

    // MARK: 底

    private var footer: some View {
        HStack(spacing: 8) {
            if analyzing {
                Text("正在分析…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
            } else if envelope.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.warning)
            }
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(SoftButtonStyle(height: 30))
            Button("生成闪避") {
                guard let target else { dismiss(); return }
                appState.applyDuckEnvelope(envelope, to: target)
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle(height: 30))
            .disabled((source == .voiceTrack && analyzing) || envelope.count < 2)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(Theme.panel2)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: 小组件

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.text2)
    }

    private func meta(_ title: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(Theme.text3)
            Text(value).foregroundStyle(Theme.text2)
        }
        .font(.system(size: 10.5))
    }

    private func sliderRow(_ title: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           format: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2)
                .frame(width: 56, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
                .tint(Theme.accent)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.text3)
                .frame(width: 58, alignment: .trailing)
        }
        .frame(height: 22)
    }
}
