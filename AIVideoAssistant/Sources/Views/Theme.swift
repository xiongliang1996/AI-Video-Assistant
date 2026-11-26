//
//  Theme.swift
//  设计系统：颜色 / 字体 / 通用组件
//

import SwiftUI

// MARK: - 颜色

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    init(hue: Double, saturation: Double = 0.72, brightness: Double = 0.92) {
        self.init(hue: hue / 360.0, saturation: saturation, brightness: brightness, opacity: 1.0)
    }
}

enum Theme {
    static let accent = Color(hex: 0x635BFF)
    static let accent2 = Color(hex: 0xA855F7)
    static let accentSoft = Color(hex: 0x635BFF, alpha: 0.09)

    static let bg = Color(hex: 0xF8F9FB)
    static let sidebar = Color(hex: 0xF3F4F8)
    static let panel = Color.white
    static let panel2 = Color(hex: 0xFAFBFD)
    static let canvas = Color(hex: 0xF2F3F7)

    static let line = Color.black.opacity(0.075)
    static let line2 = Color.black.opacity(0.13)

    static let text = Color(hex: 0x15161C)
    static let text2 = Color(hex: 0x6B6F7D)
    static let text3 = Color(hex: 0xA0A5B2)

    static let ok = Color(hex: 0x12B76A)
    static let warning = Color(hex: 0xF79009)
    static let danger = Color(hex: 0xF04438)

    static let brandGradient = LinearGradient(
        colors: [accent, accent2],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let stageGradient = LinearGradient(
        colors: [Color(hex: 0x141326), Color(hex: 0x1C1430), Color(hex: 0x2A1330)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // 缩略图配色
    static let thumbs: [LinearGradient] = [
        LinearGradient(colors: [Color(hex: 0x5B6CFF), Color(hex: 0xA06BFF), Color(hex: 0xFF8FB1)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: 0x0EA5E9), Color(hex: 0x22D3EE), Color(hex: 0xA7F3D0)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: 0xF59E0B), Color(hex: 0xF97316), Color(hex: 0xEF4444)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: 0x10B981), Color(hex: 0x34D399), Color(hex: 0xA3E635)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: 0x8B5CF6), Color(hex: 0xD946EF), Color(hex: 0xFB7185)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: 0x1E293B), Color(hex: 0x475569), Color(hex: 0x94A3B8)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: 0xEC4899), Color(hex: 0xF43F5E), Color(hex: 0xFBBF24)], startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(colors: [Color(hex: 0x0891B2), Color(hex: 0x2DD4BF), Color(hex: 0xBEF264)], startPoint: .topLeading, endPoint: .bottomTrailing)
    ]

    static func thumb(_ index: Int) -> LinearGradient {
        thumbs[abs(index) % thumbs.count]
    }

    static func thumb(for id: UUID) -> LinearGradient {
        thumb(id.uuidString.hashValue)
    }

    // 轨道片段配色
    static func clipGradient(for type: TimelineItemType) -> LinearGradient {
        switch type {
        case .video:
            return LinearGradient(colors: [Color(hex: 0x4F7CF7), Color(hex: 0x6F66FF)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .aiGenerated:
            return LinearGradient(colors: [Color(hex: 0x7C5CFF), Color(hex: 0xA855F7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .audio:
            return LinearGradient(colors: [Color(hex: 0x12B76A), Color(hex: 0x34D399)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .subtitle:
            return LinearGradient(colors: [Color(hex: 0xF59E0B), Color(hex: 0xFBBF24)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .text:
            return LinearGradient(colors: [Color(hex: 0xD946A6), Color(hex: 0xF472B6)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - 卡片容器

struct Card<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 1, x: 0, y: 1)
    }
}

// MARK: - 按钮样式

struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 29
    var fullWidth: Bool = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .padding(.horizontal, fullWidth ? 0 : 13)
            .background(Theme.brandGradient)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .shadow(color: Theme.accent.opacity(!isEnabled ? 0
                                              : (configuration.isPressed ? 0.18 : 0.3)),
                    radius: configuration.isPressed ? 4 : 10, x: 0, y: configuration.isPressed ? 1 : 4)
            .opacity(!isEnabled ? 0.42 : (configuration.isPressed ? 0.9 : 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SoftButtonStyle: ButtonStyle {
    var height: CGFloat = 29
    var fullWidth: Bool = false
    var active: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(active ? Theme.accent : Theme.text)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .padding(.horizontal, 11)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Theme.accentSoft : Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(active ? Theme.accent.opacity(0.25) : Theme.line2, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct IconButtonStyle: ButtonStyle {
    var active: Bool = false
    var size: CGFloat = 29

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(active ? Theme.accent : Theme.text2)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Theme.accentSoft : (configuration.isPressed ? Color.black.opacity(0.06) : Color.clear))
            )
            .contentShape(Rectangle())
    }
}

// MARK: - 通用小组件

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.text3)
            .textCase(.uppercase)
            .kerning(0.4)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Chip: View {
    let text: String
    var icon: String? = nil
    var selected: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 10.5))
                }
                Text(text).font(.system(size: 11.5))
            }
            .foregroundStyle(selected ? Color.white : Theme.text2)
            .padding(.horizontal, 10)
            .frame(height: 25)
            .background(
                Capsule().fill(selected ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.panel))
            )
            .overlay(
                Capsule().stroke(selected ? Color.clear : Theme.line2, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct SegmentedControl<T: Hashable>: View {
    let options: [T]
    let title: (T) -> String
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 11, weight: selection == option ? .medium : .regular))
                        .foregroundStyle(selection == option ? Theme.text : Theme.text2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(selection == option ? Theme.panel : Color.clear)
                                .shadow(color: .black.opacity(selection == option ? 0.06 : 0), radius: 1, y: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.06))
        )
    }
}

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var display: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text2)
                .frame(width: 52, alignment: .leading)

            Slider(value: $value, in: range)
                .controlSize(.mini)
                .tint(Theme.accent)

            Text(display)
                .font(.system(size: 11, design: .default))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .frame(minWidth: 44)
                .padding(.vertical, 1)
                .padding(.horizontal, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.panel)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
                )
        }
        .frame(height: 27)
    }
}

struct FieldBox<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .font(.system(size: 11.5))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line2, lineWidth: 1))
            )
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = Theme.ok
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line2, lineWidth: 1))
        )
    }
}

struct EmptyHint: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.text3)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
