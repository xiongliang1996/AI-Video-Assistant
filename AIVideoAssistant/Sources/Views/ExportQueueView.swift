//
//  ExportQueueView.swift
//  导出队列面板：看进度、取消、在访达里定位成品
//

import SwiftUI
import AppKit

struct ExportQueueView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var queue = ExportQueue.shared

    var body: some View {
        VStack(spacing: 0) {
            header

            if queue.jobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.text3)
                    Text("队列是空的")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.text2)
                    Text("⌘E 导出视频后会出现在这里，可以排队、取消")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(queue.jobs.reversed()) { job in
                            row(job)
                        }
                    }
                    .padding(14)
                }
            }

            footer
        }
        .frame(width: 470, height: 430)
        .background(Theme.panel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("导出队列")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            if queue.pendingCount > 0 || queue.runningCount > 0 {
                Text("\(queue.runningCount + queue.pendingCount)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Theme.accent))
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 22))
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Theme.panel2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("关闭") { dismiss() }
                .buttonStyle(SoftButtonStyle(height: 30))
            Spacer()
            Button("清理已结束") { queue.clearFinished() }
                .buttonStyle(SoftButtonStyle(height: 30))
                .disabled(queue.jobs.allSatisfy { !$0.state.isFinished })
            Button("全部取消") { queue.cancelAll() }
                .buttonStyle(SoftButtonStyle(height: 30))
                .disabled(queue.runningCount + queue.pendingCount == 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(Theme.panel2)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: 单行

    private func row(_ job: ExportQueue.Job) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(job.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                stateChip(job.state)
                Spacer()
                Text(job.outputURL.lastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .trailing)
            }

            // 自绘进度条：系统 ProgressView 的 tint 在 macOS 上常被忽略
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.07))
                    Capsule()
                        .fill(tint(for: job.state))
                        .frame(width: max(3, geo.size.width * min(1, max(0, job.progress))))
                }
            }
            .frame(height: 6)

            HStack(spacing: 8) {
                Text(job.message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                Spacer()

                if !job.state.isFinished {
                    Button("取消") { queue.cancel(job.id) }
                        .buttonStyle(SoftButtonStyle(height: 22))
                } else {
                    if case .done = job.state {
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([job.outputURL])
                        }
                        .buttonStyle(SoftButtonStyle(height: 22))
                    }
                    Button("移除") { queue.remove(job.id) }
                        .buttonStyle(SoftButtonStyle(height: 22))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
    }

    private func stateChip(_ state: ExportQueue.JobState) -> some View {
        Text(state.label)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(tint(for: state))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint(for: state).opacity(0.12)))
    }

    private func tint(for state: ExportQueue.JobState) -> Color {
        switch state {
        case .queued: return Theme.text3
        case .running: return Theme.accent
        case .done: return Theme.ok
        case .failed: return Theme.danger
        case .cancelled: return Theme.warning
        }
    }
}
