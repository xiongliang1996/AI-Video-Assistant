//
//  OnboardingContent.swift
//  首次使用引导 / 空状态文案 / 隐私说明
//
//  文案和判定都放在这里，不塞进视图：
//  一来能写断言（哪一页少了一句话、什么时候该弹，都能测出来），
//  二来改文案不用碰布局代码。
//

import Foundation

// MARK: - 引导页

struct OnboardingPage: Identifiable, Equatable {
    let id: Int
    let icon: String
    let title: String
    let body: String
    let bullets: [String]
    /// 页脚那句小字。空着就留白，但每页给一句更划算——
    /// 引导页最容易犯的错是「看着空」而不是「说得少」
    let note: String
}

enum OnboardingContent {
    static let pages: [OnboardingPage] = [
        OnboardingPage(
            id: 0,
            icon: "sparkles",
            title: "欢迎使用 AI 视频助手",
            body: "一条时间线，把素材、配音、字幕和 AI 生成的画面拼成成片。剪辑、合成、导出全在本机完成。",
            bullets: [
                "拖入视频 / 音频 / 图片就能开始，不用先建项目",
                "字幕、AI 配音、AI 生图都在同一个窗口里",
                "导出 H.264 成片，或只导出混好的 M4A 音频"
            ],
            note: "首次启动已经放了一段示例时间线：片段是占位的，没有真实素材，可以直接拖动、裁剪、试转场，不会动到你的文件。"
        ),
        OnboardingPage(
            id: 1,
            icon: "rectangle.split.3x1",
            title: "四个区域就够了",
            body: "左边挑素材，中间看画面，下面排时间，右边调参数。",
            bullets: [
                "素材库：搜索、分组、拖进时间线",
                "预览台：画中画可以直接拖动、拖角缩放",
                "时间线：拖边缘裁剪，拖上边缘调淡入淡出",
                "属性面板：音量、关键帧、转场、字幕样式"
            ],
            note: "属性面板只在选中片段时出现；没选中就在预览台上点一下画面。"
        ),
        OnboardingPage(
            id: 2,
            icon: "command",
            title: "几个快捷键省一半时间",
            body: "常用的就这几个，其余的菜单里都能找到。",
            bullets: [
                "空格 播放 / 暂停　⌘I 导入素材　⌘E 导出",
                "⌘D 复制片段　⌘Z / ⇧⌘Z 撤销重做",
                "⌘= / ⌘- 缩放时间线　⌘⇧T 一键吸附转场"
            ],
            note: "菜单栏里还有「文件 / 编辑 / 显示 / AI / 帮助」，随时可以按 ⌘/ 重看这份引导。"
        )
    ]

    /// 引导页总数，视图的「1 / 3」和翻页边界都用它
    static var pageCount: Int { pages.count }

    /// 最后一页才有「开始创作」，前几页是「下一步」
    static func isLast(_ index: Int) -> Bool {
        index >= pageCount - 1
    }

    /// 把翻页夹在合法范围内（按住方向键连点也不会越界）
    static func clamp(_ index: Int) -> Int {
        min(max(0, index), max(0, pageCount - 1))
    }
}

// MARK: - 什么时候弹

enum OnboardingGate {
    /// 改版时把版本号 +1，老用户会再看一遍新引导
    static let currentVersion = 1
    static let defaultsKey = "onboarding.seenVersion"

    /// 没记录过（全新安装）或者记录的是旧版本，就该弹
    static func shouldPresent(stored: Int?) -> Bool {
        (stored ?? 0) < currentVersion
    }

    static func storedVersion(in defaults: UserDefaults = .standard) -> Int? {
        defaults.object(forKey: defaultsKey) as? Int
    }

    static func markSeen(in defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: defaultsKey)
    }

    /// 给「帮助 → 使用引导」用：手动重看不能改已读记录，
    /// 否则下次真升级时反而不弹了
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

// MARK: - 空时间线

/// 空时间线上写什么，取决于素材库有没有东西：
/// 素材库也空的时候说「先导入素材」，有素材了就说「拖到时间线上」——
/// 两句话指的不是同一个动作，混着写等于没说。
struct EmptyTimelineHint: Equatable {
    var title: String
    var subtitle: String
    /// 是否该提示「可以先放一段示例」
    var suggestsDemo: Bool

    static func make(mediaCount: Int) -> EmptyTimelineHint {
        if mediaCount == 0 {
            return EmptyTimelineHint(
                title: "时间线还是空的",
                subtitle: "先把视频或音频拖进左边的素材库，再拖到这条时间线上",
                suggestsDemo: true
            )
        }
        return EmptyTimelineHint(
            title: "时间线还是空的",
            subtitle: "从左边把素材拖到时间线上；不够就先按 ⌘I 再导一些",
            suggestsDemo: false
        )
    }
}

// MARK: - 隐私说明

struct PrivacySection: Identifiable, Equatable {
    var id: String { title }
    let icon: String
    let title: String
    let body: String
}

enum PrivacyContent {
    static let summary = "素材不上传，只有你主动用 AI 功能时才会联网。"

    static let sections: [PrivacySection] = [
        PrivacySection(
            icon: "lock.shield",
            title: "素材不离开这台电脑",
            body: "导入的文件只在本机解码、合成、导出。不上传、不做统计、不需要登录。"
        ),
        PrivacySection(
            icon: "sparkles",
            title: "只有用 AI 功能时才联网",
            body: "AI 生图把提示词发给 OpenAI；AI 配音把文本发给你所选的服务商（OpenAI / Azure / 讯飞）；Whisper 转写会把音频片段发出去。不用这些功能就完全不联网。"
        ),
        PrivacySection(
            icon: "key",
            title: "密钥存在系统钥匙串",
            body: "API Key 由 macOS 钥匙串保管，项目文件和日志里都不会出现明文。"
        ),
        PrivacySection(
            icon: "doc.text",
            title: "日志只写在本机",
            body: "~/Library/Logs/AIVideoAssistant/app.log 记录时间、操作和错误信息，会包含文件路径，但不包含素材内容。随时可以直接删掉。"
        )
    ]
}
