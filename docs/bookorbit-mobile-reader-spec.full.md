# 双端基础阅读器 + BookOrbit 完整实施规格

## 一、产品定义

开发两个原生客户端：

- Android：Kotlin + Jetpack Compose，支持普通屏幕与水墨黑白模式。
- iOS：Swift + SwiftUI，支持普通屏幕模式。
- 共享格式核心：Rust/C + UniFFI，负责格式识别、哈希、MOBI/FB2 转换和漫画压缩包解析。
- Kindle 青春版仅作为 6 英寸、600×800、16 灰阶的版式测试基准，不作为安装目标。
- Android 最低 API 23、目标 API 36；iOS 最低 15。
- 单个 BookOrbit 服务器账号。
- Wi-Fi 传入的书只进入本地书库，不自动上传 BookOrbit。
- BookOrbit 只负责远端文件列表、文件下载和阅读进度同步。
- 客户端开源，建议 Apache-2.0；不复制 BookOrbit UI、TypeScript、图标或品牌资源。

### 1.1 阅读格式

支持无 DRM 文件：

| 类型 | 格式 | 实现 |
|---|---|---|
| 电子书 | EPUB、KEPUB | Readium 原生打开 |
| Kindle 文本书 | MOBI、AZW、AZW3 | libmobi 解析后生成内部 EPUB |
| FictionBook | FB2 | 共享核心转换为内部 EPUB |
| 文档 | PDF | Android Readium/PDFium；iOS Readium PDF |
| 漫画 | CBZ | Readium/原生漫画阅读器 |
| 漫画 | CBR、CB7 | libarchive 解包后交给原生漫画阅读器 |
| 有声书 | M4B、M4A、MP3、OPUS、OGG、FLAC | Android Media3、iOS AVFoundation；不支持的编码由 LibVLC 补充 |

加密 EPUB、加密 MOBI/AZW、Adobe DRM 和 Kindle DRM 明确不支持。

### 1.2 基础阅读功能

电子书：

- 本地打开、分页/滚动切换。
- 目录跳转。
- 点击区域翻页。
- 字号、字体、行距、段距、页边距和背景设置。
- 自动保存位置。
- 不实现搜索、高亮、笔记、字典、翻译和 TTS。

PDF：

- 单页阅读、连续阅读、适合页面、适合宽度。
- 缩放、拖动、旋转、页码跳转。
- 保存页码和缩放模式。

漫画：

- 单页阅读、左右阅读方向。
- 缩放、拖动、适合宽度/页面。
- 保存当前页码。
- 5～6 英寸设备默认单页模式。

音频按完整播放器实现：

- 本地播放与 BookOrbit 在线 Range 流播放。
- 多轨书籍、章节目录、自动切换下一轨。
- 播放/暂停、拖动、前后跳转、倍速。
- 睡眠定时器。
- 后台播放、锁屏控制、耳机和蓝牙按键。
- 电话、闹钟、耳机断开等中断处理。
- Android MediaSession、iOS Now Playing。
- 每 5 秒、暂停、切轨、进入后台时保存 `currentFileId` 和 `positionSeconds`。
- 强制退出、重启设备后恢复到上次播放轨道和秒数。

## 二、客户端架构

### 2.1 本地数据层

Android 使用 Room，iOS 使用 GRDB/SQLite，保存：

- `Publication`：本地出版物及元数据。
- `RemoteBook`：BookOrbit 书籍缓存。
- `RemoteFile`：BookOrbit 文件记录。
- `DownloadTask`：下载偏移、总大小、状态和错误。
- `ReadingProgress`：本地位置、远端位置、同步状态。
- `AudioProgress`：轨道、秒数、播放速度和睡眠设置。
- `SyncOutbox`：待上传进度。
- `ServerProfile`：唯一 BookOrbit 实例和账号。

文件以 SHA-256 内容哈希存放，同一个文件只保存一份。BookOrbit 下载记录和本地书籍分别引用该文件。

删除 BookOrbit 下载只删除本地副本，不删除服务器文件。断开服务器不会影响已经下载的书和 Wi-Fi 导入书。

### 2.2 显示模式

Android 提供手动切换，不通过品牌或型号字符串做自动映射。

水墨模式：

