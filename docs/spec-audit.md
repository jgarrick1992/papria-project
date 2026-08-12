# 规格逐项审计（2026-08-11）

## 审计基线与证据边界

本审计以仓库内快照 `docs/bookorbit-mobile-reader-spec.full.md` 为准；它是用户提供
规格的可复核副本，仅末尾换行不同。本仓库不公布原始输入的本机位置。

本文只记录可复核的事实，且不为变量或字典 key 增加兼容映射。结论分为三类：

- **已验证**：仓库中的脚本或 Rust 测试能够重复验证其声明的边界；这不等于真实设备或服务集成通过。
- **源码存在，尚非规格完成证据**：实现、CI 配置或默认构建路径存在，但尚未覆盖原始规格指定的验收场景，或尚未取得当前工作树的成功平台构建证据。
- **未完成／待外部验收**：必须继续实现，或必须由设备、服务、浏览器、GitHub/发布环境提供证据。

本轮 Android、iOS、CI 和合同修改已在当前工作树完成，并在下文列出对应验证。最终提交前仍应在干净 checkout 重跑同样门禁；真实设备、服务和发布环境证据不因本地构建通过而自动成立。

## 已验证的仓库边界（范围受限）

- 根目录已有 Android、iOS、共享 Rust 核心、合同、CI、`.gitignore`、许可证和 GitHub 模板等开发基线；`verify-repository.sh` 还检查 Action 固定、脚本语法和忽略产物。
- `./scripts/verify-contracts.sh`、`./scripts/verify-fixtures.sh` 和
  `bash scripts/verify-structure.sh` 验证严格合同、fixture manifest 和目录约束。fixture gate 现会生成并 byte-compare 16 种格式的许可明确合成 normal/malformed/special 文件、稀疏 64 MiB+1 大文件；Rust driver 对 normal/special 做识别、对可转换格式的 normal/malformed 做转换、对漫画 normal/malformed 做归档入口检查，并对 PDF/漫画大文件流式哈希。它不证明所有 large/special 文件均能转换或被平台阅读器打开，更不证明真实商业书籍兼容。
- Rust 核心的格式枚举、有限头部识别、流式 SHA-256、文件名/归档成员安全规则、FB2/MOBI 转内部 EPUB，以及 ZIP/RAR4/7z 有界漫画归档枚举，有仓库内测试证据。MOBI/AZW/AZW3 的生产转换路径现在通过 vendored libmobi v0.12 C shim；DRM 路径以拒绝为目标。以上不证明 16 种真实格式均可兼容。
- 两端工程中可见本地书库、下载、BookOrbit、Wi-Fi 传书、阅读器和音频的实现入口；CI 也配置了静态、Android、iOS 和默认 format-core 工作。配置存在不等于 GitHub 上已经运行、签名或产生可交付制品。

## 不满足原始规格的 P0 项目

