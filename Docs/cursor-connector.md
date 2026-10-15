# Cursor 订阅连接器

侧栏「扩展」页内置的 **Cursor 订阅连接器**（下称“连接器”），让你在保留 EZ Switch 统一路由与自动回退的同时，把 Cursor 订阅当作一类上游使用。它属于应用内置扩展，不需要下载或安装扩展，也没有插件市场。

## 实现：应用自带的固定 sidecar

连接器不依赖用户安装官方 `cursor-agent` CLI，也不自写私有协议，而是运行应用自带的 **CLIProxyAPIPlus** sidecar：

- 上游项目：[jc01rho/CLIProxyAPIPlus](https://github.com/jc01rho/CLIProxyAPIPlus)（`router-for-me/CLIProxyAPI` 的分支），**MIT**。
- 固定发布：**v8.0.28-2**，commit **67eadafb4ea36e5cf60d33fa349982da9b6dc31b**。
- 打包名：**`ezs-cursor-proxy`**（随应用打包进 `Contents/MacOS/`；归档内名为 `cli-proxy-api`）。不修改上游源码；构建时校验发布归档和可执行文件的 SHA-256，再重新进行本地签名。
- 该 sidecar 直连 `api2.cursor.sh`，并自行处理 Cursor 的 OAuth 与令牌刷新。

版本、各架构下载地址与 SHA-256、以及随包 MIT 许可的原文，记录在 [`ThirdParty/cursor-proxy/manifest.json`](../ThirdParty/cursor-proxy/manifest.json)。固定版本与校验由构建脚本 `Scripts/build-cursor-proxy.sh` 落实：从该 pin 下载 darwin `arm64` / `amd64` 资产并做 SHA-256 校验，构建期不会回退到其它项目或版本。

### 系统要求（仅连接器）

- 固定发布的官方 artifact 是 **macOS 15.0+** 构建（`vtool` 显示两个架构均 `minos 15.0` / `sdk 15.5`），**不兼容 macOS 13**。
- 因此 **Cursor 连接器只在 macOS 15 或以上可用**；系统低于 15 时扩展页显示“缺少运行条件”的错误，**不会启动** sidecar。
- 这是**连接器自身**的要求：EZ Switch 主干应用的最低系统仍是 **macOS 13**，不受影响。
- sidecar 版本固定为 **8.0.28-2**，可由其 `--help` banner 读取（它**没有** `--version` 这个 flag）。

## 运行时与凭据

启用连接器后，宿主按需启动这个**自有** sidecar，并把它限制在本机：

- 只监听 `127.0.0.1` 的随机端口；API 与管理接口各用一把随机 key，只保存在受保护的运行配置和进程内存中，不写入应用的 `config.json`。
- 扩展自己的目录位于应用配置目录下：`<应用配置目录>/extensions/cursor/`（含 `auth/`）。登录令牌由 sidecar 写在该目录里，**不读取、不复制、不修改系统上其它 Cursor CLI、桌面应用或 `~/.cursor` 配置**。
- 宿主**只读**管理接口的账户元信息，用于显示账号与模型目录；**不把 Cursor 凭据写进 `config.json`**。
- sidecar 运行需要一个临时 `config.yaml`，含本地 keys，权限设为 `0600`；它是运行期文件，不承载账户凭据。
- **退出登录只清除本扩展自己的 Cursor 登录凭据**，不影响系统上其它工具或 Cursor CLI；供应商、模型与路由绑定保留。

## 登录与状态

登录由用户显式发起，宿主不自动打开任何地址：

1. 用户在扩展页点击「连接 Cursor」；
2. 宿主向 sidecar 取得**管理地址**；
3. 宿主用系统浏览器打开该授权地址（只接受 `https`）；
4. 宿主**轮询** sidecar，读取账户元信息与模型目录；
5. 已登录、sidecar 运行中、模型目录非空且探测无错，才显示「已连接」。

连接可用 = 已安装 + 运行中 + 已认证 + 有模型 + 无错误。**登录状态本身不等于可用**：只要模型目录为空或探测报错，就提示「重新连接」，不伪造账号或模型。

## 在扩展页启用

「扩展」页在 Chat → Responses 区块下方新增 Cursor 区块，**默认关闭**。区块提供启用开关、连接/登录状态、重新检测、连接/重新连接、退出登录，以及「添加到供应商」/「前往供应商」与「同步模型」。开启开关后宿主才会启动 sidecar。

## 供应商、模型与路由

- 「添加到供应商」把 Cursor 作为一类供应商加入（默认名 `Cursor`，重名自动追加序号，绝不覆盖已有供应商），模型 ID 取自 sidecar 读取到的真实目录，不用猜测或固定字符串伪造。目录为空时提示重新连接，不生成占位模型。
- 生成的 Cursor 供应商记录连接身份为 Cursor 扩展：API Key 为空、原生协议全部关闭；添加与同步是幂等的，重复操作只补齐缺失模型。
- 添加后与普通供应商一样出现在「供应商与路由」页：可绑定路由、参与自动回退；「同步模型」会刷新目录并幂等补齐。
- Cursor 供应商使用**仅名称**的编辑器：不要求也不允许填写内部 Base URL 或 API Key。
- 模型与路由沿用现有供应商/模型逻辑，不引入单独的 Cursor 路由模型；绑定以**供应商名**为身份，由配置存储随供应商生命周期统一维护。

> 持久化时该来源的 `source` 字符串仍是 **`cursorCLI`**。这是为兼容已有模型 UUID 与路由绑定而保留的**兼容标识**，不是当前后端实现的名字；不要据此改动模型 UUID 或路由。

## 支持范围与限制

- 传输支持 **Chat Completions / Responses / Messages**，由该第三方 sidecar 处理，支持**工具回合**。
- **不支持 Gemini**（该 sidecar 不提供 Gemini 原生协议）。
- **不承诺**覆盖全部多模态内容、全部生成参数或全部服务端会话状态：这些能力以 sidecar 与 Cursor 上游的实际行为为准，EZ Switch 不做无损转换的保证。
- **工具会话是有状态的**：live 会话约 **5 分钟**、checkpoint 约 **30 分钟**，均只存在于 sidecar 进程内。sidecar 重启、禁用连接器或退出登录都会**中断未完成的工具回合**，不会对工具会话做不透明重试。
- **会话续接受当前 pin 限制**：仅识别 `metadata.user_id` 内嵌 JSON 中的 `session_id`；缺失时每个请求使用随机 `conversationId`，无法续接。续接需要客户端发送**完整历史**，缺少匹配会话 ID 时无法复用；隐藏思维链与 KV 复用**不做保证**。工具续接未全部实测，真实账号的端到端验收也未完成。
- **不做用量估算**：用量与性能沿用通用 HTTP 统计，按上游响应**真实上报**；没有上报即不记录。
- **模型目录来源**：这个固定版本按 Cursor 凭据注册其内置模型目录；扩展读取 sidecar 的 `/v1/models`，不另外制造 ID。目录并非实时向 Cursor 查询的账号能力清单，不代表账号配额或每个模型可用性已经验证。

## 关闭与生命周期

- 默认关闭。关闭会**停止本扩展自有的 sidecar**，但**保留**凭据、供应商、模型与路由 ID；重新启用即恢复。
- 关闭只让 Cursor 候选不可用；路由中其它原生候选与自动回退不受影响，不会把 Cursor 候选回退为原生。
- 应用退出时同步停掉该 sidecar，不改动应用主干。

## 验证状态

- 构建期可用 `EZSWITCH_DISABLE_CURSOR=1` 整体排除连接器：源码、专有 UI 与 sidecar 都不下载、不打包。
- 当前测试使用**假 HTTP** 加**真实发布的 sidecar 二进制**，覆盖**空登录态下的 health / management 启动**等路径；**不**声明真实订阅的推理或工具端到端已成功。
- Cursor 私有协议（Connect/protobuf）确实由该 Plus sidecar 使用与实现；EZ Switch 的 Swift 代码不实现该协议、不另写一套。不提供第三方扩展安装、热加载或插件市场。

## 实现与移除

连接器是可选、低耦合的扩展：实现、状态、sidecar 客户端与专有 UI 集中在 `Sources/EZSwitch/Extensions/Cursor`，专有测试集中在 `Tests/EZSwitchTests/Extensions/Cursor`，主干只由 `BuiltinExtensions.swift` 这一组合点指名。移除只需删除上述目录与组合注册。删除后已加入的供应商、模型、路由绑定与该扩展配置**保留**，其候选只是不可用。用 `bash Scripts/check-extension-boundaries.sh` 可静态核对名称未泄漏到主干。这是同一 target 内的编译期可选单元，**不**构成独立 SwiftPM 模块或二进制隔离。许可与打包来源见 [`ThirdParty/cursor-proxy/manifest.json`](../ThirdParty/cursor-proxy/manifest.json) 与[扩展架构与移除说明](extension-architecture.md)。
