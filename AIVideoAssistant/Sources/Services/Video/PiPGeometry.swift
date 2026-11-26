//
//  PiPGeometry.swift
//  画中画在「预览台视图坐标」与「画幅归一化坐标」之间的换算
//
//  为什么不能直接用视图尺寸当画幅：预览台是 AVPlayerLayer + resizeAspect，
//  4:3 素材进 16:9 画框、竖屏项目、以及成片比例与预览框不一致时都会留黑边。
//  拖拽必须先把「真正的画面矩形」算出来，否则画中画会跟着黑边一起漂。
//

import AVFoundation
import CoreGraphics
import Foundation

enum PiPGeometry {

    /// 读素材的显示尺寸：已套用 preferredTransform，竖屏素材会得到「高 > 宽」。
    /// 预览台画框必须用这个比例，否则竖屏画中画会被画成横的。
    static func displaySize(url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let xform = try? await track.load(.preferredTransform) else { return nil }
        let rect = CGRect(origin: .zero, size: size).applying(xform)
        let width = abs(rect.width)
        let height = abs(rect.height)
        guard width > 1, height > 1, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    /// 内容在给定区域内按 aspect-fit 缩放后的实际矩形（居中，黑边不算）
    static func fittedRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 1, contentSize.height > 1,
              bounds.width > 1, bounds.height > 1 else { return bounds }
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let width = contentSize.width * scale
        let height = contentSize.height * scale
        return CGRect(x: bounds.midX - width / 2,
                      y: bounds.midY - height / 2,
                      width: width,
                      height: height)
    }

    /// 视图坐标 → 归一化坐标（0…1，y 向下）。不夹取，交给调用方决定要不要夹。
    static func normalized(_ point: CGPoint, fitted: CGRect) -> NormalizedPoint {
        guard fitted.width > 0.5, fitted.height > 0.5 else { return NormalizedPoint(x: 0, y: 0) }
        return NormalizedPoint(x: Double((point.x - fitted.minX) / fitted.width),
                               y: Double((point.y - fitted.minY) / fitted.height))
    }

    /// 归一化坐标 → 视图坐标
    static func viewPoint(_ point: NormalizedPoint, fitted: CGRect) -> CGPoint {
        CGPoint(x: fitted.minX + CGFloat(point.x) * fitted.width,
                y: fitted.minY + CGFloat(point.y) * fitted.height)
    }

    /// 把画幅里的矩形映射到视图坐标
    static func viewRect(_ rect: CGRect, renderSize: CGSize, fitted: CGRect) -> CGRect {
        guard renderSize.width > 1, renderSize.height > 1 else { return .zero }
        let sx = fitted.width / renderSize.width
        let sy = fitted.height / renderSize.height
        return CGRect(x: fitted.minX + rect.minX * sx,
                      y: fitted.minY + rect.minY * sy,
                      width: rect.width * sx,
                      height: rect.height * sy)
    }

    /// 已知「画中画中心点」反算左上角原点。
    /// 用中心点是因为拖拽手势抓的是手感中心：用左上角反算会让画中画
    /// 在按下的瞬间往右下跳半个身位。
    static func origin(centeredAt center: NormalizedPoint,
                       size: CGSize,
                       renderSize: CGSize) -> NormalizedPoint {
        guard renderSize.width > 1, renderSize.height > 1 else { return center }
        return NormalizedPoint(
            x: center.x - Double(size.width / renderSize.width) / 2,
            y: center.y - Double(size.height / renderSize.height) / 2
        )
    }

    /// 把左上角夹到「留白以内」。
    /// 上下界可能相等（画中画正好占满可放区域），用 max 兜住，
    /// 否则 `min(max(x, lo), hi)` 在 hi < lo 时会把位置甩到负值。
    static func clampOrigin(_ origin: NormalizedPoint,
                            size: CGSize,
                            renderSize: CGSize,
                            margin: Double) -> NormalizedPoint {
        guard renderSize.width > 1, renderSize.height > 1 else { return origin }
        let w = Double(size.width / renderSize.width)
        let h = Double(size.height / renderSize.height)
        let hiX = max(margin, 1 - margin - w)
        let hiY = max(margin, 1 - margin - h)
        return NormalizedPoint(x: min(max(origin.x, margin), hiX),
                               y: min(max(origin.y, margin), hiY))
    }

    /// 边缘吸附：拖到离边缘很近时贴到留白线上，省得手动对齐。
    /// 只吸附四条边，不吸附中线——自由拖拽的价值就是自由，
    /// 中线吸附会在你想「略微偏左」时一直跟你抢。
    static func snapToEdges(_ origin: NormalizedPoint,
                            size: CGSize,
                            renderSize: CGSize,
                            margin: Double,
                            threshold: Double = 0.012) -> NormalizedPoint {
        guard renderSize.width > 1, renderSize.height > 1 else { return origin }
        let w = Double(size.width / renderSize.width)
        let h = Double(size.height / renderSize.height)
        var p = origin
        if abs(p.x - margin) < threshold { p.x = margin }
        if abs(p.y - margin) < threshold { p.y = margin }
        let right = 1 - margin - w
        let bottom = 1 - margin - h
        if abs(p.x - right) < threshold { p.x = right }
        if abs(p.y - bottom) < threshold { p.y = bottom }
        return p
    }
}
