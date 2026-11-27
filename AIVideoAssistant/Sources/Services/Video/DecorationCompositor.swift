//
//  DecorationCompositor.swift
//  自绘合成器：给画中画做圆角与描边
//
//  为什么必须自绘：`AVMutableVideoCompositionLayerInstruction` 只支持
//  「变换 + 不透明度」，没有任何遮罩能力。想要圆角，只能接管整帧合成。
//
//  接管范围刻意做小：只有项目里真的设了圆角 / 描边时才挂这个合成器
//  （见 PiPStyle.hasDecoration）。全直角的项目继续走系统合成器——
//  那条路有 400+ 条断言兜着，没必要为了「没开这个功能」的项目换引擎。
//
//  坐标系：AVFoundation 的视频坐标系原点在左上、y 向下；CoreImage 原点在
//  左下、y 向上。layerInstruction 里的变换是前者，套到 CI 之前必须先翻一次。
//
//  装饰（圆角 / 描边）放在**源画面空间**做，不是画布空间：
//  有缩放关键帧时，源空间裁一次就够，圆角会跟着缩放一起变，符合直觉；
//  在画布空间做就得每帧反推画中画矩形，还得处理旋转，容易算错。
//

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

// MARK: - 一层要画的东西

/// 一层画面的完整渲染描述。曲线用采样点表示，不用闭包——
/// 采样点在合成器里要跨线程读，闭包带 @Sendable 会很别扭。
struct RenderLayer {
    var trackID: CMPersistentTrackID
    /// 合成时间轴上的采样点，按时间升序、至少两个。
    var samples: [(time: Double, opacity: Double, transform: CGAffineTransform)]
    /// 圆角半径占**源画面短边**的比例。0 = 直角。
    /// 用比例而不是像素：4K 源缩到 320 宽显示时，按像素存会圆得离谱；
    /// 按比例存，源空间裁一次，缩放关键帧时会跟着一起放大缩小。
    var cornerRatio: Double = 0
    /// 描边宽度占源画面短边的比例。0 = 不描边
    var borderRatio: Double = 0
    /// 描边颜色，nil = 不描边
    var borderColor: CGColor?
    /// 调色。中性值 = 原样。有关键帧时这里是「没采到点时」的兜底
    var grade: ColorGrade = ColorGrade()
    /// 调色关键帧采样点（**合成时间轴绝对时间**，已按缓动细分）。
    /// nil 或空 = 用静态 `grade`——绝大多数片段走这条路，不做任何插值
    var gradeSamples: [(time: Double, grade: ColorGrade)]? = nil
    /// 投影模糊半径占**源画面短边**的比例（0 = 不投影）。
    /// 和圆角/描边一样按比例存：构建合成时拿不到源画面尺寸，
    /// 而且按比例存才能让投影跟着缩放关键帧一起放大。
    var shadowRatio: Double = 0
    /// 投影偏移占源画面短边的比例，**视频方向**（正数 = 向下）
    var shadowOffsetRatio: Double = 0
    /// 投影不透明度
    var shadowOpacity: Double = 0
    /// 投影颜色
    var shadowColor: CGColor?

    /// 这一时刻该用哪个调色。没有采样点就是静态值；
    /// 有就两端夹住、中间按分量线性插值（缓动已经在采样时细分过）
    func gradeSample(at time: Double) -> ColorGrade {
        guard let list = gradeSamples, let first = list.first, let last = list.last else {
            return grade
        }
        if list.count == 1 || time <= first.time { return first.grade }
        if time >= last.time { return last.grade }
        for index in 1..<list.count {
            let a = list[index - 1]
            let b = list[index]
            guard time <= b.time else { continue }
            let span = b.time - a.time
            guard span > 0.000_001 else { return b.grade }
            return ColorGrade.lerp(a.grade, b.grade, (time - a.time) / span)
        }
        return last.grade
    }

