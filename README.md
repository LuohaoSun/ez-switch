# EZ Switch

**轻量级 macOS 原生大模型反向代理工具。**

EZ Switch 常驻 macOS 菜单栏，在本机暴露一个 OpenAI / Anthropic 兼容入口。Codex、Claude Code、
ZCode 或任意 OpenAI-compatible 客户端只需要配置一次，之后可以在 EZ Switch 菜单中直接切换上游模型，
不需要修改 harness 配置文件，也不需要重启客户端。

旧版 `ModelRouter` 配置会在首次启动时自动复制到新配置目录，原文件不会被删除。

## 为什么用 EZ Switch

### 1. 热切换模型，不再反复改配置

Codex 等工具通常把模型和供应商写死在配置文件中。切换模型时，需要修改配置并重启。
EZ Switch 用固定的 **fake model id** 接入 harness，真实上游模型由菜单栏当前绑定的供应商决定。

在菜单栏点一下即可切换供应商模型，立即生效，无需修改 Codex 配置，也无需重启 Codex。

### 2. 所有供应商集中配置一次

API Key、Base URL、额外请求头和模型列表统一放在 EZ Switch 中管理，不必在 Codex、Claude Code、
ZCode 等每个 harness 里重复填写。新增供应商或更换 Key 时，只需要在 EZ Switch 改一次。

### 3. 原生、轻量、纯本地

EZ Switch 是 macOS 原生菜单栏应用，后端只依赖 `swift-nio`。服务默认只监听 `127.0.0.1`，
不经过第三方中转，也没有额外账号体系。

它是一个**纯反向代理**：不做协议翻译，不隐藏上游错误，也不改变请求和响应的业务字段。

## 快速开始

### 下载安装包

