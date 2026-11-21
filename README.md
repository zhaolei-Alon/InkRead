# 墨读 InkRead

一款原生 iOS 本地小说阅读器。SwiftUI + UIKit/CoreText 混合实现，支持多格式导入、精细化排版、四种翻页交互，**零第三方依赖**。

A native iOS reader for local novels — SwiftUI + CoreText, no third-party dependencies.

![Platform](https://img.shields.io/badge/iOS-18.6%2B-black)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen)
![License](https://img.shields.io/badge/license-MIT-blue)

---

## 功能

### 阅读与翻页
- 点击屏幕左侧 / 右侧翻页，点击中部呼出菜单
- 按住上下拖动翻页，带阻尼回弹
- 支持仿真（覆盖）、平移、上下滚动等翻页方式，可切换
- 章节级目录跳转、阅读进度滑杆跳转任意位置

### 排版
- 字体（系统字体与中文字体族）、字号、行间距、段间距、首行缩进
- 页边距 / 单行文字宽度可调
- 5 套主题配色 + 自定义背景色，支持系统深浅色
- 屏幕亮度独立调节，退出阅读自动还原
- **3 套标准排版预设**，一键切换，也可自由微调

### 导入与书库
- 支持 **TXT / Markdown / HTML / RTF / EPUB**
- 自动编码探测：UTF-8（含 BOM）、UTF-16、GB18030、Big5、Shift_JIS、EUC-JP、EUC-KR、CP1252、CP1251
- 自动识别章节标题（中文「第 X 章」、英文 Chapter），识别失败时按长度分节
- 支持从「文件」App、其他 App 分享导入，多选批量导入
- 书架网格、封面渐变、阅读进度条、继续阅读卡片、删除确认

### 阅读状态
- 阅读进度自动保存（防抖落盘），切换 App 后台立即保存
- 书签增删与书签列表，可跨章节定位
- 自定义状态栏：实时时间、网络状态（WiFi / 蜂窝 / 离线）、电池电量，不占用系统状态栏
- 分页结果磁盘缓存，二次打开无需重新排版

### 性能与省电
- CoreText 直接绘制到 `CALayer`，每页一次绘制并缓存
- 翻页动画只做 GPU 层位移，不重排文字
- 分页签名（字体/字号/行距/页边距/尺寸）命中即复用，排版只在必要时触发
- 无网络请求、无第三方 SDK、无后台任务

---

## 运行

### 环境要求
| 项目 | 版本 |
|---|---|
| Xcode | 16 及以上（开发使用 26.3） |
| iOS 部署目标 | 18.6 |
| Swift | 5 |
| 第三方依赖 | 无（无需 CocoaPods / SPM） |

### 步骤

```bash
git clone https://github.com/zhaolei-Alon/InkRead.git
cd InkRead
open InkRead.xcodeproj
```

1. 选中 `InkRead` target → **Signing & Capabilities**
2. 勾选 *Automatically manage signing*，选择你的 Team（免费 Apple ID 会显示 Personal Team）
3. 如需真机安装，把 Bundle Identifier 改为全局唯一值（如 `com.yourname.inkread`）
4. 选择模拟器或已连接的真机，`⌘R` 运行

### 真机测试（不上架）

| 方式 | 前提 | 有效期 |
|---|---|---|
| 免费 Apple ID 直装 | Xcode 登录任意 Apple ID，手机开启「开发者模式」 | 7 天，重装续期 |
| TestFlight | Apple Developer Program（$99/年） | 每个构建 90 天 |
| Ad Hoc | 付费账号 + 登记设备 UDID | 1 年，最多 100 台 |

首次安装后若提示「未受信任的开发者」，到 *设置 → 通用 → VPN 与设备管理* 中信任对应证书。

> 部署目标为 iOS 18.6，测试机系统需不低于该版本。若需兼容更低版本，可在 Build Settings 中下调 `IPHONEOS_DEPLOYMENT_TARGET` 后重新验证。

---

## 目录结构

```
InkRead/
├── InkRead.xcodeproj/                Xcode 工程（target: InkRead）
├── Info.plist                        显示名、文件共享、文档类型、启动屏
├── README.md
├── LICENSE
├── docs/
│   ├── 项目结构说明.md                逐文件职责、分层依赖、核心调用链
│   └── CHANGELOG.md                   版本更新日志
└── InkRead/                          源码根
    ├── InkReadApp.swift              入口：创建并注入三个全局 Store
    ├── Assets.xcassets/              图标、强调色、启动背景
    ├── Resources/                    首次启动入库的示例书
    │   ├── Sample_StarSea.txt
    │   └── Sample_Lantern.epub
    ├── Models/                       模型层（纯数据结构，无 UI、无 IO）
    │   ├── Book.swift                书、章节、进度、书签、导入草稿
    │   └── ReaderTheme.swift         主题、字体、排版、翻页方式、设置存储
    ├── Services/                     服务层
    │   ├── AppPaths.swift            沙盒路径 + JSON 编解码器
    │   ├── LibraryStore.swift        书架仓库：增删、缓存、进度落盘
    │   ├── BookmarkStore.swift       书签仓库
    │   ├── TextProcessing.swift      编码探测、文本清洗、HTML/Markdown 转换
    │   ├── ChapterSplitter.swift     章节标题识别与切分
    │   ├── BookImporter.swift        导入调度：按扩展名分派
    │   ├── EPUBImporter.swift        EPUB 解析：container → OPF → spine
    │   ├── ZipReader.swift           自写 ZIP 解析（中央目录 + zlib inflate）
    │   ├── PaginationEngine.swift    CoreText 分页引擎 + 分页缓存模型
    │   └── NetworkMonitor.swift      网络类型监听（NWPathMonitor）
    ├── Reader/                       阅读页
    │   ├── ReaderView.swift          页面骨架、自定义状态栏、弹层挂载
    │   ├── ReaderViewModel.swift     阅读状态机：章节/页码/排版/进度/书签/亮度
    │   ├── PagePagerView.swift       UIKit 翻页容器：绘制 + 手势 + 动画
    │   ├── ReaderChrome.swift        顶栏、底栏、进度滑杆
    │   └── ReaderSheets.swift        排版设置、目录、书签三个弹层
    └── Library/
        └── LibraryView.swift         书架页
```

分层依赖单向：**表现层 → 状态层 → 服务层 → 模型层**。完整说明见 [docs/项目结构说明.md](docs/项目结构说明.md)。

---

## 实现要点

### CoreText 分页
`PaginationEngine` 用 `CTFramesetterCreateFrame` 生成帧，再用 `CTFrameGetVisibleStringRange` 取得该帧实际容纳的 UTF-16 区间，循环推进得到每页 `PageSlice(start, length)`。列区间落盘为 `layout.json`，签名 `字体|字号|行距|段距|页边距|缩进|宽x高` 任一变化才重新分页。

### 翻页
`PageCanvasView` 把当前页与下一页各自绘制进独立 `CALayer`，`PagePagerView` 只做 transform 动画。手势区域按屏宽比例划分：左翻 28% / 右侧 28% / 上一页 22% / 下一页 18%；拖动超过 8pt 锁定轴向，避免误触。

### 主题与背景
正文底色由两层叠加：SwiftUI 侧 `ReaderView` 底层的 `theme.background.color`，与 UIKit 侧 `PagePagerView.backgroundColor`（在 `apply(_:)` 中同步）。`PageCanvasView` 始终保持透明（`isOpaque = false`、`backgroundColor = .clear`），仅用 CoreText 绘制文字——页视图一旦带不透明背景，翻页转正后会残留旧色，导致切换主题时正文背景不刷新。详见 [docs/项目结构说明.md](docs/项目结构说明.md)。

### EPUB
`ZipReader` 自行解析 EOCD 与中央目录，支持 stored / deflate（zlib raw inflate），拒绝 Zip64。`EPUBImporter` 依次解析 `container.xml`、OPF 清单、spine 顺序，再按 XML 名称空间提取章节文本，并以 OPF 所在目录为基准解析相对路径。

### 本地存储
```
Application Support/InkRead/
├── library.json                 书架索引
├── bookmarks.json               书签
└── Books/<uuid>/
    ├── content.txt              归一化后的正文
    ├── chapters.json            章节偏移
    └── layout.json              分页缓存
```
阅读设置存于 `UserDefaults`。

---

## 二次开发

| 想改什么 | 改哪里 |
|---|---|
| 配色、纸张背景、主题列表 | `Models/ReaderTheme.swift` |
| 默认字号、行距、页边距 | `Models/ReaderTheme.swift` 中的 `ReaderTypography` |
| 翻页手势、动画、点击区域 | `Reader/PagePagerView.swift` |
| 阅读流程（切章、进度、书签） | `Reader/ReaderViewModel.swift` |
| 分页算法 | `Services/PaginationEngine.swift` |
| 新增导入格式 | `Services/BookImporter.swift` + `TextProcessing.swift` |
| 章节识别规则 | `Services/ChapterSplitter.swift` |
| 书架 UI | `Library/LibraryView.swift` |
| 状态栏 / 页面骨架 | `Reader/ReaderView.swift` |
| 设置面板 | `Reader/ReaderSheets.swift` |

源码已逐行添加中文注释：每个文件头部注明职责、上层调用者与下层依赖，核心类型与函数有 `///` 文档注释，关键流程有分段说明。

---

## 已知限制

- EPUB 目前按纯文本渲染，图片、脚注、复杂 CSS 排版会被忽略
- 无云同步、书源、朗读、字体文件导入
- 仅面向 iPhone / iPad，未适配 macOS 与 Apple Watch

---

## 贡献

欢迎提交 Issue 与 Pull Request。提交前请确保：

1. 工程可编译（`⌘B` 无 error）
2. 保持现有分层与命名风格，新增代码补充中文注释
3. 一个 PR 只解决一个问题

---

## 许可证

[MIT](LICENSE) © 2026 Alon ([zhaolei-Alon](https://github.com/zhaolei-Alon))

示例书籍为项目自建测试内容，可自由使用。
