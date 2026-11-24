//
//  ClipThumbnailStrip.swift
//  时间线视频片段里的缩略图条：按片段宽度铺 N 张小图
//

import SwiftUI
import AVFoundation

struct ClipThumbnailStrip: View {
    let url: URL
    /// 片段在源文件里的入点（秒）
    var sourceStart: Double = 0
    /// 时间线时长（秒）
    var duration: Double
    /// 变速系数：消耗的源长度 = duration × speed
    var speed: Double = 1
    /// 每张缩略图占的宽度（pt）
    var tileWidth: CGFloat = 52

    @ObservedObject private var store: ThumbnailStore = .shared

    private func times(for width: CGFloat) -> [Double] {
        let count = max(1, Int((width / tileWidth).rounded(.up)))
        let step = duration * max(0.1, speed) / Double(count)
        return (0..<count).map { sourceStart + Double($0) * step }
    }

    var body: some View {
        GeometryReader { geo in
            let list = times(for: geo.size.width)
            let tile = geo.size.width / CGFloat(list.count)
            HStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, time in
                    // 用 overlay 承载图片：图片按 fill 缩放后只在本格内裁切，
                    // 不会把相邻格子的位置挤乱
                    Rectangle()
                        .fill(Color.black.opacity(0.14))
                        .frame(width: tile, height: geo.size.height)
                        .overlay {
                            if let image = store.image(for: url, at: time) {
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .scaledToFill()
                            }
                        }
                        .clipped()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .onAppear { store.request(url: url, times: list) }
            .onChange(of: geo.size.width) { _ in
                store.request(url: url, times: times(for: geo.size.width))
            }
        }
    }
}
