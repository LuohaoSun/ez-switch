# EZ Switch

**轻量级 macOS 原生大模型反向代理工具。**

EZ Switch 在本机提供 OpenAI / Anthropic 兼容接口。Codex、Claude Code、ZCode 等工具只需配置一次固定模型 ID；之后在 EZ Switch 中切换真实供应商和模型，立即生效，不需要修改 harness 配置或重启客户端。

## 为什么用 EZ Switch

- **热切换模型**：工具侧始终请求固定的本机模型 ID，真实上游模型可在 GUI 或菜单栏中随时切换。
- **集中管理供应商**：API Key、Base URL、请求头和模型列表统一放在 EZ Switch，不需要在每个工具里重复配置。
- **本地原生应用**：macOS 原生 GUI，服务只监听 `127.0.0.1`，请求直接转发到配置的上游。

## 安装

从 [GitHub Releases](https://github.com/LuohaoSun/ez-switch/releases) 下载最新 `EZSwitch-*.dmg`，打开后将 `EZ Switch.app` 拖入 `Applications` 文件夹。要求 macOS 13 或以上。

> 当前 DMG 使用 ad-hoc 签名，未经过 Apple Developer ID 公证。首次启动如被阻止，请在 Finder 中右键应用并选择“打开”，或在“系统设置 → 隐私与安全性”中允许。

## 使用

首次启动会打开设置窗口，并预置 `DeepSeek官方` 和 `OpenAI官方` 两个供应商示例。进入“供应商”页，选择对应供应商并填写自己的 API Key；默认模型和 Base URL 可以按需修改。

本地服务默认地址：

```text
http://127.0.0.1:8788
```

### 1. 配置供应商

在“供应商”页添加或编辑供应商：

- 供应商名称和模型 ID
- Chat Completions、Responses、Messages 三类接口是否启用
- 每类接口对应的完整 Base URL
- API Key 和可选额外请求头

同一供应商的 API Key 和接口配置统一生效，供应商下的全部模型共用。

### 2. 配置路由

首次启动会预置一个固定的本机模型 ID：

```text
main
```

`main` 会绑定到需要的供应商模型。Codex、OpenAI-compatible 工具和 Claude Code 都使用这个 ID；切换 `main` 的上游目标后，所有工具立即使用新目标。

### 3. 接入工具

Codex 示例配置：

```toml
model = "main"
model_provider = "ezswitch"

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

这里的 key 只用于满足工具的启动检查；真实上游 API Key 保存在 EZ Switch 中。

其他 OpenAI-compatible 工具可填写：

```text
base_url = http://127.0.0.1:8788/v1
api_key  = any-local-placeholder
model    = main
```

Claude Code 可设置：

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8788
export ANTHROPIC_AUTH_TOKEN=any-local-placeholder
export ANTHROPIC_MODEL=main
claude
```

## 切换模型

点击菜单栏中的 EZ Switch 图标，选择某个本机模型 ID 对应的供应商模型即可。切换立即写盘并生效；正在运行的请求不会被中断。

## 支持的接口

| 本机接口 | 用途 | 上游路径 |
| --- | --- | --- |
| `/v1/chat/completions` | OpenAI Chat Completions | Base URL + `/chat/completions` |
| `/v1/responses` | OpenAI Responses / Codex | Base URL + `/responses` |
| `/v1/messages` | Anthropic Messages / Claude Code | Base URL + `/v1/messages` |

每类接口需在供应商设置中单独启用并填写 Base URL。EZ Switch 不做协议转换；上游不支持某类接口时，会原样返回上游错误。

## 配置与限制

配置文件路径：

```text
~/Library/Application Support/EZSwitch/config.json
```

- 服务只监听本机，不提供远程访问和鉴权。
- 修改端口后需要重启应用。
- 一个路由同一时间绑定一个上游模型，暂无负载均衡、重试和熔断。
- 不翻译 API 协议，不隐藏上游错误。

## 许可证

[MIT License](LICENSE)
