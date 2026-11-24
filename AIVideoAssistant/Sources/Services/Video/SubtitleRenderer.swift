//
//  SubtitleRenderer.swift
//  字幕 / 文字图层：导出时逐帧烧进画面，预览时用同一套样式做覆盖层
//
//  为什么不用 AVVideoCompositionCoreAnimationTool：
//  在 macOS 26 上实测该工具输出整帧白屏（父层透明/黑底、视频层着色、同步/异步导出、
//  不同 preset 全部无效），属于系统级失效。改为在导出管线的帧循环里用 Core Graphics 绘制，
//  稳定且预览与成片共用同一套样式参数。
//
//  设计要点：
//  - 样式尺寸以 1080p 画布为基准，渲染时按 renderSize.height / 1080 等比缩放
//  - CGContext 原点在左下，与「距底部比例」天然一致，无需翻转坐标系
//

import Foundation
import AppKit
import AVFoundation
import CoreText
import CoreGraphics

enum SubtitleRenderer {

    /// 1080p 基准画布高度
    static let designHeight: CGFloat = 1080

    // MARK: - 样式

    struct Style {
        var text: String
        var fontSize: CGFloat
        var bold: Bool
        var colorHex: Int
        var boxOpacity: Double
        /// 距画面底部的比例
        var offsetY: Double
        var scale: CGFloat

        init(item: TimelineItem, renderHeight: CGFloat) {
            let p = item.properties
            self.text = SubtitleRenderer.text(of: item)
            self.scale = max(0.05, renderHeight / SubtitleRenderer.designHeight)
            self.fontSize = max(8, CGFloat(p.fontSize) * scale)
            self.bold = p.textBold
            self.colorHex = p.textColorHex
            self.boxOpacity = min(max(p.textBoxOpacity, 0), 1)
            self.offsetY = min(max(p.textOffsetY, 0), 0.85)
        }

        var font: NSFont {
            NSFont.systemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
        }

        var color: NSColor {
            NSColor(srgbRed: CGFloat((colorHex >> 16) & 0xFF) / 255.0,
                    green: CGFloat((colorHex >> 8) & 0xFF) / 255.0,
                    blue: CGFloat(colorHex & 0xFF) / 255.0,
                    alpha: 1)
        }

        var cgColor: CGColor { color.cgColor }

        var horizontalPadding: CGFloat { fontSize * 0.52 }
        var verticalPadding: CGFloat { fontSize * 0.26 }
        var cornerRadius: CGFloat { fontSize * 0.34 }
        var maxTextWidth: CGFloat { 1080 * scale * 0.84 }
    }

    static func text(of item: TimelineItem) -> String {
        let raw = item.properties.textContent.isEmpty ? item.name : item.properties.textContent
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 该时间点应该显示的字幕（同一时刻多条时取最上层）
    static func activeItem(at time: Double, in items: [TimelineItem]) -> TimelineItem? {
        items
            .filter { ($0.type == .subtitle || $0.type == .text) && !text(of: $0).isEmpty }
            .filter { time >= $0.startTime - 0.001 && time < $0.endTime - 0.001 }
            .sorted { $0.startTime > $1.startTime }
            .first
    }
}

// MARK: - 导出时逐帧绘制

/// 预先算好每条字幕的排版，导出时按时间点直接画
final class SubtitleFrameRenderer {

    private struct Entry {
        let start: Double
        let end: Double
        let attributed: NSAttributedString
        let boxRect: CGRect
        let textRect: CGRect
        let cornerRadius: CGFloat
        let boxOpacity: Double
        let fade: Double
    }

    private let entries: [Entry]
    private let renderSize: CGSize

    init(items: [TimelineItem], renderSize: CGSize) {
        self.renderSize = renderSize

        var built: [Entry] = []
        for item in items where item.type == .subtitle || item.type == .text {
            let style = SubtitleRenderer.Style(item: item, renderHeight: renderSize.height)
            guard !style.text.isEmpty else { continue }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping

            let attributes: [NSAttributedString.Key: Any] = [
                .font: style.font,
                .foregroundColor: style.color,
                .paragraphStyle: paragraph
            ]
            let attributed = NSAttributedString(string: style.text, attributes: attributes)

            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            var fitRange = CFRange()
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: 0),
                nil,
                CGSize(width: style.maxTextWidth, height: .greatestFiniteMagnitude),
                &fitRange
            )
            let textWidth = min(style.maxTextWidth, ceil(suggested.width) + 2)
            let textHeight = ceil(suggested.height) + 2

            let boxWidth = min(renderSize.width * 0.94, textWidth + style.horizontalPadding * 2)
            let boxHeight = textHeight + style.verticalPadding * 2
            let boxX = (renderSize.width - boxWidth) / 2
            let boxY = renderSize.height * style.offsetY

            let boxRect = CGRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
            let textRect = CGRect(x: boxX + (boxWidth - textWidth) / 2,
                                  y: boxY + style.verticalPadding,
                                  width: textWidth,
                                  height: textHeight)

            let duration = max(0.15, item.duration)
            built.append(Entry(start: item.startTime,
                               end: item.startTime + duration,
                               attributed: attributed,
                               boxRect: boxRect,
                               textRect: textRect,
                               cornerRadius: style.cornerRadius,
                               boxOpacity: style.boxOpacity,
                               fade: min(0.12, duration * 0.18)))
        }
        self.entries = built
    }

    var isEmpty: Bool { entries.isEmpty }

    /// 在 BGRA 像素缓冲区上绘制该时间点的字幕
    func draw(into pixelBuffer: CVPixelBuffer, at time: Double) {
        guard !entries.isEmpty else { return }
        let active = entries.filter { time >= $0.start - 0.001 && time < $0.end - 0.001 }
        guard !active.isEmpty else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else { return }

        for entry in active {
            var alpha = 1.0
            if entry.fade > 0.001 {
                let elapsed = time - entry.start
                let remaining = entry.end - time
                alpha = min(1, min(elapsed / entry.fade, remaining / entry.fade))
                alpha = min(max(alpha, 0), 1)
            }

            ctx.saveGState()
            ctx.setAlpha(alpha)

            if entry.boxOpacity > 0.01 {
                let path = CGPath(roundedRect: entry.boxRect,
                                  cornerWidth: entry.cornerRadius,
                                  cornerHeight: entry.cornerRadius,
                                  transform: nil)
                ctx.addPath(path)
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: entry.boxOpacity))
                ctx.fillPath()
            }

            let framesetter = CTFramesetterCreateWithAttributedString(entry.attributed)
            let path = CGPath(rect: entry.textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter,
                                                CFRange(location: 0, length: 0),
                                                path,
                                                nil)
            CTFrameDraw(frame, ctx)

            ctx.restoreGState()
        }
    }
}
