# Token 用量统计

## 范围与口径

用量页只统计经过当前 EZ Switch 实例的模型请求，从启用此功能后开始记录。它不是供应商账单，也不会读取客户端的历史会话、提示词或回答内容。

- **请求数**：已经尝试调用上游的客户端模型请求数。一个请求发生自动切换时仍记一次。
- **上游尝试**：每次调用候选模型单独记录。失败、取消及中断的尝试也保留；它们可能产生用量。
- **输入与输出**：来自上游响应的 `usage`，不根据文本长度估算。缺失字段保留为空，不当作零；显式的零是有效用量。
- **缓存命中与写入**：输入的细分。OpenAI 风格接口通常已经把缓存计入输入；Anthropic 的普通输入、缓存读取和缓存写入需要归一化为总输入。统计时不能把缓存再次加到总量上。
- **推理 tokens**：输出的细分，仅在上游提供时记录，不重复计入总量。
- **覆盖率**：输入、输出均已获得的上游尝试数占全部尝试的比例。显示的 token 合计是已获得的部分，存在未知用量时不代表全部实际消耗。

流式事件中的累计用量取最新有效值，不逐条相加。Chat Completions、Responses、Messages 的流式和普通 JSON 响应分别适配。协议转换保留原始上游的用量，不能把转换器补出的零当作真实 usage。Chat 流式请求未指定 `stream_options.include_usage` 时会补为 `true`，显式值（包括 `false`）保留；供应商不支持该选项时仍按原有规则返回错误，不额外重试。DeepSeek 的 `prompt_cache_hit_tokens` 也可用于缓存命中统计。

解析器限制单个 SSE 事件为 1 MiB、非流式响应缓冲为 16 MiB，超过限制的用量可能显示未知，但不会因此截断客户端响应。数据库无法写入期间的记录可能丢失，恢复后继续记录，不追补缺失历史。

## 页面

侧栏「用量」提供今日、近 7 天、本月和自定义日期范围。日期按本机时区计算，结束日期包含当天。输入与输出按日绘制堆叠趋势图，明细可按路由、供应商或实际模型分组。菜单中的今日用量可直接打开此页。

侧栏「性能」是独立入口，按日期区间展示同一数据源下流式请求的首输出延迟（TTFT）与吞吐（TPS），口径见下文「性能统计」。

CSV 导出保留所选时间范围内的逐次上游尝试记录。缓存和推理字段在导出中单独保留。导出不包含 API Key、请求头、提示词或回答正文。清空记录需要在界面确认，不修改路由配置。

## 命令行

安装命令行工具后可用 `ezs usage` 在终端查看同一份用量数据，需要 EZ Switch 正在运行（与 `ezs list`／`ezs set` 一致）：

```bash
ezs usage                                   # 今天，按路由分组，最多 100 组
ezs usage --period 7d --group provider      # 近 7 天，按供应商分组
ezs usage --from 2026-01-01 --to 2026-01-31 --limit 1000
ezs usage --json                            # 只输出 usage 对象
ezs usage --performance                     # 追加流式性能（TTFT/TPS），默认按模型分组
ezs usage --performance --group route --json
```

- `--period today|7d|month`：预设区间，默认 `today`。`7d` 含今天及前 6 个自然日。
- `--from`／`--to`：自定义区间，必须成对且不能与 `--period` 同时出现；日期按 `YYYY-MM-DD`，`--to` 含当天，实际日历有效性由应用校验。
- `--group route|provider|model` 与 `--limit 1..1000`：分组维度与最大分组数，默认 `route`、`100`；被截断时提示 `showing N of M groups`。
- `--performance`：在用量报告之外追加流式性能统计（TTFT/TPS）；未显式给出 `--group` 时性能默认按 `model` 分组，普通用量默认仍是 `route`。见下文「性能统计」。
- `--json`：输出日期范围、总量、每日趋势、分组明细和报告覆盖率，Token 数值保留精确整数。分组限制只影响明细行，不改变总量或每日趋势；加 `--performance` 时输出 `{"usage": …, "performance": …}` 两个对象。