    /// 在给定时刻的取值：两端夹住、中间线性插值。
    /// 曲线折点本身就是线性的（关键帧的缓动在采样阶段已经细分过），
    /// 所以这里插值和系统 ramp 的行为一致。
    func sample(at time: Double) -> (opacity: Double, transform: CGAffineTransform) {
        guard let first = samples.first, let last = samples.last else {
            return (1, .identity)
        }
        if samples.count == 1 || time <= first.time {
            return (first.opacity, first.transform)
        }
        if time >= last.time {
            return (last.opacity, last.transform)
        }
        for index in 1..<samples.count {
            let a = samples[index - 1]
            let b = samples[index]
            guard time <= b.time else { continue }
            let span = b.time - a.time
            guard span > 0.000_001 else { return (b.opacity, b.transform) }
            let r = (time - a.time) / span
            return (a.opacity + (b.opacity - a.opacity) * r,
                    lerp(a.transform, b.transform, r))
        }
        return (last.opacity, last.transform)
    }

    private func lerp(_ a: CGAffineTransform, _ b: CGAffineTransform, _ r: Double) -> CGAffineTransform {
        let t = CGFloat(r)
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return CGAffineTransform(a: mix(a.a, b.a), b: mix(a.b, b.b),
                                 c: mix(a.c, b.c), d: mix(a.d, b.d),
                                 tx: mix(a.tx, b.tx), ty: mix(a.ty, b.ty))
    }
}

// MARK: - 自定义指令

/// 带渲染描述的指令。系统合成器不认它，只有 `DecorationCompositor` 会读 `layers`；
/// 但 `requiredSourceTrackIDs` 仍然要照实填，否则合成器取不到源帧。
final class CompositeInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    /// 前 → 后，第一个画在最上面
    let layers: [RenderLayer]

    init(timeRange: CMTimeRange, layers: [RenderLayer]) {
        self.timeRange = timeRange
        self.layers = layers
        self.requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
        super.init()
    }
}

// MARK: - 合成器

final class DecorationCompositor: NSObject, AVVideoCompositing {

    private let queue = DispatchQueue(label: "com.xiongliang.aiva.compositor", qos: .userInitiated)
    private let context: CIContext

    override init() {
        // 关掉中间结果缓存：逐帧解码 + 一次性合成，缓存只吃内存不命中
        context = CIContext(options: [.cacheIntermediates: false])
        super.init()
    }