从 [GitHub Releases](https://github.com/LuohaoSun/ez-switch/releases) 下载 `EZSwitch-0.1.0.dmg`，打开磁盘映像后，将 `EZ Switch.app` 拖入
`Applications` 文件夹即可完成安装。当前发布包支持 macOS 13 及以上版本。

> 当前 DMG 使用 ad-hoc 签名，未经过 Apple Developer ID 公证。如果首次启动被 macOS 阻止，
> 请在 Finder 中右键 `EZ Switch.app` 并选择“打开”，或前往“系统设置 → 隐私与安全性”允许启动。

### 1. 构建并启动

```bash
./build-app.sh --install
```

也可以直接开发运行：

```bash
swift run
```

启动后菜单栏会出现 EZ Switch 图标，本地服务默认监听：

```text
http://127.0.0.1:8788
```

### 2. 添加供应商

打开菜单栏图标 → `设置…` → `供应商` → 右上角 `添加`。

填写：

- 供应商名称
- Chat Completions、Responses、Messages 三类接口是否启用
- 每个接口对应的完整 Base URL
- API Key 和可选额外请求头
- 该供应商下的模型 ID

API Key 按供应商统一设置，保存后应用到该供应商的全部模型。

### 3. 创建本机路由

进入 `模型` 页，新建一个 fake model id，例如：

```text
router-responses
```

然后把它绑定到某个供应商模型。Codex 请求这个 fake id 时，EZ Switch 会把它替换成真实的上游模型 ID。

### 4. 配置 harness

Codex 的 `~/.codex/config.toml`：

```toml
model = "router-responses"
model_provider = "ezswitch"
model_reasoning_effort = "medium"

[model_providers.ezswitch]
name = "EZ Switch"
base_url = "http://127.0.0.1:8788/v1"
wire_api = "responses"
env_key = "EZSWITCH_KEY"
```

```bash
export EZSWITCH_KEY=any-local-placeholder
codex
```

这里的 key 只是让 Codex 认为环境变量存在；真正请求上游时使用的 API Key 来自 EZ Switch 配置。

Claude Code：

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8788
export ANTHROPIC_AUTH_TOKEN=any-local-placeholder
export ANTHROPIC_MODEL=router-claude
claude
```

任意 OpenAI-compatible 客户端：

```text
base_url = http://127.0.0.1:8788/v1
api_key  = any-local-placeholder
model    = router-chat
```

### 5. 在菜单栏切换模型

点击菜单栏中的 EZ Switch 图标，选择某个 fake 路由对应的供应商模型。切换立即写盘并热生效。

## 支持的接口

| 本机接口（harness → EZ Switch） | 用途 | 上游路径 |
| --- | --- | --- |
| `/v1/chat/completions` | OpenAI Chat Completions | Base URL + `/chat/completions` |
| `/v1/responses` | OpenAI Responses / Codex | Base URL + `/responses` |
| `/v1/messages` | Anthropic Messages / Claude Code | Base URL + `/v1/messages` |

每类接口必须单独启用并配置 Base URL。收到请求时，如果对应当前路由的协议未启用，EZ Switch 返回 `502`，
不会尝试猜协议；已经启用但上游不支持时，上游错误会原样返回给 harness。

`GET /v1/models` 会返回当前全部 fake model id，兼容 Codex、Claude Code 和其他客户端做模型发现。

## 工作方式

EZ Switch 的核心行为只有三步：

1. 根据请求 body 中的 fake model id 找到当前绑定的供应商模型；
2. 只改写 body 里的 `model` 字段，其余字段原样保留；
3. 按入站协议重建认证头并转发请求，SSE 和普通响应均按字节流透传。

上游响应不会做通用改写。唯一例外是 Responses SSE：部分中转上游会交错发送输出项事件，导致 Codex
丢失文本增量；`Sources/EZSwitch/SSEReorder.swift` 会先把每个输出项的 `added…done` 收拢成完整块，
再按顺序写出。事件流本身规范时，这个步骤等价于逐事件透传。

## 设置窗口

- **模型**：管理 fake model id、路由排序和绑定的供应商模型。
- **供应商**：按供应商统一管理三类协议、Base URL、API Key、额外请求头和模型列表。
- **活动**：查看最近请求、状态码、耗时和错误。
- **通用**：设置端口、登录时启动、配置文件位置和日志窗口。

所有修改都会立即写回配置文件，并与手动编辑配置文件后的热重载等价。

## 配置文件

默认路径：

```text
~/Library/Application Support/EZSwitch/config.json
```

可通过环境变量覆盖：

```bash
EZSWITCH_CONFIG=/path/to/config.json swift run
```

配置示例：

```jsonc
{
  "port": 8788,
  "remotes": [
    {
      "id": "UUID",
      "name": "Provider · model",
      "apiKey": "sk-...",
      "model": "real-model-id",
      "extraHeaders": {},
      "apiEndpoints": {
        "chat": {
          "enabled": true,
          "baseURL": "https://api.example.com/v1"
        },
        "responses": {
          "enabled": true,
          "baseURL": "https://api.example.com/v1"
        },
        "messages": {
          "enabled": false,
          "baseURL": ""
        }
      }
    }
  ],
  "fakes": [
    {
      "id": "UUID",
      "fakeModelID": "router-responses",
      "displayName": "router-responses",
      "remoteID": "UUID"
    }
  ]
}
```

Base URL 是完整前缀。例如 OpenAI 填 `https://api.openai.com/v1`，EZ Switch 会请求
`https://api.openai.com/v1/responses`；GLM Coding Plan 的三类 Base URL 分别配置为：

```text
Chat      https://open.bigmodel.cn/api/coding/paas/v4
Responses https://open.bigmodel.cn/api/v1
Messages  https://open.bigmodel.cn/api/anthropic
```

旧版单 `baseURL` 配置会在加载时自动迁移。旧 Chat / Responses 地址会补齐 `/v1`，GLM Coding Plan
的旧 Anthropic 地址会自动展开成上述三类地址。

## 构建与测试

```bash
swift build
swift run

./build-app.sh             # 打包到 dist/EZSwitch.app
./build-app.sh --install   # 安装、重启并验证 /v1/models
./build-dmg.sh             # 构建可发布的 DMG（内含 Applications 快捷方式）
```

`swift test` 需要完整 Xcode。只安装 Command Line Tools 时 XCTest 不可用，但 `swift build` 可以正常运行。

打包使用 `Resources/Info.plist` 和 `AppIcon.icns`。`Package.swift` 显式声明 macOS 13 部署目标和 27.0 SDK，
用于保留新版 macOS 窗口外观和液态玻璃效果。

## 已知限制

- 只监听 `127.0.0.1`，无鉴权，定位为本机开发工具。
- 修改端口需要重启应用。
- 不做协议转换，也不预先探测上游能力。
- 一个路由同一时间只绑定一个上游模型；暂无负载均衡、重试和熔断。
- Codex 的 encrypted reasoning 内容绑定上游密钥，切换供应商后建议新开会话。
- 上游响应会移除 `content-length`、`content-encoding` 和 hop-by-hop 头；其余内容按流透传。
- 客户端断开时，EZ Switch 会同步取消上游请求，避免继续消耗 token。

## 许可证

本项目采用 [MIT License](LICENSE)。
