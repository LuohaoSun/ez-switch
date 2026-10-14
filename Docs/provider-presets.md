# 供应商预设（Provider Presets）

`Sources/EZSwitch/ProviderPreset.swift` 是“新建供应商”时可一键带入的纯数据目录。
它只描述连接配置，不含任何密钥；API Key 由用户在新增供应商时填写。

## UI 契约

```swift
struct ProviderPreset: Identifiable {
    let id: String          // 稳定目录 id
    let name: String        // 显示名（不含 " · "）
    let iconName: String    // 稳定品牌图标 id（见下）
    let endpoints: APIEndpointSettings
    let extraHeaders: [String: String]
    var aliases: [String] = []   // 搜索别名
}
```

- `static let all: [ProviderPreset]`：全部预设，顺序即建议展示顺序。
- 搜索：`preset.matches(query:)`（name / id / aliases，大小写不敏感；空查询匹配全部）。UI 用
  `ProviderPreset.all.filter { $0.matches(query: q) }` 即可，不再另设 helper。
- 图标资源：`Resources/ProviderIcons/<iconName>.png`。

## Base URL 拼接规则（重要）

路由器把每个协议的 Base URL 当作**完整前缀**，直接拼接协议相对路径
（`EndpointKind.upstreamPath`，见 `Forwarder.upstreamURL`）：

| 协议 | 相对路径 | 最终 URL |
| --- | --- | --- |
| Chat Completions | `/chat/completions` | `base + /chat/completions` |
| Responses | `/responses` | `base + /responses` |
| Messages | `/v1/messages` | `base + /v1/messages` |
| Gemini 原生 | `/models/{model}:generateContent` | `base + /models/{model}:generateContent` |

因此 **Messages 的 base 不能以 `/v1` 结尾**，否则会拼出 `/v1/v1/messages`。
例：Command Code 的 Chat/Responses base 是 `https://api.commandcode.ai/provider/v1`，
其 Messages base 是 `https://api.commandcode.ai/provider`（最终 `…/provider/v1/messages`）。

**Gemini 原生**的 base 到版本前缀 `/v1beta` 为止，模型 ID 取自入站路径
（本机 `POST /v1beta/models/main:generateContent`）；预设为
`https://generativelanguage.googleapis.com/v1beta`，路由器拼接
`/models/{远端模型 ID}:generateContent`，base 不能再以 `/v1beta` 之外的版本段或 `/models` 结尾。

## 预设清单

| id | 名称 | iconName | Chat / Responses / Messages / Gemini 原生 base |
| --- | --- | --- | --- |
| `zhipu-coding` | 智谱 Coding | `zhipu` | `https://open.bigmodel.cn/api/coding/paas/v4` / — / `https://open.bigmodel.cn/api/anthropic` / — |
| `zai-coding` | Z.AI Coding | `zai` | `https://api.z.ai/api/coding/paas/v4` / — / `https://api.z.ai/api/anthropic` / — |
| `opencode-zen` | OpenCode Zen | `opencode` | `https://opencode.ai/inference/v1` / `https://opencode.ai/inference/v1` / `https://opencode.ai/inference` / — |
| `opencode-go` | OpenCode Go | `opencode` | `https://opencode.ai/zen/go/v1` / — / `https://opencode.ai/zen/go` / — |
| `commandcode` | Command Code | `commandcode` | `https://api.commandcode.ai/provider/v1` / `https://api.commandcode.ai/provider/v1` / `https://api.commandcode.ai/provider` / — |
| `openai` | OpenAI | `openai` | `https://api.openai.com/v1` / `https://api.openai.com/v1` / — / — |
| `anthropic` | Anthropic | `anthropic` | — / — / `https://api.anthropic.com` / — |
| `gemini` | Gemini | `google` | `https://generativelanguage.googleapis.com/v1beta/openai` / — / — / `https://generativelanguage.googleapis.com/v1beta` |
| `deepseek` | DeepSeek | `deepseek` | `https://api.deepseek.com/v1` / — / `https://api.deepseek.com/anthropic` / — |
| `kimi` | Kimi | `kimi` | `https://api.moonshot.cn/v1` / — / — / — |
| `kimi-coding` | Kimi Coding | `kimi` | `https://api.kimi.com/coding/v1` / — / `https://api.kimi.com/coding` / — |
| `minimax` | MiniMax（国内） | `minimax` | `https://api.minimax.cn/v1` / — / `https://api.minimax.cn/anthropic` / — |
| `minimax-overseas` | MiniMax（海外） | `minimax` | `https://api.minimax.io/v1` / — / `https://api.minimax.io/anthropic` / — |
| `bailian` | 阿里云百炼 | `alibaba` | `https://dashscope.aliyuncs.com/compatible-mode/v1` / — / `https://dashscope.aliyuncs.com/apps/anthropic` / — |
| `siliconflow` | SiliconFlow | `siliconflow` | `https://api.siliconflow.cn/v1` / — / `https://api.siliconflow.cn` / — |
| `openrouter` | OpenRouter | `openrouter` | `https://openrouter.ai/api/v1` / `https://openrouter.ai/api/v1` / `https://openrouter.ai/api` / — |

