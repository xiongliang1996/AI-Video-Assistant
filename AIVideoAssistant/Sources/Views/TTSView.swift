//
//  TTSView.swift
//  AI 配音
//

import SwiftUI
import AVFoundation
import AppKit

final class AudioPlayerController: ObservableObject {
    private var player: AVAudioPlayer?
    @Published var isPlaying = false
    @Published var currentURL: URL?

    func toggle(url: URL) {
        if currentURL != url {
            stop()
            player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            currentURL = url
        }
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentURL = nil
    }
}

struct TTSHistoryItem: Identifiable {
    let id = UUID()
    let url: URL
    let voice: String
    let text: String
    let duration: Double
    let createdAt: Date
}

struct TTSView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var audio = AudioPlayerController()

    @State private var text = "每一段好故事，都从一个念头开始。现在，你只需要写下它。"
    @State private var provider: TTSProvider = .openAI
    @State private var voiceID = "nova"
    @State private var speed: Double = 1.0
    @State private var pitch: Double = 0
    @State private var history: [TTSHistoryItem] = []
    @State private var isGenerating = false
    @State private var errorText: String?

    private var voices: [TTSVoice] { TTSManager.shared.voices(for: provider) }

    private var estimatedSeconds: Int {
        max(1, Int(Double(text.count) / 4.2))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(alignment: .top, spacing: 16) {
                editorCard
                VStack(spacing: 12) {
                    playerCard
                    historyCard
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .onChange(of: provider) { _ in
            voiceID = voices.first?.id ?? ""
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x0EA5E9), Color(hex: 0x22D3EE)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 22, height: 22)
                    .overlay(Image(systemName: "speaker.wave.2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white))
                Text("AI 配音")
                    .font(.system(size: 14, weight: .semibold))
                Text("文字转语音 · 多音色可选")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
            StatusPill(text: "已生成 \(history.count) 段")
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Theme.panel.opacity(0.72))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var editorCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("配音文本")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text("\(text.count) 字 · 约 \(estimatedSeconds) 秒")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        TextEditor(text: $text)
                            .font(.system(size: 12.5))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(height: 110)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Theme.panel)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line2, lineWidth: 1))
                            )

                        VStack(alignment: .leading, spacing: 6) {
                            label("gearshape", "语音引擎")
                            SegmentedControl(options: TTSProvider.allCases,
                                             title: { $0.rawValue },
                                             selection: $provider)
                            Text(provider.summary)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.text3)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            label("mic", "音色")
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                                GridItem(.flexible(), spacing: 8),
                                                GridItem(.flexible(), spacing: 8)],
                                      spacing: 8) {
                                ForEach(voices) { voice in
                                    VoiceCard(voice: voice,
                                              selected: voice.id == voiceID) {
                                        voiceID = voice.id
                                    }
                                }
                            }
                        }

                        VStack(spacing: 6) {
                            SliderRow(label: "语速",
                                      value: $speed,
                                      range: 0.5...2.0,
                                      display: String(format: "%.1f×", speed))
                            SliderRow(label: "音调",
                                      value: $pitch,
                                      range: -12...12,
                                      display: "\(Int(pitch))")
                        }

                        Button {
                            synthesize()
                        } label: {
                            HStack(spacing: 6) {
                                if isGenerating {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "speaker.wave.2.fill")
                                }
                                Text(isGenerating ? "合成中…" : "生成配音")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle(height: 36, fullWidth: true))
                        .disabled(text.isEmpty || isGenerating)

                        if let errorText {
                            Text(errorText)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.danger)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 404)
    }

    private var playerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("试听")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text(currentVoiceName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            if let url = history.first?.url {
                                audio.toggle(url: url)
                            } else {
                                appState.notify("先生成一段配音再试听")
                            }
                        } label: {
                            ZStack {
                                Circle().fill(Theme.panel)
                                Circle().stroke(Theme.line, lineWidth: 1)
                                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Theme.text)
                            }
                            .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)

                        WaveformView(active: audio.isPlaying)

                        Text(formatTimecode(history.first?.duration ?? 0))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Theme.text2)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(LinearGradient(colors: [Color(hex: 0xF6F4FF), Color(hex: 0xFDF5FF)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(Theme.accent.opacity(0.16), lineWidth: 1))
                    )

                    HStack(spacing: 8) {
                        Button {
                            addToTimeline()
                        } label: {
                            Label("加入时间线", systemImage: "plus")
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SoftButtonStyle(fullWidth: true))

                        Button {
                            appState.notify("换个音色：请在左侧选择其他音色")
                        } label: {
                            Label("换个音色", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SoftButtonStyle(fullWidth: true))
                    }
                }
                .padding(14)
            }
        }
    }

    private var historyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("配音片段")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text("可拖拽到时间线")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

                if history.isEmpty {
                    EmptyHint(icon: "waveform",
                              title: "还没有配音片段",
                              subtitle: "生成后会出现在这里")
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(history) { item in
                                HStack(spacing: 10) {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Theme.thumb(item.voice.hashValue))
                                        .frame(width: 28, height: 28)
                                        .overlay(Image(systemName: "speaker.wave.2.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.white))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.text)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .lineLimit(1)
                                        Text(item.voice)
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.text3)
                                    }
                                    Spacer()
                                    Button {
                                        audio.toggle(url: item.url)
                                    } label: {
                                        Image(systemName: audio.currentURL == item.url && audio.isPlaying
                                              ? "pause.fill" : "play.fill")
                                            .font(.system(size: 10))
                                    }
                                    .buttonStyle(IconButtonStyle(size: 24))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                        }
                        .padding(6)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var currentVoiceName: String {
        voices.first { $0.id == voiceID }?.name ?? voiceID
    }

    private func label(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.text3)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text2)
        }
    }

    private func synthesize() {
        isGenerating = true
        errorText = nil
        let snapshot = text
        let providerSnapshot = provider
        let voiceSnapshot = voiceID
        let speedSnapshot = speed

        Task {
            do {
                let result = try await TTSManager.shared.synthesize(text: snapshot,
                                                                    provider: providerSnapshot,
                                                                    voice: voiceSnapshot,
                                                                    speed: speedSnapshot,
                                                                    config: appState.aiConfig)
                await MainActor.run {
                    history.insert(TTSHistoryItem(url: result.audioURL,
                                                  voice: currentVoiceName,
                                                  text: snapshot,
                                                  duration: result.duration,
                                                  createdAt: Date()),
                                   at: 0)
                    isGenerating = false
                    appState.notify("配音已生成")
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func addToTimeline() {
        guard let item = history.first else {
            appState.notify("先生成一段配音")
            return
        }
        let duration = TTSManagerDurationCache.shared.duration(for: item.url) ?? 5
        appState.addGeneratedMedia(url: item.url, duration: duration, name: "配音 · \(item.voice)")
    }
}

final class TTSManagerDurationCache {
    static let shared = TTSManagerDurationCache()
    private var cache: [URL: Double] = [:]

    func duration(for url: URL) -> Double? {
        cache[url]
    }

    func store(_ url: URL, _ duration: Double) {
        cache[url] = duration
    }
}

// MARK: - 音色卡片

struct VoiceCard: View {
    let voice: TTSVoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color(hue: voice.hue, saturation: 0.62, brightness: 0.95),
                                                      Color(hue: voice.hue + 30, saturation: 0.68, brightness: 0.86)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 28, height: 28)
                    Text(String(voice.name.prefix(1)))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(voice.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(voice.subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Theme.accentSoft : Theme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? Theme.accent : Theme.line2, lineWidth: selected ? 1.5 : 1))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 波形

struct WaveformView: View {
    let active: Bool

    private var heights: [CGFloat] {
        var result: [CGFloat] = []
        result.reserveCapacity(56)
        for index in 0..<56 {
            let phase: Double = Double(index) * 0.55
            let base: Double = sin(phase) * 0.5 + 0.5
            let noise: Double = Double((index * 37) % 100) / 100.0
            let mixed: Double = base * 0.7 + noise * 0.3
            let barHeight: CGFloat = CGFloat(8.0 + mixed * 26.0)
            result.append(barHeight)
        }
        return result
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(Theme.brandGradient)
                    .frame(width: 2.5, height: height)
                    .opacity(active ? 0.95 : 0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }
}