    var sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // 每帧都从 request.renderContext 拿，这里不用另存一份状态
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [weak self] in
            guard let self else {
                request.finish(with: Self.cancelledError)
                return
            }
            self.render(request)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        // 请求都在同一条串行队列上跑，取消时没有可中断的中间态；
        // 导出被取消时 AVFoundation 自己会丢弃后续请求
    }

    private static var cancelledError: NSError {
        NSError(domain: "AIVADecorationCompositor", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "合成请求已取消"])
    }

    // MARK: - 逐帧合成

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        let ctx = request.renderContext
        let size = ctx.size
        guard size.width > 1, size.height > 1 else {
            request.finish(with: Self.cancelledError)
            return
        }
        let canvas = CGRect(origin: .zero, size: size)
        let time = CMTimeGetSeconds(request.compositionTime)

        // 底：纯黑。没有画面时也要给编码器一帧合法的图，否则导出报 -11841
        var image = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: canvas)

        let instruction = request.videoCompositionInstruction as? CompositeInstruction
        let layers = instruction?.layers ?? []

        // 第一个是最前面，绘制要反着来
        for layer in layers.reversed() {
            guard let buffer = request.sourceFrame(byTrackID: layer.trackID) else { continue }
            let s = layer.sample(at: time)
            guard s.opacity > 0.002 else { continue }

            var source = CIImage(cvPixelBuffer: buffer)
            let sourceRect = source.extent
            guard sourceRect.width > 1, sourceRect.height > 1 else { continue }

            // 先调色再裁圆角：描边是用户挑的颜色，不该被调色带偏
            let grade = layer.gradeSample(at: time)
            if !grade.isNeutral {
                source = Self.applyGrade(source, grade)
            }

            let short = min(sourceRect.width, sourceRect.height)
            let radius = layer.cornerRatio * short
            let border = layer.borderRatio * short

            if radius > 0.5 || (border > 0.01 && layer.borderColor != nil) {
                source = Self.decorate(source,
                                       radius: radius,
                                       borderWidth: border,
                                       borderColor: layer.borderColor)
            }

            // 投影必须垫在**裁完圆角之后**：`decorate` 里的 CISourceInCompositing
            // 会把 extent 收回到画面矩形，先垫阴影会被那一步直接裁掉
            let shadowBlur = layer.shadowRatio * short
            if shadowBlur > 0.5, layer.shadowOpacity > 0.005,
               let shadowColor = layer.shadowColor {
                // 「向下」在源空间是负 y：源画面是 CoreImage 坐标，y 向上
                let offset = CGPoint(x: 0, y: -layer.shadowOffsetRatio * short)
                let shadow = Self.shadow(rect: sourceRect,
                                         radius: radius,
                                         blur: shadowBlur,
                                         offset: offset,
                                         color: shadowColor,
                                         opacity: layer.shadowOpacity)
                source = source.composited(over: shadow)
            }

            // 翻转 y 再套变换：视频坐标（y 向下）→ CoreImage 坐标（y 向上）
            let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                               tx: 0, ty: sourceRect.height)
            let flipCanvas = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                               tx: 0, ty: size.height)
            let matrix = flipSource.concatenating(s.transform).concatenating(flipCanvas)
            var placed = source.transformed(by: matrix)

            if s.opacity < 0.999 {
                placed = Self.applyOpacity(placed, s.opacity)
            }
            image = placed.composited(over: image)
        }

        guard let output = ctx.newPixelBuffer() else {
            request.finish(with: Self.cancelledError)
            return
        }
        context.render(image,
                       to: output,
                       bounds: canvas,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: output)
    }

    // MARK: - 调色

    /// 曝光 → 白平衡 → 对比度 / 饱和度。
    ///
    /// 顺序不是随便排的：曝光和白平衡是「物理量」，先归位；对比度和饱和度是
    /// 「观感量」，放最后调。反过来先拉对比度再提曝光，高光会先被推爆。
    static func applyGrade(_ image: CIImage, _ grade: ColorGrade) -> CIImage {
        let g = grade.sanitized
        var result = image

        if abs(g.exposure) > 0.005 {
            result = result.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: g.exposure
            ])
        }

        if abs(g.temperature) > 0.005 {
            // neutral 是「原图被当作的光源色温」，target 是「想让它看起来的色温」。
            // 往高色温调 = 画面偏暖（相机按更冷的光做白平衡，剩下的就是暖调）
            result = result.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: ColorGrade.neutralKelvin, y: 0),
                "inputTargetNeutral": CIVector(x: g.kelvin, y: 0)
            ])
        }

        if abs(g.contrast - 1) > 0.005 || abs(g.saturation - 1) > 0.005 {
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: g.contrast,
                kCIInputSaturationKey: g.saturation
            ])
        }
        return result
    }

    // MARK: - 装饰

    /// 圆角裁切 + 描边，都在源画面自己的像素空间里做。
    /// 顺序是先裁圆角再描边：描边要压在圆角边缘上，反过来会被裁掉一半。
    static func decorate(_ image: CIImage,
                         radius: CGFloat,
                         borderWidth: CGFloat,
                         borderColor: CGColor?) -> CIImage {
        let rect = image.extent
        guard rect.width > 2, rect.height > 2 else { return image }

        let r = min(max(radius, 0), min(rect.width, rect.height) / 2)
        var result = image
        if r > 0.5 {
            result = rounded(image, rect: rect, radius: r)
        }

        guard borderWidth > 0.01, let color = borderColor else { return result }
        let width = min(borderWidth, min(rect.width, rect.height) / 2)
        guard width > 0.01 else { return result }

        // 环 = 外圈圆角矩形 − 内圈圆角矩形。两个白色遮罩相乘之前
        // 把内圈的 alpha 反相（a' = 1 − a），交集才变成「环」而不是「内芯」
        let outer = roundedMask(rect: rect, radius: r)
        let innerRect = rect.insetBy(dx: width, dy: width)
        // 描边宽到把画面吃光时没有「内圈」可言，直接铺满整块
        guard innerRect.width > 2, innerRect.height > 2 else {
            let solid = CIImage(color: CIColor(cgColor: color)).cropped(to: rect)
            let clipped = solid.applyingFilter("CISourceInCompositing", parameters: [
                kCIInputBackgroundImageKey: outer
            ])
            return clipped.composited(over: result)
        }
        let innerRadius = max(0, r - width)
        var inner = roundedMask(rect: innerRect, radius: innerRadius)
        inner = inner.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: -1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        let ring = outer.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: inner
        ])

        // 遮罩染成描边色，再压在裁好的画面上
        let solid = CIImage(color: CIColor(cgColor: color)).cropped(to: rect)
        let stroke = solid.applyingFilter("CISourceInCompositing", parameters: [
            kCIInputBackgroundImageKey: ring
        ])
        return stroke.composited(over: result)
    }

    // MARK: - 投影

    /// 圆角形状的投影：拿和圆角裁切同一个遮罩，模糊 → 偏移 → 染色。
    ///
    /// 不用 `CIShadow` 之类的现成滤镜，因为它的形状只能取输入图的 alpha——
    /// 而这里的输入是视频帧，alpha 永远是满的，投影会变成整块矩形。
    ///
    /// 返回的图 extent 已经向外扩过（模糊会溢出边界），调用方直接
    /// `composited(over:)` 垫在画面下面即可。
    static func shadow(rect: CGRect,
                       radius: CGFloat,
                       blur: CGFloat,
                       offset: CGPoint,
                       color: CGColor,
                       opacity: Double) -> CIImage {
        let safeBlur = max(0, blur)
        // 高斯大约 3σ 之外就衰减没了，留一点余量免得阴影被硬边切掉
        let pad = safeBlur * 2.5 + max(abs(offset.x), abs(offset.y)) + 2
        let expanded = rect.insetBy(dx: -pad, dy: -pad)

        var mask = roundedMask(rect: rect,
                               radius: min(max(radius, 0), min(rect.width, rect.height) / 2))
        if abs(offset.x) > 0.01 || abs(offset.y) > 0.01 {
            mask = mask.transformed(by: CGAffineTransform(translationX: offset.x,
                                                          y: offset.y))
        }
        if safeBlur > 0.5 {
            mask = mask.applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: safeBlur
            ])
        }
        // 模糊后的 extent 是无限的，必须裁回扩展矩形，否则后面整条管线都在无限画布上跑
        mask = mask.cropped(to: expanded)

        let solid = CIImage(color: CIColor(cgColor: color)).cropped(to: expanded)
        var result = solid.applyingFilter("CISourceInCompositing", parameters: [
            kCIInputBackgroundImageKey: mask
        ])
        if opacity < 0.999 {
            result = applyOpacity(result, opacity)
        }
        return result
    }

    /// 用圆角矩形当 alpha 遮罩裁图
    private static func rounded(_ image: CIImage, rect: CGRect, radius: CGFloat) -> CIImage {
        let mask = roundedMask(rect: rect, radius: radius)
        return image.applyingFilter("CISourceInCompositing", parameters: [
            kCIInputBackgroundImageKey: mask
        ])
    }

    private static func roundedMask(rect: CGRect, radius: CGFloat) -> CIImage {
        // CIRoundedRectangleGenerator 是 generator，没有 inputImage，
        // 走不了 applyingFilter，得直接构造 filter
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else {
            return CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: rect)
        }
        filter.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        filter.setValue(max(0, radius), forKey: "inputRadius")
        filter.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor")
        let fallback = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: rect)
        return (filter.outputImage ?? fallback).cropped(to: rect)
    }

    /// 乘不透明度。必须同时乘 RGB 和 A —— 视频帧是 premultiplied 的，
    /// 只乘 A 会让半透明区域发白。
    static func applyOpacity(_ image: CIImage, _ opacity: Double) -> CIImage {
        let o = CGFloat(min(max(opacity, 0), 1))
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: o, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: o, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: o, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: o),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    }
}
