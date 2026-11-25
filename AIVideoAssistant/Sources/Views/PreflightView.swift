//
//  PreflightView.swift
//  导出前体检面板：把静默问题列清楚，再决定导不导
//

import SwiftUI

struct PreflightView: View {
    @EnvironmentObject var appState: AppState

    let report: PreflightReport
    /// 「仍然导出」
    var onContinue: () -> Void
    /// 取消 / 去修改
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            if report.issues.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(report.issues) { issue in
                            row(issue)
                        }
                    }
                    .padding(14)
                }
            }

            footer
        }
        .frame(width: 500, height: 460)
        .background(Theme.panel)
    }

    // MARK: 头

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: report.blocksExport ? "xmark.octagon.fill" : "checklist")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(report.blocksExport ? Theme.danger : Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("导出前体检")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(report.headline)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
            if report.errorCount > 0 { counter(report.errorCount, .error) }
            if report.warningCount > 0 { counter(report.warningCount, .warning) }
            if report.infoCount > 0 { counter(report.infoCount, .info) }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Theme.panel2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func counter(_ count: Int, _ severity: PreflightSeverity) -> some View {
        HStack(spacing: 3) {
            Image(systemName: severity.icon)
                .font(.system(size: 8.5))
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(tint(severity))
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(tint(severity).opacity(0.12)))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 24))
                .foregroundStyle(Theme.ok)
            Text("没发现问题，可以直接导出")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 单条

    private func row(_ issue: PreflightIssue) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: issue.severity.icon)
                .font(.system(size: 11))
                .foregroundStyle(tint(issue.severity))
                .frame(width: 14)
                .padding(.top, 1.5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(issue.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(issue.severity.label)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(tint(issue.severity))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(tint(issue.severity).opacity(0.12)))
                    Spacer(minLength: 0)
                }
                Text(issue.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
    }

    // MARK: 底

    private var footer: some View {
        HStack(spacing: 8) {
            if report.blocksExport {
                Text("这些问题会让导出失败，建议先改")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(1)
            }
            Spacer()
            Button(report.blocksExport ? "去修改" : "取消") { onCancel() }
                .buttonStyle(SoftButtonStyle(height: 30))
            if report.blocksExport {
                Button("仍然导出") { onContinue() }
                    .buttonStyle(SoftButtonStyle(height: 30))
            } else {
                Button("开始导出") { onContinue() }
                    .buttonStyle(PrimaryButtonStyle(height: 30))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(Theme.panel2)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func tint(_ severity: PreflightSeverity) -> Color {
        switch severity {
        case .error: return Theme.danger
        case .warning: return Theme.warning
        case .info: return Theme.accent
        }
    }
}
