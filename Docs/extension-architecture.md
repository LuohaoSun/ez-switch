# 扩展架构与移除说明

本文说明 EZ Switch 内置扩展的分层、运行时契约与移除方式。它面向仓库维护者，不是用户使用指引；用户侧能力见[扩展说明](extensions.md)与[Cursor 连接器说明](cursor-connector.md)。

## 分层

扩展由宿主通用层与具体连接器两层构成，二者职责分离：

- **宿主通用层（主干）**：
  - `Sources/EZSwitch/ExtensionRegistry.swift`：不可变注册表。按 `source` 登记连接器定义，负责该来源的**请求转发**、**模型目录**（`fetchModels`）与**支持协议**（`endpoints`）三类通用查询。就绪不属于注册表，由各 Router 持有。
  - `Sources/EZSwitch/ExtensionRuntime.swift`：通用运行时。持有单一 `revision` 信号，负责扩展的**启动与刷新**；具体连接状态留在各自的扩展面板里。
  - `Sources/EZSwitch/ExtensionConfig.swift`：通用配置与解析。`ProtocolAdapter`、`ExtensionSettings` 提供协议适配身份与可用性判定，不依赖任何具体连接器。
  - 面板入口 `ExtensionPaneEntry` 只声明“标识 + 构造视图”，由宿主统一挂载。
- **具体连接器**：实现请求执行、模型目录、能力声明与自身面板，通过注册表接入宿主。

`Chat → Responses` 目前不是独立的一层，而是复用主干既有配置与执行路径的协议适配方式；详见下文。

## 组合点

`Sources/EZSwitch/BuiltinExtensions.swift` 是**唯一**在主干中指名具体连接器的位置。它集中三件事：

- `connectors`：向 `ExtensionRegistry` 提供连接器定义；
- `panes`：向设置页提供扩展面板；
- `start`：在启动时接入 `ExtensionRuntime`。

除该文件与各连接器自身目录外，主干不出现任何连接器专有名称。

## 目录布局

可选连接器的实现、状态、sidecar 客户端、专有 UI 与测试集中在一处：

- 源码与专有 UI：`Sources/EZSwitch/Extensions/Cursor/`
- 专有测试：`Tests/EZSwitchTests/Extensions/Cursor/`

目录按连接器划分，便于整体增删，不需要在主干各文件中散点摘除。

## 随包 sidecar

Cursor 连接器运行在应用自带、固定版本的 CLIProxyAPIPlus sidecar（打包名 `ezs-cursor-proxy`，归档可执行名 `cli-proxy-api`）之上。版本 pin、双架构资产 URL 与 SHA-256、随包 MIT 许可原文记录在 [`ThirdParty/cursor-proxy/manifest.json`](../ThirdParty/cursor-proxy/manifest.json)。`Scripts/build-cursor-proxy.sh` 校验发布归档与可执行文件，`Scripts/build-app.sh` 随后打包并重新进行 ad-hoc 签名；不修改上游源码，重新签名会改变 Mach-O 签名数据。

- 该 artifact 是 **macOS 15.0+** 构建（`minos 15.0` / `sdk 15.5`，arm64/amd64），因此 **Cursor 连接器只在 macOS 15 或以上可用**；系统低于 15 时扩展页提示缺少运行条件且不启动 sidecar。**主干应用的最低系统仍是 macOS 13**，两者要求分开。
- sidecar 不是常驻服务：启用时按需启动，只监听 `127.0.0.1` 随机端口，API 与管理接口各用随机 key；禁用或退出应用即停止。凭据落在应用配置目录的 `extensions/cursor/auth` 下由 sidecar 持有，不写入 `config.json`。

## 构建期可选

`Package.swift` 支持以环境变量在构建与测试时整体排除 Cursor 连接器：

- 设置 `EZSWITCH_DISABLE_CURSOR=1` 时，从 `EZSwitch` target 排除 `Extensions/Cursor` 源码、从 `EZSwitchTests` target 排除对应测试，并**不**定义编译宏；
- 默认（未设置）时定义 `EZSWITCH_CURSOR_EXTENSION`，`BuiltinExtensions` 通过 `#if` 条件注册该连接器。

因此排除时主干与其余扩展照常编译，组合点回退为空注册。

## 移除契约

移除一个可选连接器只需两步，不需要改动主干其他文件：

1. 删除其源码/UI 目录与测试目录；
2. 删除 `BuiltinExtensions.swift` 中对应的条件注册。

移除后主干不再有任何该连接器的字样。可用静态检查核对：

```bash
bash Scripts/check-extension-boundaries.sh
```

该脚本扫描 `Sources/EZSwitch` 与 `Tests/EZSwitchTests` 中所有 `.swift`，只允许 Cursor 的具体名称出现在各 `Extensions/Cursor` 目录与 `BuiltinExtensions.swift` 组合点；发现泄漏即失败。

## 持久化与兼容契约

扩展是同一 target 内的可选编译单元，配置必须在其缺席时仍可安全读写：

- **来源标识**：远端记录持久化的 `source` 按字符串原样往返；已知取值 `api`、`cursorCLI` 的 JSON 拼写保持不变。其中 `cursorCLI` 是为兼容已有模型 UUID 与路由绑定而保留的**来源标识**，不是当前后端实现的名字（当前后端是随包 CLIProxyAPIPlus sidecar）。当前构建未内置的扩展，其 source 字符串既不会被拒绝、也不会被改写，可无损往返。
- **扩展配置**：已知的 `chatToResponses` 由强类型保留；其余未知扩展键以任意 JSON 往返保留，不因该扩展未内置而被丢弃。旧配置缺省字段按各自默认值解码。
- **缺席/移除时保留数据**：未安装或已移除某扩展后，其已加入的供应商/模型、路由绑定与该扩展配置都**保留**，不会被清理或改写。
- **候选不可用**：缺席或未就绪的扩展候选从可用候选中排除，继续使用现有 fallback 规则；若没有其他可用候选，则返回现有路由错误。扩展记录始终保留自身来源，不会被当作原生 HTTP 上游执行。
- **解码失败保护原文件**：配置初次加载解码失败时**阻断保存**，直到一次成功重载为止；期间不写盘，从而不覆盖磁盘上的原文件。

## 明确未声明

- 扩展没有拆成独立 SwiftPM 模块，也不是第三方动态插件；它们是同一 target 内按构建开关可裁剪的编译单元，通过宿主通用接口接入配置和路由。
- `Chat → Responses` 暂保留现有共享配置与执行（每请求独立的内置 helper 进程），本次不承诺将其拆分为独立模块。
- 不支持第三方扩展安装、热加载或插件市场，也不引入常驻服务。

## 验证

以下命令用于复核分层与可移除性：

```bash
# 1) 静态边界：连接器专有名称只出现在其目录与组合点
bash Scripts/check-extension-boundaries.sh

# 2) 无 Cursor 构建与测试：排除 Cursor 源码与专有测试的全量编译 + 测试
EZSWITCH_DISABLE_CURSOR=1 swift test

# 3) 常规构建与测试：含 Cursor
swift test
```