文本输出给出精确的输入／输出／合计、缓存与推理细分、请求数、上游尝试、失败尝试与覆盖率，并列出每日趋势与分组摘要。覆盖率不足时明确标注合计为已上报部分、不是估算。空区间显示 `No usage recorded`，表示该范围内确实没有记录，而不是数据缺失。分组名称中的控制字符会被转义，避免终端转义序列注入；输出不含 API Key 或本机路径。旧版本应用不支持 `usage` 时会提示更新并重启。

`--performance` 与既有参数完全复用：区间、分组、`--limit` 语义一致，`--limit` 同样只截取性能分组明细、保留全量 summary。应用端仅在请求明确带 `performance` 时才查询并返回性能对象；不带该字段的旧调用保持一致。旧版应用忽略该字段、不会返回 `performance`，此时 CLI 会明确提示 `does not support performance stats; update and restart`，而不是把缺失当成 0。

## 性能统计（TTFT 与 TPS）

`--performance` 报告流式请求的**首输出延迟（TTFT）**与**输出速率（TPS）**，用于比较实际使用表现，不是供应商计费或模型内部解码速率的度量。

- **测量范围**：原生 Responses、Chat Completions、Anthropic Messages，以及经桥接转换的路由，均按**原始上游响应**测量；协议转换补出的事件不参与统计。
- **TTFT**：从开始准备该次上游请求到收到**首个非空正文、推理或工具参数片段**的毫秒数。心跳、仅含角色或生命周期信息的事件不计入。流式片段可能包含多个 token，无法据此还原模型内部的首 token 生成时刻。
- **TPS**：`上游报告的输出 token 数 ÷（首个有效输出片段到上游响应体正常结束）`，单位为 tok/s。计数可能包含未对外流出的推理 token，时间窗口包含尾部与网络收尾，因此只表示代理观测到的平均速率，不代表内部解码速度或屏幕上的文字出现速度。
- **有效样本**：TPS 需要有效 TTFT、输出 tokens ≥ 2、有效输出事件 ≥ 2 且完整生成窗口大于零。默认分位数只纳入成功完成的流式尝试；失败或取消时仍保留已观测到的原始计时，但不纳入分位数。缺少输出 token 计数时只贡献 TTFT。超限或解析丢失导致无法可靠测量时，对应指标留空。
- **requestTTFT 与 attemptTTFT**：按 `route` 分组时展示 **requestTTFT**，从路由器收到完整请求并进入候选尝试阶段开始计时，包含自动回退等待；按 `provider`／`model` 分组时展示 **attemptTTFT**，仅包含该次上游尝试自身的首输出等待。两者都在原始上游流上测量，后续输出翻译、事件重排及客户端渲染延迟不属于该口径。
- **样本数**：TTFT samples 与展示口径一致——`route` 分组为 request 级样本数（JSON `requestTTFTSamples`），`provider`／`model` 分组为上游 attempt 样本数（`ttftSamples`）。两者可能不同；request 级样本缺失时按 0 显示并给出 warning，绝不用上游样本数冒充路由样本。TPS samples 独立统计。
- **分位数**：P50／P95 使用 nearest-rank，样本不足时按已有样本计算。时间清楚标注单位（`ms` 或 `s`），TPS 单位为 `tok/s`。
- **无样本**：没有对应样本时显示 `—`，JSON 中对应字段为 `null`，绝不显示为 0。
- **历史**：早于本功能开始记录的历史尝试没有性能数据，与「无样本」一致；统计不持久化任何提示词或回答正文，只保留时延与 token 计数。

命令行文本会先打印完整用量报告，再追加一段性能报告，例如：

```text
Performance (model)
TTFT basis: upstream attempt

Summary
  Attempts: 12
  Successful streaming: 9/12 attempts
  TTFT samples: 9  TPS samples: 8
  TTFT P50: 480 ms  TTFT P95: 2.40 s
  TPS P50: 42.3 tok/s

Groups
  deepseek-v4.1-flash (command-wsz)
    Attempts 12  Successful streaming 9/12 attempts
    TTFT samples 9  TPS samples 8
    TTFT P50 480 ms  P95 2.40 s  TPS P50 42.3 tok/s
```

