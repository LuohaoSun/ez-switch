# 扩展（Extensions）

侧栏「扩展」页管理 EZ Switch 内置的协议扩展。扩展随应用一起内置，不需要下载扩展或访问插件市场。

当前内置的扩展有两项，各自有独立的总开关，互不影响：

1. **Chat → Responses 转换**（下称“转换”）：让只提供 Chat Completions 的上游也能服务 Codex 等客户端发出的 `/v1/responses` 请求。它是纯内置扩展，不需要任何外部依赖。
2. **Cursor 订阅连接器**：通过应用自带的固定 CLIProxyAPIPlus sidecar 把 Cursor 订阅作为一类上游接入，接入后与普通供应商一样参与路由和自动回退。它自带 sidecar、没有外部 CLI 依赖，但要求 **macOS 15+**，详见[Cursor 连接器说明](cursor-connector.md)。

下面先完整说明 Chat → Responses 转换；Cursor 订阅连接器见文末摘要。

## Chat → Responses 转换

默认情况下，本机按原协议把 `/v1/responses` 原生转发给上游。当上游只支持 Chat Completions 时，开启转换后：

- 客户端仍请求本机 `/v1/responses`；
- 应用用内置转换器把 Responses 请求体转换为 Chat Completions 请求，发往所选供应商的 Chat Completions 地址；
- 再把上游返回的 Chat 响应转换回 Responses 格式交给客户端。

转换**按供应商生效，不按模型设置**。同一供应商下的所有模型共用同一条转换规则，不能只对单个模型单独开启或关闭。

## 生效规则

转换只在其条件同时满足时才对该供应商的模型生效：

1. 「扩展」页的扩展总开关已开启；
2. 该供应商在供应商名单中已被勾选。

任一条件不满足，或该供应商没有勾选，则该供应商的模型保持原生 Responses 转发（当该供应商启用了原生 Responses 时）。

总开关与名单相互独立：关闭总开关不会清除已有的勾选，名单在选择状态下仍可编辑；重新开启总开关后，之前勾选的供应商仍然处于勾选状态。

## 界面（Chat → Responses）

- 「扩展」页是独立的侧栏入口；「供应商与路由」页的布局与操作保持不变。
- 页面顶部是扩展总开关，用于整体开启或关闭转换。
- 总开关下方是供应商名单，逐供应商勾选是否参与转换；配置不可用时，在该行显示原因。
- 原生地址、凭据与各协议的启用开关都不受转换影响：转换复用所选供应商已配置的 Chat Completions 地址与凭据，不会覆写、改写或复制原生 Responses 的 Base URL、API Key 或协议开关。

### 缺少 Chat Completions 的供应商

如果某个供应商没有启用 Chat Completions，它就无法作为转换目标：

- 该供应商不能被新勾选（勾选项不可用），名单中会说明原因；
- 若它此前已被勾选、之后又不具备 Chat Completions 配置，仍可取消勾选，界面会用醒目标注说明原因；
- 应用不会把它静默退回原生，也不会留下“已勾选但实际不转换”的模糊状态。

### 供应商身份与生命周期

扩展名单以**供应商名**作为身份（当前供应商没有独立 UUID），并由配置存储随供应商生命周期统一维护，不单独引入一套扩展生命周期：

- 取消勾选或删除供应商：按集中规则清理对应选择，不留下指向已删除供应商的悬空引用；
- 重新添加同名供应商：不会自动继承此前的勾选（不做幽灵继承）；
- 新添加的供应商：默认不勾选，需要手动勾选才会参与转换；
- 重命名供应商会更换其名称标识，其勾选由同一套存储生命周期规则处理，不会静默指向不再存在的旧名称。

## Chat → Responses 的旧配置迁移

在早期版本中，“转发到 Chat”是供应商级别的 Responses 传输方式设置（`responsesTransport`，在内部会随每个模型复制一份，只允许在供应商设置里修改）。升级后该设置迁移为本文档描述的按供应商规则：

- 只要某供应商此前的任一模型使用了 Chat 转换，迁移后该供应商在扩展名单中即视为已勾选，且扩展总开关被打开，其全部模型统一按同一规则处理；
- 迁移只用于兼容读取旧配置并转换为新规则，**不会改写原生 Responses 地址、凭据或其他协议开关**；
- 迁移只影响 Responses 的传输方式，不改动模型列表、路由、自动回退或用量数据；
- 迁移只在配置中尚无扩展字段时执行一次：一旦配置写入了扩展字段，就以已保存的扩展设置为准，不会因重新加载又按旧的 `responsesTransport` 打开转换。

> 迁移只保证对旧配置的 decode 兼容，不提供把新规则反向写回旧字段的路径。

