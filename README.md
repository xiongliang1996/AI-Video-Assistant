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
- 四轨时间线（V1 视频 / A1 音乐 / A2 配音 / S1 字幕），音频可上下拖动换层
- **时间线拖拽**：拖动片段改位置，拖两端裁剪，自动吸附到相邻片段边缘 / 播放头 / 0 点
- **素材拖入**：把素材面板里的文件直接拖到时间线任意轨道与落点，自动找最近的空位插入，同类轨道满了会顺延到下一层
- **真实波形**：读取音频采样（峰值 + RMS 混合）绘制包络，静音段与渐强段一眼可见；裁剪片段后包络跟着滑动，解码在后台线程并按文件缓存
- **多选批量操作**：`⌘` 点击增减选择、`⌘A` 全选，选中多个片段可整组拖动 / 一次性删除，属性面板显示片段数、时间跨度与总长
- **时间线缩略图**：视频片段按宽度平铺源文件画面（异步取帧、按「文件 + 时间」缓存），裁剪后缩略图跟着入点走
- **智能剪辑**：分析配音停顿（20 ms 窗口 RMS → dBFS，阈值 / 最短停顿 / 最短语句可调），可「按停顿切片」或「删除停顿并前移」——后者是波纹删除，视频 / 音乐 / 字幕一起前移，音画不脱轨
- **真实转场**：交叉溶解、黑场过渡、左滑推入、缩放推入，导出与预览同时生效
- **切割**：播放头处一键切开片段（`⌘` 工具栏剪刀按钮）
- 片段属性：缩放、旋转、不透明度、音量、变速、淡入淡出、源入点、所属轨道
- **关键帧动画**：缩放 / 不透明度 / 音量可打关键帧，线性补间，属性面板里有曲线预览（带播放头竖线），导出与预览走同一套 ramp
- **撤销 / 重做**：`⌘Z` / `⇧⌘Z`，拖拽与滑杆按操作合并成一步
- **项目持久化**：自动保存到 `~/Library/Application Support/AIVideoAssistant`，支持导出 `.aiva` 文件
- **字幕烧录**：字幕 / 文字真正画进画面（字号、颜色、底衬、距底位置、粗体），预览与成片同款样式
- AVFoundation 编码导出（H.264，720p–4K）；无字幕走硬件编码，有字幕走逐帧绘制
- **导出队列**：`⌘E` 入队、串行执行，排队期间可以继续剪；`⌘⇧E` 看进度、取消（取消会清掉写了一半的文件）、在访达里定位成品

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

1. 打开 [Releases](https://github.com/xiongliang1996/AI-Video-Assistant/releases/latest) 页面
2. 下载 `AIVideoAssistant-macOS.zip`，解压后把 `AI视频助手.app` 拖进「应用程序」

> **说明**：CI 目前使用 `macos-15-intel` 运行器（GitHub 的 arm64 macOS 运行器容量紧张，排队 15 分钟后会被取消），因此产物是 **x86_64 架构**。在 Apple Silicon 上运行需要 Rosetta 2（首次打开系统会提示安装）。
>
> 想要原生 arm64 版本，用下面的本地构建方式，或在 `.github/workflows/build.yml` 里把 `runs-on: macos-15-intel` 改回 `macos-latest`。

> 应用为 ad-hoc 签名，首次打开需右键 → 打开，或在「系统设置 → 隐私与安全性」中允许。

### 方式二：从源码构建（原生架构）

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
| `⌘ O` | 打开项目 |
| `⌘ S` | 保存项目 |
| `⌘ ⇧ S` | 导出项目副本 |
| `⌘ I` | 导入素材 |
| `⌘ E` | 导出视频（加入队列） |
| `⌘ ⇧ E` | 导出队列 |
| `⌘ Z` / `⇧ ⌘ Z` | 撤销 / 重做 |
| `⌘ A` / `⇧ ⌘ A` | 全选片段 / 取消选择 |
| `⌘ ⌫` | 删除所选片段 |
| `⌘ ⇧ K` | 智能剪辑（按停顿） |
| `⌘ G` | AI 生视频 |
| `⌘ T` | AI 配音 |
| `⌘ L` | AI 字幕 |
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
        ├── App/                    # 入口 + 全局状态（含预览与自动保存）
        ├── Models/                 # 数据模型（含转场 / 源入点 / 关键帧）
        ├── Services/
        │   ├── AI/                 # OpenAI / TTS / 配置管理
        │   ├── Audio/              # 波形分析 + 停顿检测（RMS → dBFS）
        │   ├── ProjectStore.swift  # 项目读写
        │   └── Video/              # CompositionBuilder / SubtitleRenderer / VideoExporter / ThumbnailStore / ExportQueue
        └── Views/                  # 设计系统 + 五个界面（含 WaveformView / SmartCutView / ClipThumbnailStrip）
```

### 架构

- **MVVM**：`AppState` 作为单一数据源，视图层只读状态、回调改状态
- **服务层抽象**：`VideoGeneratingService` 协议隔离不同 AI 供应商
- **合成引擎**：`CompositionBuilder` 把时间线编译成 A/B 双轨合成 + 视频合成指令（转场 / 变换 / 淡入淡出）
- **导出管线**：`VideoExporter` 负责编码与进度回传；预览复用同一套合成结果，保证「所见即所得」

### 转场是怎么实现的

时间线片段交替落在 A / B 两条视频轨道上。给片段设置转场时，前一个片段的素材**向后多取 t 秒**（需要素材本身还有余量，没有就自动缩短或跳过），后一个片段按自己的入点正常开始，于是两段在 `[后片入点, 后片入点 + t]` 区间重叠。合成指令在这个区间里同时挂上两条轨道的图层指令：

| 转场 | 实现 |
|------|------|
| 交叉溶解 | 前段不透明度 1→0，后段 0→1 |
| 黑场过渡 | 前半段前片淡出到黑，后半段后片从黑淡入 |
| 左滑推入 | 两段做平移变换 ramp |
| 缩放推入 | 后段 0.86→1.0 缩放 + 淡入 |

---

## 路线图

- [x] 项目骨架与设计系统
- [x] 视频合成 / 裁剪 / 拼接 / 变速 / 音频提取
- [x] OpenAI 图像生成 + Whisper 字幕 + 多引擎 TTS
- [x] 五界面 UI 与交互
- [x] GitHub Actions 自动构建 .app
- [x] 时间线拖拽调整片段位置与长度（含吸附）
- [x] 转场真实渲染（溶解 / 黑场 / 推入 / 缩放）
- [x] 项目文件持久化（自动保存 + `.aiva` 导出）
- [x] 真实时间线预览（预览走同一套合成管线）
- [x] 字幕 / 文字图层烧录进画面
- [x] 多音频轨道（音乐 / 配音分离，支持拖拽换层）
- [x] 撤销 / 重做
- [x] 真实波形绘制（读取音频采样，峰值 + RMS 包络）
- [x] 素材拖入时间线（自动找空位 / 落点顺延）
- [x] 多选与批量操作（整组拖动 / 批量删除 / 选中统计）
- [x] 智能剪辑（按语音停顿切片 / 波纹去停顿）
- [x] 时间线视频缩略图（异步取帧 + 时间点缓存）
- [x] 导出队列（串行执行 / 可取消 / 失败不留残片）
- [x] 关键帧动画（缩放 / 不透明度 / 音量 + 曲线预览）
- [ ] Sora 视频生成接入（等待 API 开放）

---

## License

个人项目，仅供自用与学习。
