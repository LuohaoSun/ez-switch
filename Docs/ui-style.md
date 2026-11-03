# 界面样式规范

范围：`Sources/EZSwitch` 下所有 SwiftUI 页面与卡片。静态自检：

```bash
python3 Scripts/check-ui-style.py
```

## 1. 设计令牌

所有颜色、间距、圆角来自 `Sources/EZSwitch/DesignSystem.swift` 的 `AppDesign`，页面不新增十六进制颜色，也不写第二套圆角字面量。

- 语义色按三档中性面建立层次：`canvas`（页面）→ `surface`（卡片）→ `inset`（卡片内嵌块）；另有 `hover`、`border` 与卡片专用的 `cardBorder`。`canvas` 直接取系统原生的 `controlBackgroundColor`，浅色下与白色标题栏连续，深色下自动适配。
- `brand` 只用于主操作、选中态和每页唯一的主指标，不用于运行状态或装饰。
- 状态色使用 `success` / `warning` / `danger`，不要直接写 `.orange`、`.red`。
- 间距 `Space.page` / `card` / `section`，圆角 `Radius.card` / `inset` / `row`。`UsageCardMetrics` 也只转发这些令牌。
- 深色变体缺失的颜色不允许进代码库；除 `canvas` 直接使用原生 `controlBackgroundColor` 外，新增颜色必须在 `adaptiveColor` 里成对声明浅/深值。

## 2. 布局主次

- 页面外边距 24pt，卡片内边距 16pt（密集流向图可用 12pt），区块间距 16pt。
- 每页顶部用 `AppPageHeader`（标题 + 一句说明）；主操作由页面自己用 `HStack` 与标题并排，不塞进标题组件。
- 一页只保留一个主指标：`StatTile(primary: true)` 放大并交给品牌蓝，其余指标保持中性。同组指标使用相同内边距、行间距与数字区高度；主指标字号变化不应使卡片外形变大，三行文字按共同基线对齐。
- 卡片内不再套卡片：内嵌块用单层 `AppDesign.inset` 底色，不加第二道描边。原生表格已经带分隔线时，外层不再补线。
- 长文本用 `lineLimit` + `minimumScaleFactor` + `allowsTightening`，避免列宽和行高跳动；表格列宽由 `TableRowLayout` 的权重与最小宽度统一分配。
- 空/加载/错误状态用 `AppPageState`（整页）或 `EmptyState`（列表内就地操作），不各自拼图标和留白。

## 3. 卡片表面唯一实现

`CardSurfaceModifier`（`DesignSystem.swift`）是唯一的卡片表面实现：连续圆角、`surface` 底色、0.5pt `cardBorder` 淡描边、极轻投影。两个入口都只是薄封装：

- `cardSurface(padding:)`：不裁剪内容。含原生 `NSTableView` 的卡片走这里，避免裁剪收窄表格绘制余量。
- `ezsCardSurface(cornerRadius:padding:)`：保留裁剪。供应商卡、路由卡、扩展卡依赖它把内容收进圆角。

规则：

- 不允许新增第二个卡片表面 modifier，也不允许页面内联“底色 + 描边 + 阴影”的组合。
- 旧模板（4% 黑阴影、以 `controlBackgroundColor` 充当卡片填充、9% 主色描边）已废弃，不得恢复。该禁用只针对卡片填充：页面画布本身使用原生 `controlBackgroundColor` 属于设计令牌，不受此条限制。
- 自检脚本会验证两个入口都委托 `CardSurfaceModifier`，且全仓库只有一个实现。

## 4. 原生控件优先

- 列表、表单、开关、选择器使用系统控件：`List(selection:)`、`Form` + `.formStyle(.grouped)`、`Toggle`（`.switch` 或原生复选框）、`Picker`、`TextField`、标准 `Button` 样式。
- 行几何与拖放交给原生控件：候选列表用 `NSTableView`，侧栏用 `NSSplitViewController`，不以 SwiftUI 手势自绘等价行为。
- 窗口 chrome（标题栏、工具栏、侧栏材质）由标准 `toolbar` / `navigationTitle` 和 SDK 27 链接提供。需要玻璃按钮时用 `glassButtonIfAvailable()`（macOS 26+，低版本原样返回）。
- 严禁在 `List` 或任何内容列表上调用 `.backgroundExtensionEffect(`：该 API 的语义是把视图镜像到四周再模糊裁剪，用在内容上会导致行渲染错乱（已实测）。静态自检会拦截真实调用，注释不受影响。
- 不自绘复选框、滚动条、分隔线、警告弹窗。

## 5. 浅色 / 深色

- 所有颜色由 `adaptiveColor(light:dark:)` 解析，页面不读 `colorScheme`，不写 `#if` 深色分支。
- 层次只靠三档中性面与描边；卡片用 0.5pt `cardBorder` 淡描边，内嵌块与胶囊仍用 1pt `border`。不使用渐变、发光、彩色图标基座。
- 浅色下画布与标题栏同为原生白，内容区保持连续；卡片与画布同色，只靠 0.5pt 淡描边和极轻投影立起。深色下画布随系统变暗，卡片必须比画布亮一档（`surface` 0x262629 对原生深色画布），保证边界清楚。
- 图标底色用语义色 10% 透明度，不直接用品牌色冒充运行状态。

## 6. Reduce Motion

- 所有 `animation` / `withAnimation` 必须由 `@Environment(\.accessibilityReduceMotion)` 关闭：`reduceMotion ? nil : .easeInOut(duration: 0.2)`。
- 展开/折叠走 `CollapsibleBody`，导航切换在 Reduce Motion 下用 `AnyTransition.identity`。
- 悬停反馈允许 0.12s 底色过渡，但不得改变行高、列宽或内容位置。

## 7. 隔离预览

- GUI 验收一律使用独立 app bundle、独立 `EZSWITCH_CONFIG` 与数据库、非 8788 端口（例如 19007），不覆盖也不重启 `/Applications/EZSwitch.app`。
- 验收结束后清理隔离进程、bundle 与 LaunchServices 注册。
- 静态自检与 GUI 验收分开记录：自检通过只说明规则成立，外观、几何、动画必须等真实 GUI 观察后才能写“已验收”；未观察到的项明确写“待验收”。
