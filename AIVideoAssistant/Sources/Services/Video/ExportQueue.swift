//
//  ExportQueue.swift
//  导出队列：串行执行、可取消、可回看历史
//
//  为什么要排队：AVAssetExportSession / AVAssetWriter 同时跑多个会互相抢 CPU 和
//  磁盘带宽，反而更慢；串行还能让「取消」语义简单——只可能有一个在跑。
//

import Foundation
import Combine

@MainActor
final class ExportQueue: ObservableObject {
    static let shared = ExportQueue()

    enum JobState: Equatable {
        case queued
        case running
        case done
        case failed(String)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .queued, .running: return false
            case .done, .failed, .cancelled: return true
            }
        }

        var label: String {
            switch self {
            case .queued: return "排队中"
            case .running: return "导出中"
            case .done: return "已完成"
            case .failed: return "失败"
            case .cancelled: return "已取消"
            }
        }
    }

    struct Job: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var outputURL: URL
        var state: JobState = .queued
        var progress: Double = 0
        var message: String = "排队中"
        var queuedAt = Date()
        var finishedAt: Date?
    }

    /// 入队时的快照：排队期间用户继续改时间线，不应影响已经排上的任务
    private struct Payload {
        var items: [TimelineItem]
        var settings: ExportSettings
    }

    @Published private(set) var jobs: [Job] = []

    /// 当前正在跑的任务变化时回调（用于驱动顶部进度浮层）
    var onActiveJobChange: ((Job?) -> Void)?
    /// 单个任务结束时回调（用于 toast 提示）
    var onJobFinish: ((Job) -> Void)?

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var payloads: [UUID: Payload] = [:]
    private var pumping = false

    private init() {}

    var activeJob: Job? {
        jobs.first { $0.state == .running }
    }

    var runningCount: Int {
        jobs.filter { $0.state == .running }.count
    }

    var pendingCount: Int {
        jobs.filter { $0.state == .queued }.count
    }

    // MARK: - 入队 / 取消

    @discardableResult
    func enqueue(title: String,
                 items: [TimelineItem],
                 settings: ExportSettings,
                 to outputURL: URL) -> UUID {
        let job = Job(title: title, outputURL: outputURL)
        jobs.append(job)
        payloads[job.id] = Payload(items: items, settings: settings)
        pump()
        return job.id
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].state {
        case .queued:
            jobs[index].state = .cancelled
            jobs[index].message = "已取消"
            jobs[index].finishedAt = Date()
            onJobFinish?(jobs[index])
        case .running:
            tasks[id]?.cancel()
        case .done, .failed, .cancelled:
            break
        }
    }

    func cancelAll() {
        for job in jobs where !job.state.isFinished {
            cancel(job.id)
        }
    }

    /// 从列表里移除（只允许移除已结束的任务）
    func remove(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.state.isFinished else { return }
        tasks[id] = nil
        payloads[id] = nil
        jobs.removeAll { $0.id == id }
    }

    func clearFinished() {
        for job in jobs where job.state.isFinished {
            tasks[job.id] = nil
            payloads[job.id] = nil
        }
        jobs.removeAll { $0.state.isFinished }
    }

    // MARK: - 串行执行

    private func pump() {
        guard !pumping else { return }
        guard let next = jobs.first(where: { $0.state == .queued }),
              let payload = payloads[next.id] else { return }

        pumping = true
        update(next.id) { job in
            job.state = .running
            job.message = "准备中"
            job.progress = 0.02
        }
        onActiveJobChange?(jobs.first { $0.id == next.id })

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await VideoExporter.shared.export(items: payload.items,
                                                      settings: payload.settings,
                                                      to: next.outputURL) { progress, message in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.update(next.id) { job in
                            job.progress = max(job.progress, progress)
                            job.message = message
                        }
                        if let job = self.jobs.first(where: { $0.id == next.id }) {
                            self.onActiveJobChange?(job)
                        }
                    }
                }
                await self.finish(next.id, state: .done, message: "导出完成")
            } catch let error as VideoError {
                if case .cancelled = error {
                    await self.finish(next.id, state: .cancelled, message: "已取消")
                } else {
                    await self.finish(next.id, state: .failed(error.localizedDescription), message: "失败")
                }
            } catch is CancellationError {
                await self.finish(next.id, state: .cancelled, message: "已取消")
            } catch {
                await self.finish(next.id, state: .failed(error.localizedDescription), message: "失败")
            }
        }
        tasks[next.id] = task
    }

    private func finish(_ id: UUID, state: JobState, message: String) async {
        update(id) { job in
            job.state = state
            job.message = message
            job.finishedAt = Date()
            if case .done = state { job.progress = 1 }
        }
        tasks[id] = nil
        payloads[id] = nil
        pumping = false
        if let job = jobs.first(where: { $0.id == id }) {
            onJobFinish?(job)
        }
        onActiveJobChange?(nil)
        pump()
    }

    private func update(_ id: UUID, _ body: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[index])
    }
}
