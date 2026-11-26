//
//  make-icon.swift
//  把一张方形图片做成 macOS .icns：抠掉白底、按 macOS 图标网格缩进、切圆角
//
//  用法: make-icon <源图> <输出 .icns> [内容边长占比，默认 0.805]
//

import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: make-icon <input> <output.icns> [contentRatio]")
    exit(1)
}
let inputPath = args[1]
let outputPath = args[2]
let contentRatio = args.count > 3 ? Double(args[3])! : 0.805

guard let source = NSImage(contentsOfFile: inputPath),
      let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("读不到图片: \(inputPath)")
    exit(1)
}

let width = cgSource.width
let height = cgSource.height
print("源图 \(width)x\(height)")

// MARK: 找非白底的包围盒

var pixels = [UInt8](repeating: 0, count: width * height * 4)
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let readContext = CGContext(data: &pixels,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}
readContext.draw(cgSource, in: CGRect(x: 0, y: 0, width: width, height: height))

var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height {
    for x in 0..<width {
        let offset = (y * width + x) * 4
        let r = Int(pixels[offset])
        let g = Int(pixels[offset + 1])
        let b = Int(pixels[offset + 2])
        // 近白：三个通道都很亮，且彼此接近（排除图标里的浅色高光）
        // 阈值放宽到 236：JPEG 在边缘有一两行半透明白的过渡像素，
        // 只按 246 判会把它们当成内容，成品顶上就留一道白线
        let isWhite = r >= 236 && g >= 236 && b >= 236
        if !isWhite {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
}
guard maxX > minX, maxY > minY else {
    print("整张图都是白的？")
    exit(1)
}
// CGContext 的 y 轴是自下而上，转回图像坐标
// 往里收一点：源图圆角外侧有一圈抗锯齿白边，不裁掉的话成品会留白边
let rawWidth = maxX - minX + 1
let rawHeight = maxY - minY + 1
let inset = max(2, Int(Double(min(rawWidth, rawHeight)) * 0.012))
let box = CGRect(x: minX + inset,
                 y: height - maxY - 1 + inset,
                 width: rawWidth - inset * 2,
                 height: rawHeight - inset * 2)
print("内容包围盒 \(Int(box.width))x\(Int(box.height)) @ (\(Int(box.minX)),\(Int(box.minY)))")

guard let cropped = cgSource.cropping(to: box) else { exit(1) }

// MARK: 画到 macOS 图标网格

let canvas = 1024
let content = Int(Double(canvas) * contentRatio)
let origin = (canvas - content) / 2
let radius = CGFloat(content) * 0.2237

guard let context = CGContext(data: nil,
                              width: canvas,
                              height: canvas,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}
context.interpolationQuality = .high

// 圆角裁剪（Apple 的 squircle 用连续曲率，这里用普通圆角，肉眼差别很小）
let rect = CGRect(x: origin, y: origin, width: content, height: content)
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
context.addPath(path)
context.clip()
context.draw(cropped, in: rect)

guard let icon = context.makeImage() else { exit(1) }

// MARK: 生成 iconset

let fileManager = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fileManager.removeItem(at: iconset)
try! fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("icon-master-1024.png")
let rep = NSBitmapImageRep(cgImage: icon)
try! rep.representation(using: .png, properties: [:])!.write(to: master)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, size) in variants {
    let target = iconset.appendingPathComponent("\(name).png")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    task.arguments = ["-z", "\(size)", "\(size)", master.path, "--out", target.path]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try! task.run()
    task.waitUntilExit()
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try! iconutil.run()
iconutil.waitUntilExit()

let size = (try? fileManager.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
print("✅ \(outputPath) \(size ?? 0) bytes")
