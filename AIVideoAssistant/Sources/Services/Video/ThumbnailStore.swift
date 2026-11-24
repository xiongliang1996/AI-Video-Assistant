//
//  ThumbnailStore.swift
//  给视频片段生成时间线缩略图（异步取帧 + 按「路径#时间」缓存）
//
//  取帧用 AVAssetImageGenerator：
//  - maximumSize 限制在 96×54，缩略图只需要能看出画面内容
//  - appliesPreferredTrackTransform 处理手机竖拍视频的旋转
//  - 同一批时间点一次性提交 generateCGImagesAsynchronously，比逐帧同步快很多
//

import Foundation
import AVFoundation
import AppKit
import Combine

final class ThumbnailStore: ObservableObject {
    static let shared = ThumbnailStore()

    /// key = "path#时间(保留 2 位)"
    @Published private(set) var cache: [String: CGImage] = [:]

    private var requesting: Set<String> = []
    private var generators: [String: AVAssetImageGenerator] = [:]
    private let queue = DispatchQueue(label: "aiva.thumbnail", qos: .utility)

    private init() {}

    static func key(_ url: URL, time: Double) -> String {
        "\(url.path)#\(String(format: "%.2f", max(0, time)))"
    }

    /// 纯查询，不触发加载
    func image(for url: URL, at time: Double) -> CGImage? {
        cache[Self.key(url, time: time)]
    }

    /// 请求一批时间点的缩略图；已经有的、正在取的全部跳过
    func request(url: URL, times: [Double]) {
        let missing = times.filter { time in
            let k = Self.key(url, time: time)
            return cache[k] == nil && !requesting.contains(k)
        }
        guard !missing.isEmpty else { return }
        missing.forEach { requesting.insert(Self.key(url, time: $0)) }

        queue.async { [weak self] in
            guard let self else { return }
            let generator = self.generator(for: url)

            for (index, time) in missing.enumerated() {
                let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: cmTime)]) { _, image, _, _, _ in
                    let key = Self.key(url, time: missing[index])
                    DispatchQueue.main.async {
                        if let image { self.cache[key] = image }
                        self.requesting.remove(key)
                    }
                }
            }
        }
    }

    private func generator(for url: URL) -> AVAssetImageGenerator {
        if let existing = generators[url.path] { return existing }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 放大时间线时一张缩略图会占到 120pt 以上，取帧尺寸留够余量
        generator.maximumSize = CGSize(width: 160, height: 90)
        // 容差放小：宽容差会取到最近关键帧，画面变化处（切镜、转场）容易错位
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        generators[url.path] = generator
        return generator
    }

    /// 清掉某个文件的缓存（素材被替换时用）
    func invalidate(url: URL) {
        let prefix = url.path + "#"
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
        generators[url.path] = nil
    }
}
