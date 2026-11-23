//
//  AIGenerateView.swift
//  AI 生视频
//

import SwiftUI
import AppKit

struct GeneratedResult: Identifiable {
    let id = UUID()
    let url: URL
    let prompt: String
    let style: VideoStyle
    let createdAt: Date
}

struct AIGenerateView: View {
    @EnvironmentObject var appState: AppState

    @State private var prompt = ""
    @State private var style: VideoStyle = .realistic
    @State private var camera: CameraMotion = .fixed
    @State private var duration = 5
    @State private var resolution = "1920x1080"
    @State private var negativePrompt = ""
    @State private var results: [GeneratedResult] = []
    @State private var isGenerating = false
    @State private var errorText: String?

    private let inspirations = [
        ("咖啡店晨光", "清晨的咖啡店里，阳光穿过百叶窗，一杯拿铁冒着热气，镜头缓慢推进"),
        ("雨夜街头", "霓虹灯下的雨夜街道，一位撑伞的行人走过，镜头跟随移动"),
        ("产品旋转", "产品在纯黑背景中缓缓旋转，柔和的轮廓光勾勒边缘")
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(alignment: .top, spacing: 16) {
                form
                resultArea
            }
            .padding(16)
        }
        .background(Theme.bg)
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.brandGradient)
                    .frame(width: 22, height: 22)
                    .overlay(Image(systemName: "wand.and.stars")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white))
                Text("AI 生视频")
                    .font(.system(size: 14, weight: .semibold))
                Text("用一句描述，生成可用片段")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
            StatusPill(text: "本次预估 \(duration * 8) 点")
            Button {
                appState.notify("历史记录功能开发中")
            } label: {
                Label("历史记录", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12.5))
            }
            .buttonStyle(SoftButtonStyle())
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Theme.panel.opacity(0.72))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: 参数表单

    private var form: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("创作参数")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text("步骤 1 / 2")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // 提示词
                        VStack(alignment: .leading, spacing: 6) {
                            label("textformat", "提示词")
                            TextEditor(text: $prompt)
                                .font(.system(size: 12.5))
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .frame(height: 96)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Theme.panel)
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line2, lineWidth: 1))
                                )
                                .overlay(alignment: .topLeading) {
                                    if prompt.isEmpty {
                                        Text("描述你想要的画面，例如：清晨的咖啡店里，阳光穿过百叶窗…")
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(Theme.text3)
                                            .padding(.horizontal, 11)
                                            .padding(.vertical, 12)
                                            .allowsHitTesting(false)
                                    }
                                }
                            HStack {
                                Text("\(prompt.count) / 500")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.text3)
                                Spacer()
                                Button("帮我润色") {
                                    appState.notify("提示词润色功能开发中")
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.accent)
                            }
                        }

                        // 灵感
                        VStack(alignment: .leading, spacing: 6) {
                            label("sparkles", "灵感")
                            HStack(spacing: 6) {
                                ForEach(inspirations, id: \.0) { item in
                                    Chip(text: item.0) { prompt = item.1 }
                                }
                            }
                        }

                        // 风格
                        VStack(alignment: .leading, spacing: 6) {
                            label("paintpalette", "画面风格")
                            FlowChips(items: VideoStyle.allCases.map(\.rawValue),
                                      selection: style.rawValue) { raw in
                                if let s = VideoStyle(rawValue: raw) { style = s }
                            }
                        }

                        // 参数
                        HStack(spacing: 8) {
                            picker("时长", "\(duration) 秒")
                            picker("分辨率", resolution == "1920x1080" ? "1080p" : "720p")
                            picker("帧率", "24 fps")
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            label("video", "镜头运动")
                            SegmentedControl(options: CameraMotion.allCases,
                                             title: { $0.rawValue },
                                             selection: $camera)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            label("xmark", "负面提示词")
                            TextField("模糊、变形、低画质、水印…", text: $negativePrompt)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5))
                                .padding(.horizontal, 8)
                                .frame(height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Theme.panel)
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line2, lineWidth: 1))
                                )
                        }

                        Button {
                            generate()
                        } label: {
                            HStack(spacing: 6) {
                                if isGenerating {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(isGenerating ? "生成中…" : "生成视频")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle(height: 36, fullWidth: true))
                        .disabled(prompt.isEmpty || isGenerating)

                        Text("预计耗时 40–90 秒 · 消耗 \(duration * 8) 点额度")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.text3)
                            .frame(maxWidth: .infinity)

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

    private func picker(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
            FieldBox {
                HStack {
                    Text(value).foregroundStyle(Theme.text)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.text3)
                }
            }
        }
    }

    // MARK: 结果区

    private var resultArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("生成结果")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("本次 \(results.count) 个")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Text("按时间倒序")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
            }

            if results.isEmpty && !isGenerating {
                Card {
                    EmptyHint(icon: "sparkles",
                              title: "还没有生成结果",
                              subtitle: "写下你的想法，点击「生成视频」开始")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                              spacing: 12) {
                        if isGenerating {
                            GeneratingCard()
                        }
                        ForEach(results) { result in
                            ResultCard(result: result) {
                                appState.addGeneratedMedia(url: result.url,
                                                           duration: Double(duration),
                                                           name: String(result.prompt.prefix(12)))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 生成

    private func generate() {
        guard !prompt.isEmpty else { return }
        isGenerating = true
        errorText = nil

        let config = VideoGenerationConfig(duration: duration,
                                           resolution: resolution,
                                           fps: 24,
                                           style: style,
                                           cameraMotion: camera,
                                           negativePrompt: negativePrompt)

        Task {
            do {
                let service = OpenAIService(config: appState.aiConfig)
                let url = try await service.generateImage(prompt: prompt, config: config)
                await MainActor.run {
                    results.insert(GeneratedResult(url: url, prompt: prompt, style: style, createdAt: Date()),
                                   at: 0)
                    isGenerating = false
                    appState.notify("生成完成，已加入结果区")
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    errorText = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 结果卡片

struct ResultCard: View {
    let result: GeneratedResult
    let onAdd: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            if let image = NSImage(contentsOf: result.url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.thumb(result.id.uuidString.hashValue)
            }

            VStack {
                HStack {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles").font(.system(size: 8))
                        Text("AI").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    Spacer()
                }
                Spacer()
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.prompt)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                    Text("\(result.style.rawValue) · 已生成")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.white)
            }
            .padding(7)

            if hovering {
                Color.black.opacity(0.5)
                HStack(spacing: 6) {
                    Button {
                        onAdd()
                    } label: {
                        Label("加入时间线", systemImage: "plus")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(SoftButtonStyle(height: 26))
                }
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
        .onHover { hovering = $0 }
    }
}

struct GeneratingCard: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xEEF0FF), Color(hex: 0xF8F2FF)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("AI 正在创作中…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text2)
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
    }
}

// MARK: - 自动换行标签

struct FlowChips: View {
    let items: [String]
    let selection: String
    let onSelect: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Chip(text: item, selected: item == selection) {
                    onSelect(item)
                }
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