## Chat → Responses 的限制

- 转换要求客户端发送完整会话历史。请求中如出现 `previous_response_id`、`conversation`，或服务端压缩（`compaction_trigger` / `compaction` 项），会被明确拒绝并返回客户端错误，请改用本地压缩；不会静默降级或改用其他方式。
- 转换并非无损，部分 Responses 能力无法在 Chat Completions 中完整表达。
- 转换由随应用内置的独立 helper 进程执行，每个请求一个进程，进程之间不共享状态；API Key 与网络连接保留在应用本体，helper 只接收请求体。
- 用量与性能以**原始上游响应**为准，转换补出的事件不参与统计，详见[用量统计说明](token-usage.md)。

## Cursor 订阅连接器

侧栏「扩展」页在 Chat → Responses 区块下方新增 **Cursor 订阅连接器**，默认关闭。它运行在应用自带的固定 **CLIProxyAPIPlus** sidecar（打包名 `ezs-cursor-proxy`）之上：

- sidecar 来自 [jc01rho/CLIProxyAPIPlus](https://github.com/jc01rho/CLIProxyAPIPlus)（`router-for-me/CLIProxyAPI` 分支），固定 **v8.0.28-2** / commit **67eadafb4ea36e5cf60d33fa349982da9b6dc31b**，**MIT**；不依赖官方 `cursor-agent` CLI，也不自写私有协议。固定 pin 与校验见 [`ThirdParty/cursor-proxy/manifest.json`](../ThirdParty/cursor-proxy/manifest.json)。
- 启用后只在 `127.0.0.1` 随机端口监听，API 与管理接口各用随机 key；登录凭据写在应用配置目录的 `extensions/cursor/auth` 下、由 sidecar 持有，EZSwitch 不把它写进 `config.json`，只读管理接口的账户元信息；退出登录只清除本扩展账户，不影响系统上其它工具。
- 登录由「连接」按钮发起：宿主取管理地址并在系统浏览器打开授权，再轮询读取账户与模型目录；已登录、sidecar 运行中、目录非空且无错才显示「已连接」，登录态本身不等于可用。
- 「添加到供应商」用 sidecar 读取的真实目录加入供应商（默认名 `Cursor`，重名自动追加序号），随后像普通供应商一样绑定路由、参与自动回退；目录为空时提示重新连接，不伪造模型 ID。Cursor 供应商使用仅名称的编辑器，不填 Base URL/API Key。
- 传输支持 Chat / Responses / Messages（由该 sidecar 处理，含工具回合），**不支持 Gemini**；不承诺覆盖全部多模态、生成参数或服务端状态。工具会话在 sidecar 进程内有状态（约 5 分钟 TTL），sidecar 重启、禁用或退出登录会中断未完成的工具回合。用量不做估算，沿用通用 HTTP 统计的真实上报。
- 默认关闭；关闭会停止本扩展自有的 sidecar，但保留凭据、供应商、模型与路由 ID，重新启用即恢复；其它原生候选与自动回退不受影响。
- **系统要求**：固定发布的 sidecar 是 macOS 15.0+ 构建（`minos 15.0` / `sdk 15.5`，arm64/amd64），**不兼容 macOS 13**。Cursor 连接器因此只在 **macOS 15 或以上**可用，低于 15 时扩展页提示缺少运行条件且不启动 sidecar；主干应用最低系统仍是 macOS 13。

当前测试使用假 HTTP 加真实发布的 sidecar 二进制，覆盖空登录态下的 health / management 启动，**未**声明真实订阅的推理或工具端到端验证。完整说明见 [Cursor 连接器说明](cursor-connector.md)。

## 实现范围

扩展随应用内置。Chat → Responses 通过每请求独立的桥接进程执行；Cursor 订阅连接器由自带固定的 CLIProxyAPIPlus sidecar 执行，仅在启用时按需启动、只监听 `127.0.0.1` 随机端口，关闭即停止。两者都不常驻运行，也不支持第三方扩展安装、热加载或插件市场。

扩展在主干中通过通用注册表与运行时接入：`ExtensionRegistry` 负责请求转发、模型目录与支持协议，`ExtensionRuntime` 负责启动与刷新。具体连接器只集中在各自的 `Extensions/Cursor` 目录，主干仅由 `BuiltinExtensions.swift` 这一组合点指名。可选连接器可在构建时以 `EZSWITCH_DISABLE_CURSOR=1` 整体排除，移除只需删除其目录与组合注册。这**不**构成独立 SwiftPM 模块或二进制隔离；Chat → Responses 暂保留现有共享配置与执行。完整分层、持久化兼容契约与可复现检查命令见[扩展架构与移除说明](extension-architecture.md)。