“—”：该协议未启用，原因见“未启用协议”。

## 图标 key

同品牌套餐共用同一 `iconName`；`id` 与 `iconName` 不一一对应。

| iconName | 覆盖预设 |
| --- | --- |
| `zhipu` | 智谱 Coding |
| `zai` | Z.AI Coding |
| `opencode` | OpenCode Zen、OpenCode Go |
| `commandcode` | Command Code |
| `openai` | OpenAI |
| `anthropic` | Anthropic |
| `google` | Gemini |
| `deepseek` | DeepSeek |
| `kimi` | Kimi、Kimi Coding |
| `minimax` | MiniMax（国内）、MiniMax（海外） |
| `alibaba` | 阿里云百炼 |
| `siliconflow` | SiliconFlow |
| `openrouter` | OpenRouter |

## 额外请求头

- OpenCode Zen / Go：仅固定 `x-opencode-client: ezswitch`。**不预填** `x-opencode-session` /
  `x-opencode-project` / `x-opencode-request`，也不生成固定 UUID；这些逐会话字段由客户端传入并原样透传
  （`Forwarder.buildRequest`）。预设不伪装成 opencode 客户端。
- 其余预设 `extraHeaders` 为空；鉴权头由路由器按协议统一生成（Chat/Responses 用 `Authorization: Bearer`，
  Messages 用 `x-api-key` + `anthropic-version`，Gemini 原生用 `x-goog-api-key`）。额外头最后应用，可覆盖以上任意值。

## Gemini 原生

- 同时启用 Chat 与 Gemini 原生时（预设默认如此），模型列表查询优先走原生
  `GET {base}/models`（`https://generativelanguage.googleapis.com/v1beta/models`），带 `x-goog-api-key`，
  按 `nextPageToken` → `pageToken` 分页（URLComponents 安全拼接，不跟随上游返回的任意 URL），
  只保留 `supportedGenerationMethods` 含 `generateContent` 的模型，去掉单层 `models/` 前缀后合并、去重、排序；
  有最大页数与 token 去重兜底。
- 边界：仅覆盖 Gemini Generative Language API 的 `generateContent` 文本生成与 `models` 列表；
  不含 Vertex AI、`files`、Live API 与翻译等其它方法。

## 端点来源（官方页面）

