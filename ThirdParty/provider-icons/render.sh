#!/bin/bash
# 把 ThirdParty/provider-icons/lobe-icons/ 下的原始品牌 SVG 渲染成
# Sources/EZSwitch/Resources/ProviderIcons/<key>.png，供 ProviderPresetIcon 加载。
#
# 为什么本地渲染而不是直接随包发 SVG：macOS 的 NSImage 对 SVG 支持不可靠，
# 所以这里用 rsvg-convert 离线渲染为透明背景 PNG（App 运行时不需要网络、不需要额外工具）。
#
# 重新生成（仅当升级图标来源时）：
#   brew install librsvg        # 提供 rsvg-convert
#   ./ThirdParty/provider-icons/render.sh
#
# 资源 key 与数据 catalog 的 ProviderPreset.iconName 一一对应；同一品牌的多条套餐
# 共用一张图标，因此这里按品牌 key 输出，而不是按 preset id。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$SCRIPT_DIR/lobe-icons"
OUT="$REPO_ROOT/Sources/EZSwitch/Resources/ProviderIcons"
SIZE=128

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "错误：未找到 rsvg-convert（brew install librsvg）" >&2
    exit 1
fi

mkdir -p "$OUT"

# 输出 key=原始 SVG 文件名。带 -color 的保留品牌色；其余为单色（currentColor 渲染为黑），
# 运行时由 ProviderPresetIcon 以 template 方式着色为 Color.primary。
declare -a MAP=(
    "zhipu=zhipu-color.svg"
    "zai=zai.svg"
    "opencode=opencode.svg"
    "commandcode=commandcode.svg"
    "openai=openai.svg"
    "anthropic=anthropic.svg"
    "google=google-color.svg"
    "deepseek=deepseek-color.svg"
    "kimi=kimi.svg"
    "minimax=minimax-color.svg"
    "alibaba=qwen-color.svg"
    "siliconflow=siliconcloud-color.svg"
    "openrouter=openrouter.svg"
)

for entry in "${MAP[@]}"; do
    key="${entry%%=*}"
    svg="${entry#*=}"
    if [[ ! -f "$SRC/$svg" ]]; then
        echo "错误：缺少源文件 $SRC/$svg" >&2
        exit 1
    fi
    rsvg-convert -w "$SIZE" -h "$SIZE" --keep-aspect-ratio -o "$OUT/$key.png" "$SRC/$svg"
    echo "渲染 $key.png  <-  $svg"
done

# MIT 许可随资源 bundle 一起分发（上游原文，逐字复制，不改写）。
cp "$SRC/LICENSE" "$OUT/LICENSE.txt"
echo "复制 LICENSE.txt  <-  lobe-icons/LICENSE"

echo "完成：$OUT"
