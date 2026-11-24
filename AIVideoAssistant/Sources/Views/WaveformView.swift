//
//  WaveformView.swift
//  波形绘制组件：给定峰值数组画柱状包络，或直接从文件读
//

import SwiftUI

/// 给定峰值数组（0...1）画柱状波形，自动铺满宽度、垂直居中
struct WaveformBars: View {
    let peaks: [Float]
    var color: Color = Theme.accent
    var minBarHeight: CGFloat = 2
    var spacing: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let count = max(1, peaks.count)
            let totalSpacing = spacing * CGFloat(count - 1)
            let barWidth = max(0.7, (geo.size.width - totalSpacing) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(peaks.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth,
                               height: max(minBarHeight, CGFloat(max(0, min(1, value))) * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }
}

/// 从音频文件读真实波形；解码期间显示低透明度占位
struct FileWaveform: View {
    let url: URL
    var buckets: Int = 64
    var color: Color = Theme.accent
    var minBarHeight: CGFloat = 2
    var spacing: CGFloat = 1.5

    @ObservedObject private var store = WaveformStore.shared

    var body: some View {
        let real = store.cachedPeaks(for: url, buckets: buckets)
        let peaks = real ?? WaveformStore.placeholder(buckets: buckets)
        WaveformBars(peaks: peaks,
                     color: color,
                     minBarHeight: minBarHeight,
                     spacing: spacing)
            .opacity(real == nil ? 0.45 : 1)
            .onAppear { store.load(url: url, buckets: buckets) }
    }
}
