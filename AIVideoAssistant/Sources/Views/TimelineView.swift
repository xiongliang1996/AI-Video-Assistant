//
//  TimelineView.swift
//  多轨时间线
//

import SwiftUI

struct TimelineView: View {
    @EnvironmentObject var appState: AppState

    private let pps: CGFloat = 26
    private let trackHeight: CGFloat = 46
    private let headWidth: CGFloat = 78

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                trackHeads
                Rectangle().fill(Theme.line).frame(width: 1)
                ScrollView(.horizontal, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            RulerView(pps: pps, seconds: 44)
                                .frame(height: 22)
                            track(for: appState.videoClips)
                            track(for: appState.audioClips)
                            track(for: appState.subtitleClips)
                        }
                        playhead
                    }
                    .frame(width: max(900, CGFloat(appState.totalDuration + 12) * pps), alignment: .topLeading)
                }
            }
        }
        .frame(height: 238)
        .background(Theme.panel2)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 3) {
            Text("时间线")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .padding(.trailing, 6)

            Button {} label: { Image(systemName: "cursorarrow") }
                .buttonStyle(IconButtonStyle(active: true, size: 24))
                .help("选择")

            Button {} label: { Image(systemName: "scissors") }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("切割")

            Button {} label: { Image(systemName: "plus") }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("添加标记")

            Rectangle().fill(Theme.line2).frame(width: 1, height: 14)

            Button {
                appState.removeSelectedItem()
            } label: { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("删除所选")

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.text3)
                Capsule().fill(Color.black.opacity(0.12)).frame(width: 56, height: 3)
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private var trackHeads: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 22)
            head("V1", "视频")
            head("A1", "音频")
            head("S1", "字幕")
        }
        .frame(width: headWidth)
    }

    private func head(_ code: String, _ name: String) -> some View {
        HStack(spacing: 5) {
            Text(code)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.06)))
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(Theme.text3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: trackHeight)
    }

    private func track(for items: [TimelineItem]) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.clear)
                .frame(height: trackHeight)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 1)
                }

            ForEach(items) { item in
                ClipView(item: item,
                         width: max(28, CGFloat(item.duration) * pps),
                         selected: appState.selectedItemID == item.id)
                    .offset(x: CGFloat(item.startTime) * pps)
                    .onTapGesture {
                        appState.selectedItemID = item.id
                    }
            }
        }
        .frame(height: trackHeight)
    }

    private var playhead: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 8))
                .foregroundStyle(Color(hex: 0xFF3B30))
                .offset(y: -1)
            Rectangle()
                .fill(Color(hex: 0xFF3B30))
                .frame(width: 1.5)
        }
        .frame(maxHeight: .infinity)
        .offset(x: CGFloat(appState.currentTime) * pps - 4)
        .allowsHitTesting(false)
    }
}

// MARK: - 标尺

struct RulerView: View {
    let pps: CGFloat
    let seconds: Int

    var body: some View {
        Canvas { context, size in
            for second in 0...seconds {
                let x = CGFloat(second) * pps
                guard x <= size.width else { break }
                let major = second % 5 == 0
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: major ? 12 : 6))
                context.stroke(path,
                               with: .color(major ? Color.black.opacity(0.2) : Color.black.opacity(0.1)),
                               lineWidth: 1)
                if major {
                    context.draw(
                        Text("\(second)s")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.text3),
                        at: CGPoint(x: x + 3, y: 4),
                        anchor: .topLeading
                    )
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

// MARK: - 片段

struct ClipView: View {
    let item: TimelineItem
    let width: CGFloat
    let selected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: item.type.icon)
                .font(.system(size: 9, weight: .medium))
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(width: width, height: 36, alignment: .leading)
        .background(Theme.clipGradient(for: item.type))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(selected ? Theme.accent : Color.white.opacity(0.45),
                        lineWidth: selected ? 2 : 1)
        )
        .shadow(color: .black.opacity(selected ? 0.2 : 0.1), radius: selected ? 5 : 2, y: 1)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}
