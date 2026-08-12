# Papria 文档索引

Papria 的文档按“主题说明 + 架构决策 + 验收规格”组织，目录结构参考 `eeclass-project`，但不引入其教育业务、后端或 Web 前端。

## 工程与架构

- [`project-structure.md`](project-structure.md)：主项目目录结构学习与 Papria 映射；先阅读此文，了解上游 BookOrbit 和 `eeclass-project` 的实际主目录清单、根目录入口文件、源码/产物边界、依赖方向和后续扩展位置。`1.2` 节记录了本次对 `eeclass-project` 提交 `c667e1f5`（0.8.0 repository candidate）的实际核对结果。
- [`architecture.md`](architecture.md)：Android、iOS、共享核心、本地存储和 BookOrbit 的边界。
- [`adr/0001-native-project-structure.md`](adr/0001-native-project-structure.md)：为什么使用原生双端分层。
- [`adr/0002-bookorbit-transport-security.md`](adr/0002-bookorbit-transport-security.md)：HTTPS、证书指纹和明文局域网传输的安全边界。
- [`../shared/format-core/README.md`](../shared/format-core/README.md)：格式识别、归档安全、哈希和 UniFFI 边界；Android 的每个 `preBuild` 与 iOS 的项目 build phase 都默认构建并接入该核心，缺失产物即失败。当前 Android Readium/PDFium 和 iOS App 的完整构建证据状态见 [`spec-audit.md`](spec-audit.md)。
- `../scripts/build-format-core.sh`：在安装 Rust Apple targets（iOS）或 Android NDK + `cargo-ndk` 后，打包共享核心原生库；不把二进制产物提交到仓库。

## 产品与协议

- [`bookorbit-mobile-reader-spec.md`](bookorbit-mobile-reader-spec.md)：规格入口指针。
- [`bookorbit-mobile-reader-spec.full.md`](bookorbit-mobile-reader-spec.full.md)：完整产品功能、格式支持、同步和验收规格快照。
- [`compatibility.md`](compatibility.md)：BookOrbit `v2.5.0` 精确路由和字段范围。
- [`wifi-transfer.md`](wifi-transfer.md)：前台局域网传书协议和安全约束。
- [`epub-reader.md`](epub-reader.md)：Android/iOS EPUB、KEPUB 目录、分页、样式和 offset locator 边界。

## 开发与质量

- [`development.md`](development.md)：工具链、构建和本地 BookOrbit 测试。
- [`testing.md`](testing.md)：合同、格式、同步、断点下载和真机验收策略。
- [`acceptance.md`](acceptance.md)：共享核心、协议、设备和发布证据的验收清单。
- [`spec-audit.md`](spec-audit.md)：按源规格逐项核对当前源码证据、硬缺口和建议修复顺序。
- [`supply-chain.md`](supply-chain.md)：Action/工具链固定策略、SBOM、校验和、构建证明和许可证复核边界。
- [`license-inventory.md`](license-inventory.md)：生成依赖报告并逐项补齐许可证/NOTICE 的方法。

平台脚本位于 `android/scripts/` 和 `ios/scripts/`，分别负责 Debug、单元测试、重建和 QA 构建入口；脚本只编排平台工具链，不复制业务逻辑。

根目录 `scripts/verify-structure.sh` 检查 Android、iOS、shared、文档和 GitHub 协作入口是否
仍然存在；`scripts/verify-repository.sh` 另外检查 Action 固定、脚本语法、产物忽略和
tracked-file hygiene。两者与合同、fixture 检查一起由 CI 执行。

文档中的接口字段名与 `shared/contracts/` 保持一致。不要在文档或实现中增加字段别名、备用 key 或隐式兼容映射。

## 仓库级规范

- [`CONTRIBUTING.md`](../CONTRIBUTING.md)：分支、提交和变更协作约定。
- [`SECURITY.md`](../SECURITY.md)：漏洞报告和安全边界。
- [`CODE_OF_CONDUCT.md`](../CODE_OF_CONDUCT.md)：社区行为规范。
- [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)：第三方组件和许可证说明。
- [`RELEASING.md`](../RELEASING.md)：候选构建、签名制品、校验和、GitHub 发布和管理员外部凭据流程。
- [`../third_party/licenses/JUNRAR-7.5.5-UNRAR.txt`](../third_party/licenses/JUNRAR-7.5.5-UNRAR.txt)：Junrar 使用的 UnRAR 条款原文。