- 纯黑白界面，封面生成灰阶/二值化缓存。
- 禁止动画、Ripple、阴影、透明渐变和平滑滚动。
- 书库使用单列紧凑列表。
- 阅读器优先整页点击翻页。
- 菜单只重绘必要区域。
- 通用 Android 绘制不承诺控制面板波形；具体厂商快刷接口留独立适配器，本期不做型号兼容映射。

普通模式：

- 彩色封面和常规主题。
- 允许滑动、滚动和短过渡动画。
- 与水墨模式使用相同业务功能和数据。

测试尺寸：

- 5 英寸长屏 Android：360×720dp 级别。
- 6 英寸阅读器基准：600×800px、3:4。
- 普通 Android 手机和 iPhone SE 尺寸。
- 所有 Compact 宽度采用单栏布局。

## 三、BookOrbit 集成

### 3.1 兼容范围

初始严格支持 BookOrbit `v2.5.0`：

- 使用 `GET /api/v1/app-info` 检测版本。
- 只启用明确通过契约测试的服务器版本。
- 不添加字段别名、备用 key、端点回退或版本兼容映射。
- 不支持的版本仅停用远端功能，本地阅读和 Wi-Fi 传书继续可用。

### 3.2 登录

使用普通 BookOrbit 账号：

- `POST /api/v1/auth/login`
- `POST /api/v1/auth/refresh`
- `GET /api/v1/auth/me`

访问令牌用于 Bearer Authorization；refresh cookie 由持久 CookieStore 管理。凭据和 Cookie 存放在 Android Keystore/iOS Keychain。

默认要求 HTTPS。局域网 HTTP 必须由用户对当前主机显式启用。自签证书不允许直接忽略错误，只允许用户确认并保存证书 SHA-256 指纹。

### 3.3 文件列表与下载

- `POST /api/v1/books/query`：分页获取书籍。
- `GET /api/v1/books/:id`：获取文件、格式、文件名和音频轨道。
- 使用封面接口缓存封面。
- `GET /api/v1/books/files/:fileId/serve`：使用 HTTP Range 下载或音频流播放。
- 下载写入 `.part` 临时文件，完成后校验长度、计算 SHA-256，再原子移动。
- 服务器忽略 Range 并返回 `200` 时，清空部分文件后重新下载。
- 支持暂停、继续、失败重试、仅 Wi-Fi 下载和存储空间预检。

### 3.4 阅读进度

普通文件：

- `GET /api/v1/books/files/:fileId/progress`
- `POST /api/v1/books/files/:fileId/progress`
- 请求字段严格使用 `percentage`、`cfi`、`pageNumber`、`positionSeconds` 等现有名称。

有声书：

- `GET /api/v1/books/:bookId/audio-progress`
- `PATCH /api/v1/books/:bookId/audio-progress`
- 请求严格使用 `percentage`、`currentFileId`、`positionSeconds`。

同步精度：

- EPUB：同步百分比和 CFI。
- PDF、CBZ、CBR、CB7：同步百分比和页码。
- 音频：同步轨道文件 ID、百分比和秒数。
- MOBI、AZW、AZW3、FB2：本机精确恢复，BookOrbit 跨引擎只同步百分比。
- Wi-Fi 导入的本地书不上传任何 BookOrbit 进度。

同步时序：

1. 打开书籍前拉取远端进度。
2. 翻页或播放时立即保存本地数据库。
3. 阅读中合并上传，退出阅读和进入后台时再上传。
4. 断网时写入 `SyncOutbox`。
5. 恢复网络后由 WorkManager/BGTask 补传。
6. 上传前再次拉取；如果远端在本地上次拉取后发生变化，显示本地/服务器进度选择。
7. 上传后再次读取验证。

现有 BookOrbit 进度接口没有条件更新能力，因此无法完全消除两台设备同时写入的竞争；该限制必须在兼容说明中明确。

## 四、Wi-Fi 传书

Android 和 iOS 都能作为接收端。用户进入“Wi-Fi 传书”页面后：

1. App 启动仅监听局域网的临时 HTTP 服务。
2. 显示本机地址、mDNS 名称和二维码。
3. iPhone、Android、电脑通过浏览器扫码打开上传页。
4. 支持拖拽、文件选择、批量队列、进度和断点续传。
5. 文件完成后进入本地书库，不调用 BookOrbit 上传接口。
6. 离开传输页面后关闭服务。

iOS 和 Android 均以前台传输为准，传输页面保持屏幕唤醒。iOS 申请 Local Network 权限，不承诺 App 进入后台后继续接收。

