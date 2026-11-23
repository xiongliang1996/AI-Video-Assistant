# AI 视频助手

> macOS 原生 AI 视频创作工具 · Swift + SwiftUI + AVFoundation

[![Build macOS App](https://github.com/xiongliang1996/AI-Video-Assistant/actions/workflows/build.yml/badge.svg)](https://github.com/xiongliang1996/AI-Video-Assistant/actions/workflows/build.yml)

用一句话描述，让 AI 帮你把片子做出来。

---

## 功能

### 创作
- **AI 生视频** — 输入文字描述，调用 OpenAI 图像模型生成画面素材，风格 / 镜头运动可选
- **AI 配音** — 三引擎 TTS（OpenAI / Azure / 讯飞），多音色、可调语速
- **AI 字幕** — Whisper 自动识别语音生成 SRT，支持逐条校对与样式预览

### 编辑
- 多轨时间线（V1 视频 / A1 音频 / S1 字幕）
- 片段属性：缩放、旋转、不透明度、音量、变速
- 转场与滤镜槽位
- AVFoundation 硬件编码导出（H.264 / ProRes，720p–4K）

### 体验
- 全原生 SwiftUI 界面，深浅色自适应
- API Key 存入系统钥匙串，不明文落盘
- 素材导入即生成缩略图与时长信息

---

## 界面

`Design/ui-prototype.html` 是可点击的高保真交互原型，用浏览器直接打开即可体验五个核心界面的交互流程。

---

## 安装

### 方式一：下载构建产物

1. 打开 [Actions](https://github.com/xiongliang1996/AI-Video-Assistant/actions/workflows/build.yml) 页面，进入最近一次成功的构建
2. 在页面底部 **Artifacts** 下载 `AIVideoAssistant-macOS`
3. 解压后把 `AI视频助手.app` 拖进「应用程序」

> 应用为 ad-hoc 签名，首次打开需右键 → 打开，或在「系统设置 → 隐私与安全性」中允许。

### 方式二：从源码构建

```bash
git clone https://github.com/xiongliang1996/AI-Video-Assistant.git
cd AI-Video-Assistant/AIVideoAssistant
./scripts/build-app.sh release
open dist/AI视频助手.app
```

环境要求：macOS 13+、Swift 5.9+（Xcode 或 Command Line Tools）

---

## 配置 AI

启动后按 `⌘,` 打开设置：

| 能力 | 需要的凭证 |
|------|-----------|
| AI 生视频 / 字幕识别 / OpenAI 配音 | OpenAI API Key |
| Azure 配音 | Azure Speech Key + 区域 |
| 讯飞配音 | AppID + APIKey + APISecret |

凭证保存在 macOS 钥匙串，卸载应用前可用设置页的「测试连接」验证可用性。

---

## 快捷键

| 快捷键 | 功能 |
|--------|------|
| `⌘ N` | 新建项目 |
| `⌘ I` | 导入素材 |
| `⌘ E` | 导出视频 |
| `⌘ G` | AI 生视频 |
| `⌘ T` | AI 配音 |
| `⌘ S` | AI 字幕 |
| `⌘ ,` | 设置 |

---

## 项目结构

```
.
├── .github/workflows/build.yml     # CI：编译 → 打包 .app → 上传产物 / 发布 Release
├── Design/ui-prototype.html        # 可点击交互原型
└── AIVideoAssistant/
    ├── Package.swift               # SwiftPM 清单
    ├── scripts/build-app.sh        # 本地打包脚本
    ├── Support/Info.plist
    └── Sources/
        ├── App/                    # 入口 + 全局状态
        ├── Models/                 # 数据模型
        ├── Services/
        │   ├── AI/                 # OpenAI / TTS / 配置管理
        │   └── Video/              # 合成引擎 / 导出管线
        └── Views/                  # 设计系统 + 五个界面
```

### 架构

- **MVVM**：`AppState` 作为单一数据源，视图层只读状态、回调改状态
- **服务层抽象**：`VideoGeneratingService` 协议隔离不同 AI 供应商
- **编辑引擎**：`VideoEditor` 负责 AVFoundation 合成，`VideoExporter` 负责编码与进度

---

## 路线图

- [x] 项目骨架与设计系统
- [x] 视频合成 / 裁剪 / 拼接 / 变速 / 音频提取
- [x] OpenAI 图像生成 + Whisper 字幕 + 多引擎 TTS
- [x] 五界面 UI 与交互
- [x] GitHub Actions 自动构建 .app
- [ ] 转场效果实现（当前为属性槽位）
- [ ] 时间线拖拽调整片段位置
- [ ] 真实波形绘制（读取音频采样）
- [ ] Sora 视频生成接入（等待 API 开放）
- [ ] 项目文件持久化（.aiva 格式）

---

## License

个人项目，仅供自用与学习。
