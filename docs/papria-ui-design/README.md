# Papria 双版本 UI 设计交付

本目录是 Papria 移动阅读器的视觉设计交付，不包含 Android 或 iOS 原生代码改动。

## 版本范围

| 设计版本 | 平台 | 参考逻辑尺寸 | 设计目标 |
| --- | --- | --- | --- |
| 正常版 Android | Android | 360 x 800 dp | 纸张书房感、高频操作效率、Material 导航习惯 |
| 正常版 iOS | iOS | 390 x 844 pt | 与 Android 共用视觉语言，保留 iOS 导航和安全区习惯 |
| 水墨屏版 | Android | 600 x 800 px | 黑白高对比、单列紧凑、低刷新和分页阅读优先 |

正常版共享四个一级入口：`书库`、`BookOrbit`、`传书`、`设置`。下载任务从 BookOrbit 的任务入口进入；同步冲突在设置的同步状态中处理。iOS 仅包含正常版，不包含水墨屏版实现要求。

## 文件索引

| 文件 | 用途 |
| --- | --- |
| `design-tokens.md` | 颜色、字体、间距、圆角、图标、状态和可访问性规范 |
| `interaction-spec.md` | 导航、加载、离线、下载、传书和冲突处理交互规范 |
| `screen-inventory.md` | 页面、组件、状态、平台和后续 PNG 对应清单 |
| `imagegen-prompts.md` | 高保真 PNG 的逐张生成提示词、尺寸和验收说明 |
| `*.png` | 生成完成后放置的高保真设计稿 |

## PNG 交付清单

正常版单屏稿：

| 文件名 | 画布像素 | 逻辑基准 | 页面 |
| --- | ---: | ---: | --- |
| `normal-library-android-360.png` | 1152 x 2560 | 360 x 800 dp | Android 书库与继续阅读 |
| `normal-library-ios-390.png` | 1152 x 2496 | 390 x 844 pt | iOS 书库与继续阅读 |
| `normal-bookorbit-detail.png` | 1152 x 2560 | 360 x 800 dp | 远程书籍详情、下载和任务状态 |
| `normal-reader-epub.png` | 1152 x 2560 | 360 x 800 dp | EPUB 阅读器与控制栏 |
| `normal-audio-player.png` | 1152 x 2560 | 360 x 800 dp | 音频阅读、倍速和睡眠计时 |
| `normal-transfer.png` | 1152 x 2560 | 360 x 800 dp | Wi-Fi 传书、二维码和上传完成 |
| `normal-settings-conflict.png` | 1152 x 2560 | 360 x 800 dp | 服务器、离线和同步冲突 |
| `normal-task-center.png` | 1152 x 2560 | 360 x 800 dp | 下载中、暂停、失败与重试 |
| `normal-overview.png` | 2048 x 1536 | 横向总览 | 正常版关键页面总览 |

水墨屏 Android 单屏稿：

| 文件名 | 画布像素 | 逻辑基准 | 页面 |
| --- | ---: | ---: | --- |
| `eink-library-600x800.png` | 1536 x 2048 | 600 x 800 px | 黑白书库和继续阅读 |
| `eink-bookorbit-detail-600x800.png` | 1536 x 2048 | 600 x 800 px | 远程书籍详情与下载状态 |
| `eink-reader-600x800.png` | 1536 x 2048 | 600 x 800 px | 默认分页阅读器 |
| `eink-transfer-600x800.png` | 1536 x 2048 | 600 x 800 px | QR 地址、上传进度和完成状态 |
| `eink-settings-conflict-600x800.png` | 1536 x 2048 | 600 x 800 px | 显示模式、离线与冲突选择 |
| `eink-task-center-600x800.png` | 1536 x 2048 | 600 x 800 px | 紧凑下载队列 |
| `eink-overview.png` | 2048 x 1536 | 横向总览 | 水墨屏关键页面总览 |
| `normal-vs-eink-comparison.png` | 2048 x 1536 | 横向对照 | 两种设计系统的组件和层级对照 |

## 使用方式

1. 以 `design-tokens.md` 的 token 名称和数值建立 Android Compose 与 iOS SwiftUI 的设计变量。
2. 以 `screen-inventory.md` 逐页对应现有功能，不新增未经规格确认的一级导航。
3. 正常版优先遵守平台原生导航：Android 使用底部导航和 Material 触控尺寸，iOS 使用安全区、Navigation Stack 和系统 Tab Bar。
4. 水墨屏版仅 Android 使用，必须关闭阴影、渐变、过渡动画和依赖颜色的状态表达。
5. 视觉稿完成后，将其作为层级、文案密度和状态布局依据；图中的书封为抽象原创占位封面，不能替换为受版权限制的真实封面。

## 生成状态

本目录中的 Markdown 规范、逐张 PNG 提示词与 17 张高保真 PNG 已生成完成。PNG 由内置图像生成工具产出后，已按本 README 的规定统一导出为目标尺寸。交付可作为 Android 正常版 / 水墨屏版以及 iOS 正常版的后续原生实现视觉依据；水墨屏版不包含 iOS 实现要求。