### 4.1 局域网上传协议

- `GET /`：内置上传页面。
- `POST /api/uploads`：创建上传，精确请求字段为 `fileName`、`sizeBytes`。
- `GET /api/uploads/:uploadId`：获取续传状态。
- `PUT /api/uploads/:uploadId/chunks/:chunkIndex`：上传 8 MiB 分块，携带 `Content-Range`。
- `POST /api/uploads/:uploadId/complete`：完成、计算 SHA-256、导入书库。
- `DELETE /api/uploads/:uploadId`：取消并清理临时文件。

安全规则：

- 二维码使用 128 位随机会话令牌。
- 令牌放在 URL Fragment，由网页通过 `Authorization: Bearer` 发送，不进入 HTTP 日志。
- API 不接受无令牌请求。
- 服务只绑定局域网接口，不映射公网端口。
- 文件名去除路径、控制字符和保留字符。
- 数据直接流式写盘，不整文件进入内存。
- 检查剩余空间、压缩包条目数量、解压尺寸和路径穿越。
- 相同 SHA-256 文件判定为重复，不重复占用存储。
- 未完成分块保留 24 小时，然后自动清理。

## 五、实施顺序与验收

### 5.1 实施阶段

1. 建立 Android、iOS、共享格式核心和双端 CI；固定 BookOrbit v2.5.0 契约。
2. 完成本地数据库、内容寻址存储、系统文件导入和 Wi-Fi 分块传书。
3. 完成 EPUB/KEPUB、MOBI/AZW、FB2、PDF、CBZ/CBR/CB7 阅读引擎。
4. 完成全格式音频播放器、后台播放和精确断点恢复。
5. 完成 BookOrbit 登录、书库列表、封面、Range 下载和进度同步。
6. 完成 Android 水墨模式、600×800 基准适配和双端发布加固。

### 5.2 必须通过的测试

- 每种声明格式至少准备正常、损坏、超大和特殊字符文件。
- MOBI/AZW/FB2 转换结果在 Android、iOS 上目录、图片和分页一致。
- PDF、漫画大文件不得整包加载内存。
- Wi-Fi 上传支持手机 Safari、Chrome 和桌面浏览器；中断后可续传。
- 无令牌、错误令牌、路径穿越、压缩炸弹和磁盘不足必须安全失败。
- BookOrbit 登录过期可刷新；401、403、404、Range 失效和网络切换可恢复。
- EPUB CFI、PDF/漫画页码、音频轨道和秒数在双设备间正确恢复。
- 音频在锁屏、蓝牙切换、电话中断、强制退出和重启后保存位置。
- Android 水墨模式无动画、渐变、Ripple 和持续滚动。
- 600×800、5 英寸长屏、普通 Android 和 iPhone 小屏无内容截断。
- BookOrbit 不可用时，本地阅读、Wi-Fi 导入和本地进度完全可用。
- Wi-Fi 导入书不得出现在 BookOrbit 服务端。
- BookOrbit v2.5.0 之外的未认证版本不得静默兼容或映射字段。

### 5.3 明确不包含

- 在 Kindle 真机安装。
- DRM 破解或受保护 Kindle 文件。
- BookOrbit 文件上传。
- 多 BookOrbit 实例。
- 书签、高亮、笔记、阅读统计和设置的远端同步。
- 字典、翻译、全文搜索和 TTS。
- 特定水墨厂商刷新 SDK。
- 复制或内置 BookOrbit Web UI。

应用源码采用 Apache-2.0；Readium、libarchive、libmobi、UniFFI、LibVLC 等依各自许可证保留源码、NOTICE 和可重链接材料。BookOrbit AGPL 服务端不打包进客户端，应用名称和图标使用独立品牌。

## 六、参考实现依据

- BookOrbit 项目：<https://github.com/bookorbit/bookorbit>
- BookOrbit v2.5.0：<https://github.com/bookorbit/bookorbit/releases/tag/v2.5.0>
- Readium Kotlin：<https://readium.org/kotlin-toolkit/latest/>
- Readium Swift：<https://github.com/readium/swift-toolkit>
- libmobi：<https://github.com/bfabiszewski/libmobi>
- libarchive：<https://github.com/libarchive/libarchive>
- UniFFI：<https://github.com/mozilla/uniffi-rs>