| 供应商 | 官方 URL |
| --- | --- |
| 智谱 Coding、Z.AI Coding | https://zcode.z.ai/en/docs/configuration |
| OpenCode Zen | https://opencode.ai/docs/zen （Endpoints 段：`https://opencode.ai/inference/v1/{chat/completions,responses,messages}`） |
| OpenCode Go | https://opencode.ai/docs/go （官方 Go 文档 Endpoints 段；base `https://opencode.ai/zen/go/v1`） |
| Command Code | https://commandcode.ai/docs/provider |
| OpenAI | https://developers.openai.com/api/reference/overview （base `https://api.openai.com/v1`；Responses 参考 `/v1/responses`） |
| Anthropic | https://platform.claude.com/docs/en/api/messages （`POST /v1/messages`） |
| Gemini 原生 | https://ai.google.dev/api/generate-content （`POST /v1beta/models/{model}:generateContent`）；https://ai.google.dev/api/models （`GET /v1beta/models`，`nextPageToken` 分页、`supportedGenerationMethods`）；https://ai.google.dev/api/tokens （`countTokens`）；https://ai.google.dev/gemini-api/docs/api-key （`x-goog-api-key`） |
| Gemini（OpenAI 兼容） | https://ai.google.dev/gemini-api/docs/openai （base `…/v1beta/openai`，仅 chat/embeddings） |
| DeepSeek | https://api-docs.deepseek.com/guides/anthropic_api （Anthropic base `https://api.deepseek.com/anthropic`）；https://api-docs.deepseek.com （OpenAI base） |
| Kimi、Kimi Coding | https://www.kimi.com/code/docs/en/ （Kimi Code：OpenAI `https://api.kimi.com/coding/v1`、Anthropic `https://api.kimi.com/coding/`；Kimi 开放平台 `https://api.moonshot.cn/v1`） |
| MiniMax（国内） | https://platform.minimax.cn/docs/api-reference/text-openai-api （`https://api.minimax.cn/v1`）；https://platform.minimax.cn/docs/api-reference/text-anthropic-api （`https://api.minimax.cn/anthropic`） |
| MiniMax（海外） | https://platform.minimax.io/docs/api-reference/text-openai-api （`https://api.minimax.io/v1`）；https://platform.minimax.io/docs/api-reference/text-anthropic-api （`https://api.minimax.io/anthropic`） |
| 阿里云百炼 | https://help.aliyun.com/zh/model-studio/claude-code （总域 Anthropic base `https://dashscope.aliyuncs.com/apps/anthropic`，另有按量/套餐的区域专址）；https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope （OpenAI 兼容 `…/compatible-mode/v1`，总域 `https://dashscope.aliyuncs.com` 仍可用） |
| SiliconFlow | https://docs.siliconflow.cn/cn/usercases/use-siliconcloud-in-ClaudeCode （`ANTHROPIC_BASE_URL=https://api.siliconflow.cn/`）；OpenAI 兼容 base `https://api.siliconflow.cn/v1` |
| OpenRouter | https://openrouter.ai/docs/api-reference/overview （Chat `/api/v1/chat/completions`）；https://openrouter.ai/docs/api_reference/responses/overview （Responses `https://openrouter.ai/api/v1/responses`）；https://openrouter.ai/docs/api_reference/errors-and-debugging （Anthropic Messages `/api/v1/messages`） |

## 未启用协议

未获官方文档确认的协议一律禁用，不做猜测：

- **OpenAI**：不提供 Messages。
- **Anthropic**：只提供 Messages。
- **Gemini 的 Responses**：Google OpenAI 兼容仅覆盖 chat completions（与 embeddings），无 Responses；原生侧只做 `generateContent`，不含 Vertex / files / Live / 翻译。
- **Kimi（按量）**：Kimi 开放平台文档只列 OpenAI 兼容 base；Anthropic 兼容属 Coding 套餐，与按量不混用，故 Messages 禁用（Coding 单独为 `kimi-coding`）。
- **OpenCode Go 的 Responses**：官方 Go 文档（https://opencode.ai/docs/go ）Endpoints 段未列出 Responses，故禁用（Zen 的 Responses 已按官方 `/inference/v1` 启用）。

## OpenCode Zen / Go

- **Zen**：官方文档 https://opencode.ai/docs/zen 的 Endpoints 段列出
  `https://opencode.ai/inference/v1/chat/completions`、`…/responses`、`…/messages`。
  预设据此启用 chat / responses / messages 三种协议（base `https://opencode.ai/inference/v1`，
  messages base `https://opencode.ai/inference`）。别名含 `console`。
- **Go**：官方 Go 文档 https://opencode.ai/docs/go 有独立 Endpoints 段，base 为 `https://opencode.ai/zen/go/v1`
  （与 `Forwarder.buildRequest` 对 `/zen/go/v1/` 的处理一致；Docker 的 OpenCode Go 集成文档
  https://docs.docker.com/ai/docker-agent/providers/opencode-go 亦记录同一 OpenAI 兼容 base）。
  Go 仅 chat 与 messages。
- **未修改 `Forwarder`**：其 `/zen/go/v1/` user-agent 兜底仍只作用于 Go；Zen 走 `/inference/v1` 不受影响。
  Zen 是新增 catalog，不改动现有用户配置。

## 测试

`Tests/EZSwitchTests/ProviderPresetTests.swift` 覆盖：目录合法性与唯一性、不含凭据、协议 URL 拼接
（含 Messages 不出现 `/v1/v1`）、Command Code 的版本段拆分、OpenCode 不固化会话 ID 且动态透传、
`preset → addProvider` 持久化、模型列表请求 URL/头、转发链 URL 与鉴权头。测试不发带真实密钥的网络请求。

`Tests/EZSwitchTests/GeminiProviderTests.swift` 补充 Gemini：预设 id/name/icon 与 chat+native 端点、
原生目录请求 URL 与 `x-goog-api-key`、`nextPageToken` 分页合并与去重（注入 mock URLSession，不换全局）、
`generateContent` 过滤、`models/` 前缀与非法名处理、循环 token 兜底、UI Base URL 示例。
