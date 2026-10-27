# Token 用量统计

## 范围与口径

用量页只统计经过当前 EZ Switch 实例的模型请求，从启用此功能后开始记录。它不是供应商账单，也不会读取客户端的历史会话、提示词或回答内容。

- **请求数**：已经尝试调用上游的客户端模型请求数。一个请求发生自动切换时仍记一次。
- **上游尝试**：每次调用候选模型单独记录。失败、取消及中断的尝试也保留；它们可能产生用量。
- **输入与输出**：来自上游响应的 `usage`／`usageMetadata`，不根据文本长度估算。缺失字段保留为空，不当作零；显式的零是有效用量。原生 Gemini 的输入是 `promptTokenCount` 与 `toolUsePromptTokenCount` 之和（`promptTokenCount` 已包含缓存内容），输出是 `candidatesTokenCount` 与 `thoughtsTokenCount` 之和，因此标准字段齐全时本页合计与上游 `totalTokenCount`（prompt + tool-use prompt + thoughts + candidates）一致。
- **缓存命中与写入**：输入的细分。OpenAI 风格接口通常已经把缓存计入输入；Anthropic 的普通输入、缓存读取和缓存写入需要归一化为总输入；Gemini 的 `cachedContentTokenCount` 已包含在 `promptTokenCount` 内，同样不再加一次。统计时不能把缓存再次加到总量上。
- **缓存命中率**：已上报的缓存命中 token ÷ 已上报的输入 token（缓存是输入的子集）。上游没上报过输入、没上报过缓存，或输入合计为 0 时命中率未知，页面显示「—」，不会用精确的 0% 冒充缺失。只有部分上游尝试上报了缓存用量时，比值只按已上报部分计算，指标卡会标明「部分上报」并在提示里给出已上报缓存与已上报输入的确切数值；它不是逐请求配对样本的平均值。
- **推理 tokens**：输出的细分，仅在上游提供时记录，不重复计入总量。Gemini 的 `thoughtsTokenCount` 是输出的一部分，同时作为推理子项单独记录。
- **覆盖率**：输入、输出均已获得的上游尝试数占全部尝试的比例。显示的 token 合计是已获得的部分，存在未知用量时不代表全部实际消耗。

流式事件中的累计用量取最新有效值，不逐条相加。Gemini 的输入／输出分量（prompt、tool-use prompt、candidates、thoughts）各自独立保留上次有效值：后续累计快照省略已上报的可选分量时不会把它从合计里丢掉，只有显式 `0` 才重置，无效值不覆盖，从未上报的可选分量按 0 计入其所属合计。Chat Completions、Responses、Messages、原生 Gemini（`generateContent` 与 `streamGenerateContent`）的流式和普通 JSON 响应分别适配。Gemini 非 SSE 的 `streamGenerateContent` 会在完整的有界缓冲内按 JSON 数组解析，取最后一个累计快照；`:countTokens` 返回的 `totalTokens` 只是输入预估，不计入生成用量，也不进性能样本。协议转换保留原始上游的用量，不能把转换器补出的零当作真实 usage。Chat 流式请求未指定 `stream_options.include_usage` 时会补为 `true`，显式值（包括 `false`）保留；供应商不支持该选项时仍按原有规则返回错误，不额外重试。DeepSeek 的 `prompt_cache_hit_tokens` 也可用于缓存命中统计。Gemini 仅在能确定一侧、另一侧缺失时才用权威 `totalTokenCount` 推导缺失的一侧，绝不产生负数，也不覆盖已确定的字段；无法解析的用量保持未知。

解析器限制单个 SSE 事件为 1 MiB、非流式响应缓冲为 16 MiB，超过限制的用量可能显示未知，但不会因此截断客户端响应。数据库无法写入期间的记录可能丢失，恢复后继续记录，不追补缺失历史。

## 页面