按 `route` 分组时，标题下方提示 `TTFT basis: request (includes fallback)`，展示 requestTTFT。

## 存储与安装

使用 macOS 自带的 SQLite，无需额外服务或第三方数据库安装。数据库放在当前配置文件所在目录的 `usage.sqlite`；默认位置是：

```text
~/Library/Application Support/EZSwitch/usage.sqlite
```

指定 `EZSWITCH_CONFIG` 的预览实例拥有自己的数据库。测试必须传入临时路径，不能访问正式数据库。

数据库采用 WAL 模式，可能同时存在 `usage.sqlite-wal` 与 `usage.sqlite-shm`。运行中备份应使用 SQLite 备份机制，而不是单独复制主文件。替换 `.app` 不会覆盖数据库，删除 `.app` 也不会自动删除统计历史。

记录和查询在独立串行队列执行。数据库不可写、损坏或版本不兼容时，统计显示错误，转发继续运行；不自动删除或重建历史数据库。首版保留逐次记录，提供手动清空；自动保留期限和历史压缩尚未启用。

供应商和模型使用调用当时的名称快照，后续配置改名不改写历史记录。费用估算和客户端识别不在本版范围内。

## 开发验收

- CLI 用量查询验收（2026-10-09）：完整测试通过应用端 246 项（33 个套件）和 CLI 端 52 项（5 个套件），合计 298 项；Release 构建通过。独立实例在端口 19017 经模拟上游 19018 转发 12 个请求、记录 13 次尝试，`ezs usage` 查询结果与数据库的输入 232、输出 94、合计 326 和覆盖率 10/13 一致。实际核对三种分组、分组截取保留总量、今日/近 7 天/本月、结束日包含与倒置日期、自定义空范围、无效参数、JSON 输出以及原有 list/set。查询未改动配置，独立实例和临时应用已清理，正式服务保持运行。
- 历史用量页面验收：`swift test` 160 项测试、24 个套件通过，包含流式中断、fallback 去重、HTTP 连续请求顺序、数据库恢复和日期边界。
- `swift build -c release`：构建成功；在当前 macOS 主机完成运行验收，尚未在 macOS 13 真机验证。
- `python3 Tools/UsagePreview/verify_usage.py full --no-mock`：最终 Release 通过 12 个本机模拟请求，记录 13 次上游尝试，输入 232、输出 94、合计 326；3 次未上报用量保留为空。
- 原生页面核对了时间范围、路由/供应商/模型分组、趋势日期、CSV 导出与确认清空。数据库路径不可写时，两次实际转发仍返回 200。
- 发布打包验收（2026-10-09，v0.3.2 build 12）：`swift test` 应用端 246 项（33 套件）与 CLI 端 52 项（5 套件）合计 298 项通过；Go bridge/translator 未缓存测试 `go test -count=1` 5 项通过。`./build-dmg.sh` 全量构建成功（未安装）（现入口：`./Scripts/build-dmg.sh`），`dist/EZSwitch-0.3.2.dmg` 通过 `hdiutil verify`，SHA-256 `4e0f43766c15746338814f973ecfe82386c7f02ec1565abba102ae242fe9001f`；ad-hoc 签名 deep-strict 校验通过，CFBundle 0.3.2（build 12），随包 `ezs --help` 正常。只读挂载校验根目录仅 `EZSwitch.app` 与 `Applications` 符号链接；随包许可证与来源逐字节一致：Go 26 个模块 `modules.json`、Swift 4 个固定包及 SwiftNIO NOTICE、根 MIT `LICENSE.txt`。构建后清理 `dist/EZSwitch.app` 与 `dist/dmg-staging`，仅保留 DMG、校验文件和既有配置；正式服务保持运行。

独立预览位于 `dist/UsagePreview.noindex/EZSwitch-UsagePreview.app`，使用端口 19007、模拟上游端口 19008 和 `/tmp/ezswitch-usage-preview/` 下的配置及数据库。演示记录来自真实的本机 HTTP 调用，没有导入正式密钥或历史。该预览不替换 `/Applications/EZSwitch.app`。
