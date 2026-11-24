//
//  HoverPreviewStore.swift
//  素材卡片悬停预览：鼠标横向划过卡片时，按位置取对应时间点的画面
//
//  与 ThumbnailStore 的区别：
//  - 时间点是连续的（跟着鼠标走），不能按「路径#时间」缓存，否则缓存会爆
//  - 每个素材只保留「最新一帧」，尺寸更大（480×270），用来做预览
//  - 同一素材同时只允许一个取帧任务在飞，期间的新请求只记下最新时间，
//    上一次取完再补——鼠标快速划过时不会堆一堆过期请求
//

import Foundation
import AVFoundation
import AppKit
import Combine

final class HoverPreviewStore: ObservableObject {
    static let shared = HoverPreviewStore()

    /// key = 文件路径，value = 该素材最新的一帧
    @Published private(set) var frames: [String: CGImage] = [:]

    private var generators: [String: AVAssetImageGenerator] = [:]
    /// 还没取的最新目标时间
    private var pending: [String: Double] = [:]
    /// 正在取帧的素材
    private var busy: Set<String> = []
    /// 每个素材的「取帧代次」：cancel 时 +1，飞行中的旧结果落地时对不上就丢掉
    private var token: [String: Int] = [:]
    private let queue = DispatchQueue(label: "aiva.hoverpreview", qos: .userInitiated)

    private init() {}

    func frame(for url: URL) -> CGImage? {
        frames[url.path]
    }

    /// 请求某一时间点的画面（异步、可被后续请求覆盖）
    func scrub(url: URL, time: Double) {
        guard time.isFinite else { return }
        let path = url.path
        let target = max(0, time)
        queue.async { [weak self] in
            guard let self else { return }
            // 已经有一帧几乎同一时刻的，就别再取了
            if let current = self.pending[path], abs(current - target) < 0.01 { return }
            self.pending[path] = target
            self.pump(url: url)
        }
    }

    /// 鼠标离开卡片时调用：丢掉还没落地的那一帧（保留已取到的帧）
    func cancel(url: URL) {
        let path = url.path
        queue.async { [weak self] in
            guard let self else { return }
            self.pending[path] = nil
            self.token[path, default: 0] += 1
        }
    }

    private func pump(url: URL) {
        let path = url.path
        guard !busy.contains(path), let want = pending[path] else { return }
        pending[path] = nil
        busy.insert(path)
        let myToken = token[path, default: 0]

        let generator = generator(for: url)
        let cmTime = CMTime(seconds: want, preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: cmTime)]) { [weak self] _, image, _, _, _ in
            guard let self else { return }
            self.queue.async {
                self.busy.remove(path)
                // 期间被 cancel 过，这张已经过时了，直接丢
                if self.token[path, default: 0] == myToken, let image {
                    DispatchQueue.main.async { self.frames[path] = image }
                }
                // 期间鼠标又动了，接着取最新那一帧
                if self.pending[path] != nil {
                    self.pump(url: url)
                }
            }
        }
    }

    private func generator(for url: URL) -> AVAssetImageGenerator {
        if let existing = generators[url.path] { return existing }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        // 预览是铺满整张卡片的，比时间线缩略图大一圈
        generator.maximumSize = CGSize(width: 480, height: 270)
        // 悬停预览要跟手，容差放宽到 0.12 s 换取解码速度（拖动时肉眼看不出来）
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.12, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.12, preferredTimescale: 600)
        generators[url.path] = generator
        return generator
    }

    /// 素材被替换 / 移除时清掉
    func invalidate(url: URL) {
        let path = url.path
        frames[path] = nil
        queue.async { [weak self] in
            self?.generators[path] = nil
            self?.pending[path] = nil
            self?.busy.remove(path)
            self?.token[path, default: 0] += 1
        }
    }
}
