//
//  OnboardingView.swift
//  首次使用引导 + 隐私说明
//

import SwiftUI
import AppKit

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    @State private var index = 0

    /// 截图 / 预览用：直接打开某一页
    init(initialPage: Int = 0) {
        _index = State(initialValue: OnboardingContent.clamp(initialPage))
    }

    private var page: OnboardingPage {
        OnboardingContent.pages[OnboardingContent.clamp(index)]
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            Rectangle().fill(Theme.line).frame(height: 1)
            footer
        }
        .frame(width: 600, height: 366)
        .background(Theme.panel)
        // 按 Esc 关掉也算看过了：否则每次启动都弹，用户会以为是 bug
        .onDisappear { OnboardingGate.markSeen() }
    }

    // MARK: - 内容

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Theme.brandGradient)
                    .frame(width: 52, height: 52)
                    .overlay(Image(systemName: page.icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white))
                    .shadow(color: Theme.accent.opacity(0.3), radius: 10, y: 5)

                VStack(alignment: .leading, spacing: 6) {
                    Text(page.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(page.body)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(page.bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 1)
                        Text(bullet)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 20)

            if !page.note.isEmpty {
                note(page.note, icon: "lightbulb")
                    .padding(.top, 16)
            }

            Spacer(minLength: 0)

            HStack(spacing: 7) {
                ForEach(0..<OnboardingContent.pageCount, id: \.self) { dot in
                    Capsule()
                        .fill(dot == index ? Theme.accent : Theme.line2)
                        .frame(width: dot == index ? 16 : 6, height: 6)
                        .animation(.easeOut(duration: 0.18), value: index)
                }
                Spacer()
                Text("\(index + 1) / \(OnboardingContent.pageCount)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    // MARK: - 页脚

    private var footer: some View {
        HStack(spacing: 8) {
            Button("跳过") { finish() }
                .buttonStyle(SoftButtonStyle())

            Spacer()

            if index > 0 {
                Button("上一步") { index = OnboardingContent.clamp(index - 1) }
                    .buttonStyle(SoftButtonStyle())
            }

            Button(OnboardingContent.isLast(index) ? "开始创作" : "下一步") {
                if OnboardingContent.isLast(index) {
                    finish()
                } else {
                    index = OnboardingContent.clamp(index + 1)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Theme.panel2)
    }

    private func note(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.text3)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.panel2))
    }

    private func finish() {
        OnboardingGate.markSeen()
        appState.showingOnboarding = false
        dismiss()
    }
}

// MARK: - 隐私说明

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("隐私说明")
                    .font(.system(size: 15, weight: .semibold))
                Text(PrivacyContent.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Rectangle().fill(Theme.line).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(PrivacyContent.sections) { section in
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Theme.accentSoft)
                                .frame(width: 26, height: 26)
                                .overlay(Image(systemName: section.icon)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.accent))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(section.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.text)
                                Text(section.body)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.text2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(20)
            }

            Rectangle().fill(Theme.line).frame(height: 1)

            HStack(spacing: 8) {
                Button {
                    AppLog.revealLogFile()
                } label: {
                    Label("打开日志文件", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(SoftButtonStyle())
                Spacer()
                Button("知道了") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Theme.panel2)
        }
        .frame(width: 540, height: 392)
        .background(Theme.panel)
    }
}