| 规格要求 | 当前可复核事实 | 诚实结论与完成条件 |
| --- | --- | --- |
| 16 种格式均有正常、损坏、超大和特殊文件名的真实 fixture，并驱动双端阅读/转换验证 | 现在有 Apache-2.0 合成、可再生 corpus；Rust driver 对 normal/special 识别、normal/malformed 转换（限转换格式）、normal/malformed 漫画检查，及 PDF/漫画大文件流式哈希。 | **fixture 与部分共享核心边界已验证；** 不是 16 种 large/special 都完成转换/归档解析，更不是双端阅读、真实书籍、DRM、内存上限或设备兼容验收。 |
| 共享 Rust/C + UniFFI 核心负责漫画压缩包解析 | UDL 提供有界 `ArchiveByteSource` 与 `inspect_comic_archive`，Rust 解析 ZIP/RAR4/7z 容器元数据、路径、重复名、条目数和压缩组限制。Android 通过有界 `RandomAccessFile` callback 调用；iOS 通过生成 header 的有界 `FileHandle` callback 调用。平台仍负责受限图片解码和呈现。 | **共享枚举/安全边界有仓库测试，Android Debug/Release APK 和 iOS App 链接已验证；** 仍需实际设备运行 callback，并以真实 CBR/CB7/solid 7z 回归。 |
| 压缩炸弹在 CBZ/CBR/CB7 上安全失败 | 元数据校验对未知 member packed size 改为 fail-closed；7z 仅在共享核心从可信 packed stream group 推导压缩比时可通过。 | **共享核心边界已验证；** 仍需真实压缩/solid 7z/CB7、取消路径和设备内存验收。 |
| 共享格式核心是正式 Android/iOS 交付路径 | Android 的每个 `preBuild` 都运行 format-core 构建并加入生成 binding 与 ABI 库；iOS Xcode build phase 生成并直接链接 `PapriaFormatCore.xcframework`，Swift bridge 不再使用可选加载或 PalmDOC/FB2 fallback。生成产物仍被忽略，故每次构建都须重建。 | **默认/强制集成的源码路径已落地，Android Debug/Release APK 与 iOS App-only 链接均已验证。** 这些证据不等于真机安装、设备 callback 或签名发布。 |
| EPUB/KEPUB 用 Readium；Android PDF 用 Readium/PDFium，iOS PDF 用 Readium PDF；不支持的音频编码由 LibVLC 补充 | Android Readium Kotlin `3.1.2`/PDFium dependencies resolved from the local Gradle cache; Debug/Release APK, lint, R8, native-core and LibVLC package gates pass. iOS `Package.resolved` fixes Readium Swift Toolkit `3.8.0`; the MobileVLCKit `3.7.2` archive was fetched, SHA-256 verified, and its delegate headers inspected; the iOS App-only build and 77 simulator XCTest/UI tests pass. | **源码/API边界与本机平台构建已验证；** connected emulator, iOS device, authenticated Range/redirect fallback, and real format/audio acceptance remain external evidence. |
| MOBI/AZW/AZW3 使用 libmobi 后转换 | `shared/format-core` vendored libmobi v0.12，并通过受限 `tmpfile()` C shim 调 `mobi_load_file`、加密检测和 RawML 解析；Rust `mobi` crate 与 PalmDOC 生产 fallback 均已移除。宿主 `cargo test --locked` 实际编译链接 shim，37 项测试通过。 | **核心实现与宿主测试已验证；** 尚未以许可明确的 HUFF/CDIC、KF8/AZW3、DRM 真书回归，也未证明 Android NDK/iOS 交叉编译和最终安装包链接。LGPL 发布材料与法律审查仍为发布阻塞项。 |
| EPUB CFI 在双设备间正确同步与恢复 | Android/iOS 都改为产生和保存 `epubcfi(...)` point locator，并能恢复外来 point CFI；不能映射时会明确提示后按百分比降级。 | **基础 point CFI 已验证；** range/temporal/spatial CFI 与完整 Readium 跨引擎互操作仍未完成。 |
| 同步仅在“远端自本地上次拉取后变化”时提示冲突 | Android Room 9 与 iOS SQLite migration 5 均保存普通/音频远端快照基线；首次 dirty 本地进度先建立基线，只有远端相对基线变化且与本地不同才创建冲突。 | **源码、Android JVM tests、Swift parser 与 simulator XCTest 已验证；** 真实双设备 BookOrbit 集成仍待外部验收。 |
| Android Wi-Fi 断点续传不损坏文件 | Android 现在以 `.part` 实际长度为恢复依据，纠正 Room 偏移，截断半块尾部，禁止 seek 空洞，写入后 fsync，完成前再次对账，并对数据库领先/落后、半块、最终块和超长文件有 JVM 测试。 | **源码与 Debug JVM 测试已验证；** 真正断电/进程杀死、设备文件系统和浏览器恢复仍待外部验收。 |

## P1：安全、功能与契约一致性缺口

| 范围 | 事实与限制 | 完成条件 |
| --- | --- | --- |
| BookOrbit 登录和进度合同 | 双端现在都严格要求登录响应中的 `accessToken`；iOS 局域网 HTTP 确认绑定规范化 host+port，旧 host-only 记录不迁移。 | **源码、Swift parser、iOS App-only build 与 simulator XCTest 已验证；** 真实 HTTP refresh-cookie、服务端错误码和证书场景仍待外部验收。 |
| 明文 HTTP 边界 | Android Manifest 与 Network Security Config 现在默认拒绝全部明文流量，且没有伪装成动态用户白名单的 `domain-config`。`BookOrbitClient` 在既有私网 host+port 确认之后，仍必须通过 Android `NetworkSecurityPolicy`；默认安装包因此会在打开 socket 前拒绝 HTTP。 | **源码与 JVM 静态验证已覆盖 fail-closed 路径；** 这关闭了全局放行 P1，但也意味着默认 Android 包不提供 BookOrbit LAN HTTP。若产品决定恢复该功能，必须经安全评审交付具体、静态且可测试的 host 策略或改用 HTTPS，不能由确认复选框动态放行。 |
| Wi-Fi 会话、续传与清理 | 两端为每个新上传生成独立的 256-bit `resumeToken`，接收端只保存其 SHA-256；浏览器与 `uploadId` 一同保存该凭据。恢复时必须同时持有新 QR 的短期 bearer 和 `X-Papria-Resume-Token`，所以扫描新 QR 或猜到 uploadId 都不能接管旧上传。mDNS 不含 token，前台服务每小时与每次请求清理超 24 小时上传。 | **源码与 Android JVM 测试边界已验证；** 支持在 24 小时保留期内，使用新 QR 会话加原浏览器的 resume token 恢复上传。旧版“bearer 绑定 uploadId”的未完成上传在升级时会被刻意清除，不进行不同凭据间的 key 映射。真实浏览器、进程杀死和设备文件系统验收仍待完成。 |
| 基础阅读设置 | Android PDF 已本机持久化 page、zoom/fit；iOS EPUB 已有暖白/护眼/夜读纸色，iOS PDF 已持久化 page/fit/zoom。 | **源码与 build/JVM 证据已验证；** 重启和设备 UI 验收仍待完成。 |
| 平台构建与测试门禁 | libmobi 变更后的宿主 Rust core 37 项测试、Clippy、四 Android ABI、Android Debug/Release package gates、iOS XCFramework 和 iOS App-only build 均有本机证据；API 26 emulator 已执行数据库迁移与打包 native-core instrumentation，arm64 iPhone 17 Pro simulator 已通过 77 XCTest/UI tests。MobileVLCKit archive fetch/header inspection 也成功。 | 更广泛的 Android connected instrumentation、iOS device execution、GitHub clean-checkout execution and real-device smoke tests remain required. |

