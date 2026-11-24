//
//  MediaHoverPreview.swift
//  素材卡片的悬停预览与拖拽预览
//
//  - 悬停：鼠标横向划过卡片时，画面跟着鼠标位置「搓」起来（类似剪辑软件的 skim），
//    底部有一条进度条 + 右上角时间码，鼠标离开立刻退回封面图
//  - 拖拽：拖到时间线时带一张缩略图，而不是系统默认的文档图标
//

import SwiftUI
import AppKit

private struct MediaCardWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 悬停搓动预览
struct MediaSkimModifier: ViewModifier {
    let asset: MediaAsset
    var cornerRadius: CGFloat = 8

    @ObservedObject private var store: HoverPreviewStore = .shared
    @State private var cardWidth: CGFloat = 0
    @State private var ratio: CGFloat?

    /// 只有视频、且时长够长才值得搓
    private var skimmable: Bool {
        asset.type == .video && asset.duration > 0.2
    }

    /// 鼠标横向位置 → 素材内的时间点（0…duration）
    static func skimTime(x: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard width > 1, duration > 0 else { return 0 }
        let ratio = min(1, max(0, x / width))
        return Double(ratio) * duration
    }

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: MediaCardWidthKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(MediaCardWidthKey.self) { cardWidth = $0 }
            .overlay {
                if let ratio, skimmable, let frame = store.frame(for: asset.url) {
                    MediaSkimOverlay(frame: frame,
                                     ratio: ratio,
                                     time: Double(ratio) * asset.duration,
                                     cornerRadius: cornerRadius)
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    guard skimmable, cardWidth > 1 else { return }
                    ratio = min(1, max(0, point.x / cardWidth))
                    store.scrub(url: asset.url,
                                time: Self.skimTime(x: point.x, width: cardWidth, duration: asset.duration))
                case .ended:
                    ratio = nil
                    store.cancel(url: asset.url)
                }
            }
    }
}

/// 预览层本身：画面 + 底部进度条 + 时间码
struct MediaSkimOverlay: View {
    let frame: CGImage
    let ratio: CGFloat
    let time: Double
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(decorative: frame, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)

            GeometryReader { geo in
                let x = geo.size.width * ratio
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.black.opacity(0.35))
                        .frame(height: 3)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: max(0, x), height: 3)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                        .shadow(color: .black.opacity(0.35), radius: 1)
                        .offset(x: max(0, min(geo.size.width - 6, x - 3)))
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }

            HStack {
                Spacer()
                Text(Self.fineTime(time))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(.black.opacity(0.55)))
            }
            .padding(4)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    static func fineTime(_ seconds: Double) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

/// 拖拽时跟着鼠标走的小缩略图
struct MediaDragPreview: View {
    @ObservedObject var asset: MediaAsset
    let index: Int

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                if let image = asset.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Theme.thumb(index)
                }
            }
            .frame(width: 64, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(asset.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                Text(asset.durationText)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
        }
        .padding(6)
        .frame(maxWidth: 200, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(hex: 0x15161C).opacity(0.92))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        )
    }
}

extension View {
    /// 给素材卡片加悬停搓动预览
    func mediaSkim(_ asset: MediaAsset, cornerRadius: CGFloat = 8) -> some View {
        modifier(MediaSkimModifier(asset: asset, cornerRadius: cornerRadius))
    }
}