侧栏「用量」提供今天、近 7 天、近 30 天和自定义四个区间预设。区间按本机时区计算并包含当天；自定义是紧凑的“近 N 个自然日”输入（含今天），不使用日期选择器。选中「今天」时输入与输出按本机时区的小时绘制堆叠趋势图，其余区间按自然日绘制。明细可按路由、供应商或实际模型分组，每行在缓存数量后显示缓存率（未知为「—」）。菜单中的今日用量可直接打开此页。

点击图表中的某根柱（小时或自然日）会把上方的总览卡片与下方的使用明细都收敛到该小时／该日；图表本身始终保留整个区间的序列，选中后其余柱依然可以点选。标题旁会出现所选时段的指示与清除按钮；再次点击同一根柱、点清除按钮或点坐标轴留白处都会回到整个区间。切换时间区间（含自定义天数）、切换视图或图表粒度（今天按小时、其余按天）都会重置所选柱——旧柱在新区间或新粒度下不再成立。总览卡片另含「缓存命中率」指标，口径见上文「范围与口径」。

侧栏「性能」是独立入口，复用用量页的同一组区间预设，展示同一数据源下的请求数与流式请求的首输出延迟（TTFT）、吞吐（TPS），口径见下文「性能统计」。请求数按 `request_id` 去重（一个请求自动回退多次只计一次），以指标卡、柱状图（今天按小时、其余按天，与用量页同一图表外壳）与「性能明细」表的「请求」列三种粒度展示；有转发记录但暂无性能样本时，请求数照常展示，TTFT／TPS 显示「—」并附提示条。点击柱状图中的某根柱会把指标卡与性能明细收敛到该时段（图表本身仍保留整段），再次点击同一根柱、点标题旁的清除按钮或点坐标轴留白处回到整段；请求数为 0 的柱不可选，没有性能样本的时段会显示「暂无样本」提示而不是空页。有效样本数不单独占列，数值悬停可查看该分组的 TTFT／TPS 样本数，顶部均值卡显示所选范围的总样本数。「性能明细」表点击列头排序：首次点击按该列默认方向（延迟类升序、吞吐类降序），再次点击同一列反向，未测或未知的样本恒定置后。

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
- `--performance`：在用量报告之外追加流式性能统计（TTFT 与含 TTFT 的 TPS）；未显式给出 `--group` 时性能默认按 `model` 分组，普通用量默认仍是 `route`。见下文「性能统计」。
- `--json`：输出日期范围、总量、每日趋势、分组明细和报告覆盖率，Token 数值保留精确整数。分组限制只影响明细行，不改变总量或每日趋势；加 `--performance` 时输出 `{"usage": …, "performance": …}` 两个对象。

文本输出给出精确的输入／输出／合计、缓存与推理细分、请求数、上游尝试、失败尝试与覆盖率，并列出每日趋势与分组摘要。覆盖率不足时明确标注合计为已上报部分、不是估算。空区间显示 `No usage recorded`，表示该范围内确实没有记录，而不是数据缺失。分组名称中的控制字符会被转义，避免终端转义序列注入；输出不含 API Key 或本机路径。旧版本应用不支持 `usage` 时会提示更新并重启。

`--performance` 与既有参数完全复用：区间、分组、`--limit` 语义一致，`--limit` 同样只截取性能分组明细、保留全量 summary。应用端仅在请求明确带 `performance` 时才查询并返回性能对象；不带该字段的旧调用保持一致。旧版应用忽略该字段、不会返回 `performance`，此时 CLI 会明确提示 `does not support performance stats; update and restart`，而不是把缺失当成 0。

## 性能统计（TTFT 与 TPS）

`--performance` 报告流式请求的**首输出延迟（TTFT）**与**输出速率（TPS）**，用于比较实际使用表现，不是供应商计费或模型内部解码速率的度量。

