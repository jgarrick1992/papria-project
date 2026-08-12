# Papria 项目目录结构说明

Papria 是独立的原生移动阅读客户端。它参考公开的 BookOrbit 项目边界和通用的多端
工程分层，但不复制 BookOrbit 的 Web UI、服务端、数据库、部署配置或其他参考工程
的业务代码。本说明只描述本仓库的公开结构，不记录开发者本机路径、用户名或私有
工作树。

## 结构结论

Papria 采用“原生客户端 + 共享合同/格式核心 + 仓库级文档与检查脚本”的结构：

```text
Papria
├── android/       Android 原生应用、阅读器、BookOrbit、同步和 Wi-Fi 传书
├── ios/           iOS 原生应用、阅读器、BookOrbit、同步和 Wi-Fi 传书
├── shared/        精确线上合同与跨平台格式/归档安全核心
├── docs/          架构、开发、测试、验收和决策记录
├── scripts/       可重复的合同、fixture 与仓库检查
└── third_party/   随源码发布所需的第三方许可文本
```

移动端只连接已部署的 BookOrbit 服务，并保持线上字段名原样；不增加字段别名或隐式
兼容映射。

## 公开参考来源

| 来源 | 用途 |
| --- | --- |
| [BookOrbit](https://github.com/bookorbit/bookorbit) | 了解公开的服务端/客户端边界和 HTTP 合同语义。 |
| 本仓库 `shared/contracts/` | 固定 Papria 实际使用的精确字段、端点和 fixture。 |
| 本仓库 `docs/bookorbit-mobile-reader-spec.full.md` | 保存已审计的产品规格快照。 |

上游项目的 Web、服务端、数据库、容器、部署与测试产物均不属于 Papria 的源码树。
上游发生变化时，应重新核对公开合同后再更新本仓库的合同文件；不得引入字段别名或
key 映射。

## Papria 当前目录

```text
papria-project/
├── android/
│   ├── app/                         # Kotlin/Compose 应用、资源和 Android 测试
│   ├── gradle/                      # Gradle Wrapper
│   ├── scripts/                     # Android 构建、测试和 QA 入口
│   └── README.md
├── ios/
│   ├── Papria.xcodeproj/            # Xcode 工程和共享 scheme
│   ├── Papria/                      # SwiftUI 应用、平台核心与资源
│   ├── PapriaTests/                 # XCTest 单元测试
│   ├── PapriaUITests/               # XCUITest 启动和主流程
│   ├── scripts/                     # Xcode 构建、测试和 QA 入口
│   └── README.md
├── shared/
│   ├── contracts/                   # 精确 JSON/HTTP 合同和样例
│   └── format-core/                 # Rust 格式识别、哈希、归档和转换边界
├── docs/                            # 架构、规格、测试、验收和 ADR
├── scripts/                         # 跨平台合同、fixture、结构和仓库检查
├── third_party/licenses/            # 第三方许可证原文
├── .github/                         # CI、Dependabot、Issue 模板和 CODEOWNERS
├── README.md
├── SUPPORT.md
├── CONTRIBUTING.md
├── LICENSE
├── SECURITY.md
└── THIRD_PARTY_NOTICES.md
```

### Android

`android/app/src/main/java/com/papria/reader/` 保存 Compose 入口、BookOrbit、音频、
显示模式、本地存储、阅读器、安全、同步和 Wi-Fi 传书逻辑。`src/test/` 与
`src/androidTest/` 分别保存 JVM 与设备测试。`build/`、`.gradle/`、`.kotlin/`、
`jniLibs/` 和其他生成内容均为忽略的构建产物。

### iOS

`ios/Papria/` 包含应用入口、API、认证、持久化、阅读、音频、路由、安全、传输、
设计系统和 SwiftUI 功能页。`PapriaTests/` 与 `PapriaUITests/` 是独立测试 target。
`DerivedData/`、SwiftPM 缓存、`ThirdParty/Build/`、生成的 XCFramework、绑定和 IPA
均不得提交。

### 共享边界

`shared/contracts/` 是 BookOrbit HTTP 合同的唯一公开事实来源，要求精确字段名。
`shared/format-core/` 是 Rust/C + UniFFI 的格式识别、流式哈希、归档安全和可转换
格式边界；平台层负责生命周期、UI、系统 API 与受限文件访问。生成绑定和原生库
由平台构建脚本产生，不纳入 Git。

## 依赖方向

```text
App / Features / Compose or SwiftUI
             │
             ▼
platform Core（API、DB、Keychain/Keystore、后台任务、音频、Wi-Fi）
             │
             ├── shared/contracts（精确字段和端点）
             ├── shared/format-core（格式解析与转换）
             └── local file store（内容寻址和断点下载）
```

- UI 不直接拼接 BookOrbit URL，也不直接读取令牌。
- `shared/contracts` 定义线上字段名；不新增 camelCase/snake_case 别名，也不做 key 映射兼容。
- `shared/format-core` 不持有账号、Cookie、数据库连接或平台 UI 状态。
- BookOrbit 下载、Wi-Fi 导入和本地文件最终进入同一个本地文件存储；Wi-Fi 导入不会触发 BookOrbit 上传。
- iOS `GeneratedAPI/` 与 Android 合同模型必须可追溯到 `shared/contracts/`；生成目录禁止手工修改。

## 文档与发布边界

`docs/` 保留规格、架构、兼容性、Wi-Fi 传书、开发、测试、验收与 ADR。真机截图、
性能数据、服务互操作记录和发布证据应在取得后作为可审计材料加入，不得把本机缓存、
私有书籍、账号、签名材料或构建输出提交到仓库。

`LICENSE`、`THIRD_PARTY_NOTICES.md` 与 `docs/supply-chain.md` 记录许可和供应链边界。
在发布制品前，仍须核对最终 APK/AAB/IPA、SBOM、MobileVLCKit、LGPL/MPL/UnRAR 与
编解码器相关义务；当前公开仓库只提供未签名源码快照。