## P2：必须由外部环境提供的发布与验收证据

以下项目不是通过补充仓库源码就能证明完成，当前均没有证据：

- 真实 BookOrbit v2.5.0 服务的登录、令牌过期、401/403/404、分页、封面、多轨音频、Range、网络切换和双设备冲突验收。
- Android 普通机、5～6 英寸/600×800/16 灰阶水墨参考设备和 iPhone SE 的安装、阅读、触控、性能、无动画/无滚动、锁屏、蓝牙、电话中断、强退和重启恢复证据。Kindle 不是安装目标。
- Safari、Chrome 与桌面浏览器的 Wi-Fi 上传、8 MiB 分块、断线续传、应用进程重启、无 token、空间不足、路径穿越与压缩炸弹验收。
- 实体 GitHub 仓库尚未配置 remote，因此不能在本地证明 CI 已运行、分支保护、CODEOWNERS 审批或私密漏洞报告已启用。仓库已有候选、签名发布、SBOM/provenance 与发布 runbook 工作流，并且候选/签名流程会复用严格 source gate；但真实 GitHub Environment、密钥、AAB/IPA 上传、正式验收包和可用安全联系入口均需要仓库管理员配置，不能在此代码库内假定完成。
- 第三方许可交付未完成。已加入 libmobi v0.12 的完整 LGPL 文本、上游源码和 provenance；文档现记录 Readium 的 BSD-3-Clause 许可证证据、Readium/PDFium 的待解析依赖边界，以及 MobileVLCKit `3.7.2` 的官方 SHA-256/`COPYING.txt`/LGPL v2.1 证据。`THIRD_PARTY_NOTICES.md` 仍须在发布前按最终 APK/IPA 补齐准确 NOTICE、源码与 LGPL 可重链接材料；BookOrbit 服务端不应被打包进客户端。
- 仓库侧供应链配置已补齐：GitHub Actions 使用 40 位 commit SHA，Rust 固定为 `1.85.1`，`cargo-ndk` 固定为 `3.5.4`，UniFFI 使用固定源码 commit，Gradle wrapper 有 `distributionSha256Sum`，并新增 SBOM、校验和、测试报告和 provenance 工作流。GitHub runner 镜像/Xcode 仍只能固定到托管镜像标识（当前为 `ubuntu-24.04`/`macos-14`），且这些 workflow 尚未在远端执行；原因和管理员需提供的签名/发布凭据记录在 `docs/supply-chain.md` 与 `RELEASING.md`，不能替代真实发布和法律验收。

## 当前完成度结论

项目已经具备可继续开发的双端工程和部分安全/协议/格式边界，且严格合同、fixture、目录和仓库策略可以在本地复查；本轮使 format core 成为 Android/iOS 默认强制构建路径，并补齐 Android Readium/PDFium、iOS Readium、MobileVLCKit 的源码或锁定材料。它**不应被表述为“已按原始规格完成”或“可发布”**：广泛的 Android connected instrumentation、iOS device、完整 CFI 互操作、真实书籍与真实环境验收，以及最终许可证/签名发布证据仍是实质缺口。

在补齐剩余 P0/P1 实现、清理并验证当前工作树后，仍必须取得 P2 的真机、真实服务、浏览器、GitHub 发布和许可证证据，才能把交付状态提升为候选发布版本。

## 可重复命令及其适用范围

```bash
./scripts/verify-contracts.sh
./scripts/verify-fixtures.sh
./scripts/verify-repository.sh
bash scripts/verify-structure.sh
CARGO_TARGET_DIR=/tmp/papria-rust-target cargo fmt --manifest-path shared/format-core/Cargo.toml -- --check
CARGO_TARGET_DIR=/tmp/papria-rust-target cargo test --locked --manifest-path shared/format-core/Cargo.toml
CARGO_TARGET_DIR=/tmp/papria-rust-target cargo clippy --locked --manifest-path shared/format-core/Cargo.toml --all-targets -- -D warnings
# Android: JDK 21 + Android SDK/NDK; every build runs the mandatory format core
# iOS: xcodebuild ... build-for-testing (see .github/workflows/ci.yml)
```

这些命令和本轮平台构建只能验证仓库代码路径与限定行为；即便通过，也不能替代本文件列出的真实格式、设备、服务、浏览器、签名和许可证验收。
