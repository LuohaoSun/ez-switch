# 扩展架构与移除说明

本文说明 EZ Switch 内置扩展的分层、运行时契约与移除方式。它面向仓库维护者，不是用户使用指引；用户侧能力见[扩展说明](extensions.md)。

## 分层

扩展由宿主通用层与具体连接器两层构成，二者职责分离：

- **宿主通用层（主干）**：
  - `Sources/EZSwitch/ExtensionRegistry.swift`：不可变注册表。按 `source` 登记连接器定义，负责该来源的**请求转发**、**模型目录**（`fetchModels`）与**支持协议**（`endpoints`）三类通用查询。就绪不属于注册表，由各 Router 持有。
  - `Sources/EZSwitch/ExtensionRuntime.swift`：通用运行时。持有单一 `revision` 信号，负责扩展的**启动与刷新**；具体连接状态留在各自的扩展面板里。
  - `Sources/EZSwitch/ExtensionConfig.swift`：通用配置与解析。`ProtocolAdapter`、`ExtensionSettings` 提供协议适配身份与可用性判定，不依赖任何具体连接器。
  - 面板入口 `ExtensionPaneEntry` 只声明“标识 + 构造视图”，由宿主统一挂载。
- **具体连接器**：实现请求执行、模型目录、能力声明与自身面板，通过注册表接入宿主。

`Chat → Responses` 目前不是独立的一层，而是复用主干既有配置与执行路径的协议适配方式；详见下文。

出站代理是同一套骨架上的另一类单元：**出站能力由通用 `OutboundPolicy` 接口承载**（`.direct` 直连 / `.proxy` 经代理 / `.invalid` 配置非法），原生 HTTP 转发按候选快照解析出的策略选择可复用的 `URLSession`；非法策略按后端错误处理，**绝不静默退化为直连**。面板集中在 `Extensions/Proxy`，策略与传输在主干通用的 `OutboundPolicy` / `OutboundTransport`。它同样只经 `BuiltinExtensions.swift` 组合，不引用任何具体连接器名称；连接器通过能力位声明是否允许被代理。

## 组合点

`Sources/EZSwitch/BuiltinExtensions.swift` 是**唯一**在主干中指名具体可选扩展（当前只有出站代理）与连接器的地方。它集中三件事：

- `connectors`：向 `ExtensionRegistry` 提供连接器定义（当前列表为空，没有内置连接器）；
- `panes`：向设置页提供扩展卡片（出站代理一张独立可折叠卡片；注册了连接器时，每个连接器各一张）；
- `start`：在启动时接入 `ExtensionRuntime`。

除该文件与各扩展自身目录外，主干不出现任何扩展专有名称。

## 目录布局

扩展的实现、状态、专有 UI 与测试集中在一处：

- 出站代理面板：`Sources/EZSwitch/Extensions/Proxy/`（通用策略与传输在主干 `OutboundPolicy.swift`，不属任何连接器）
- 连接器（当前无内置）：约定集中在 `Sources/EZSwitch/Extensions/<连接器>/`，专有测试在 `Tests/EZSwitchTests/Extensions/<连接器>/`

目录按扩展划分，便于整体增删，不需要在主干各文件中散点摘除。

## 构建期可选

`Package.swift` 支持在构建与测试时独立排除可选扩展：

- `EZSWITCH_DISABLE_PROXY=1`：排除 `Extensions/Proxy` 源码与测试，不定义 `EZSWITCH_PROXY_EXTENSION`；通用出站接口保留，组合点返回直连策略，已保存的代理配置原样保留。

默认包含该扩展，`BuiltinExtensions` 通过条件注册组合；连接器框架本身不受影响，只是当前没有内置连接器可注册。

## 移除契约

移除一个可选扩展或连接器时，清理以下入口：

1. 删除其源码/UI 目录与测试目录；
2. 删除 `BuiltinExtensions.swift` 中对应的注册，以及 `Package.swift` 中对应的构建开关与排除项；
3. 若扩展附带辅助程序，删除专有构建脚本、打包与签名步骤、第三方来源文件及相关文档。

移除后主干不再有任何该扩展的字样。可用静态检查核对：

```bash
bash Scripts/check-extension-boundaries.sh
```

该脚本扫描 `Sources/EZSwitch` 与 `Tests/EZSwitchTests` 中所有 `.swift`，将连接器名称与代理扩展的专有类型/配置键限制在各自扩展目录及 `BuiltinExtensions.swift` 组合点，发现泄漏即失败。

## 持久化与兼容契约

扩展是同一 target 内的可选编译单元，配置必须在其缺席时仍可安全读写：

- **来源标识**：远端记录持久化的 `source` 按字符串原样往返。原生 HTTP 上游的来源标识为 `api`，其 JSON 拼写保持不变；任何其它来源字符串（例如曾由某个扩展写入、而当前构建尚未内置的 `source`）既不会被拒绝、也不会被改写，可无损往返。
- **扩展配置**：已知的 `chatToResponses` 由强类型保留；出站代理设置（`outboundProxy`：`enabled`、代理地址、原生 `providerNames`、连接器 `connectorSources`）按通用扩展键读写，未识别字段原样往返；其余未知扩展键以任意 JSON 往返保留，不因该扩展未内置而被丢弃。旧配置缺省字段按各自默认值解码。
- **缺席/移除时保留数据**：未安装或已移除某扩展后，其已加入的供应商/模型、路由绑定与该扩展配置都**保留**，不会被清理或改写。
- **候选不可用**：来源非 `api` 的远端若没有在本构建中注册的连接器（`ExtensionRegistry` 查不到定义），其转发与模型目录都会按不可用处理（`ConnectorUnavailable`），从可用候选中排除并继续走现有 fallback 规则；若没有其他可用候选，则返回现有路由错误。它始终保留自身来源，绝不被当作原生 HTTP 上游执行。缺席或未就绪的扩展候选同理。
- **解码失败保护原文件**：配置初次加载解码失败时**阻断保存**，直到一次成功重载为止；期间不写盘，从而不覆盖磁盘上的原文件。

## 明确未声明

- 扩展没有拆成独立 SwiftPM 模块，也不是第三方动态插件；它们是同一 target 内按构建开关可裁剪的编译单元，通过宿主通用接口接入配置和路由。
- `Chat → Responses` 暂保留现有共享配置与执行（每请求独立的内置 helper 进程），本次不承诺将其拆分为独立模块。
- 出站代理首版是**单一**代理地址 + 名单：不做 PAC、不做代理认证（userinfo），也不为不同来源配置不同代理；`https://`（TLS 到代理）仅在 **macOS 14+** 可用，`http` / `socks5` 自 macOS 13 起可用。
- 不支持第三方扩展安装、热加载或插件市场，也不引入常驻服务。

## 验证

以下命令用于复核分层与可移除性：

```bash
# 1) 静态边界：扩展专有名称只出现在其目录与组合点
bash Scripts/check-extension-boundaries.sh

# 2) 无代理构建与测试：排除代理源码与专有测试的全量编译 + 测试
EZSWITCH_DISABLE_PROXY=1 swift test

# 3) 常规构建与测试：含全部扩展
swift test
```