- **测量范围**：原生 Responses、Chat Completions、Anthropic Messages、原生 Gemini SSE，以及经桥接转换的路由，均按**原始上游响应**测量；协议转换补出的事件不参与统计。
- **TTFT**：从开始准备该次上游请求到收到**首个非空正文、推理或工具参数片段**的毫秒数。心跳、仅含角色或生命周期信息的事件不计入。Gemini 按 `candidates[].content.parts[]` 判定：非空 `text`（含 `thought: true` 的思考文本）、非空名称的 `functionCall`（零参数工具可省略 `args` 或传 `{}`）、以及有效的 `inlineData` 多模态结果都算有效输出；仅 `thoughtSignature`、空 part、`safetyRatings`／`finishReason`／`role` 或仅用量事件不计入。流式片段可能包含多个 token，无法据此还原模型内部的首 token 生成时刻。
- **Gemini 非 SSE 流**：`streamGenerateContent` 不带 `alt=sse` 时返回 JSON 数组，需要完整响应体才能解析，**不产生任何性能样本**（不显示 TTFT／TPS），但用量仍按完整有界缓冲提取。需要性能统计时应使用 SSE 入口。
- **TPS**：输出计数使用上游报告的输出 token，可能包含思考 token。分母计入首输出等待与生成时间（覆盖从请求进入到响应体正常结束的整个响应期），按总 token ÷ 总时间汇总。上游缓冲和网络传输会影响观测值，无法据此还原模型内部解码速度。应用内性能页另展示「不含 TTFT」的平均 TPS（分母只算首分片到响应结束的生成时间），仅作对照；攒批一次性下发的上游会低估生成时长、让该值偏高。
- **有效样本**：平均 TTFT 使用成功完成（2xx）、对应 TTFT 有效且有限的流式尝试，不要求上报 token 数。TPS 使用同一组样本，额外要求两种 TTFT 有效、完整生成时间有限且大于零、输出 tokens ≥ 2、有效输出事件 ≥ 2。失败、取消或无法可靠解析的样本不计入对应指标。
- **requestTTFT 与 attemptTTFT**：整体汇总与按 `route` 分组时展示 **requestTTFT**，从路由器收到完整请求并进入候选尝试阶段开始计时，包含自动回退等待；按 `provider`／`model` 分组时展示 **attemptTTFT**，仅包含该次上游尝试自身的首输出等待。两者都在原始上游流上测量，后续输出翻译、事件重排及客户端渲染延迟不属于该口径。
- **样本数**：TTFT samples 与展示口径一致——`route` 分组为 request 级样本数（JSON `requestTTFTSamples`），`provider`／`model` 分组为上游 attempt 样本数（`ttftSamples`）。两者可能不同；request 级样本缺失时按 0 显示并给出 warning，绝不用上游样本数冒充路由样本。TPS samples 独立统计。
- **聚合指标**：平均 TTFT = 有效 TTFT 之和 ÷ 样本数；平均 TPS（含 TTFT）= `Σ输出 Token ÷ Σ(TTFT + 生成时间)`。应用内性能页另给出平均 TPS（不含 TTFT）= `Σ输出 Token ÷ Σ生成时间`，与含 TTFT 版本共用同一批样本、只换分母。时间以秒计，TPS 单位为 `tok/s`；TPS 不对每次请求的速率求算术平均。
- **无样本**：没有对应样本时显示 `—`，JSON 中对应字段为 `null`，绝不显示为 0。
- **历史**：早于本功能开始记录的历史尝试没有性能数据，与「无样本」一致；统计不持久化任何提示词或回答正文，只保留时延与 token 计数。

命令行文本会先打印完整用量报告，再追加一段性能报告，例如：

```text
Performance (model)
Overall basis: request scope (includes fallback)

Summary
  Attempts: 12
  Successful streaming: 9/12 attempts
  TTFT samples: 9  TPS samples: 8
  Average TTFT: 480 ms
  Average TPS (incl TTFT): 38.1 tok/s

Groups — basis: upstream attempt
  deepseek-v4.1-flash (command-wsz)
    Attempts 12  Successful streaming 9/12 attempts
    TTFT samples 9  TPS samples 8
    Average TTFT 480 ms  Average TPS (incl TTFT) 38.1 tok/s
```

按 `route` 分组时，明细标注 `Groups — basis: request (includes fallback)`，使用 requestTTFT；整体汇总始终使用请求口径。

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
