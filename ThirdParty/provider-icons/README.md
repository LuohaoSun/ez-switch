# Provider preset brand icons

Brand icons for the "add provider" preset picker (`ProviderPresetIcon`). Each
brand key maps 1:1 to `ProviderPreset.iconName`; several presets of the same
brand share one icon.

## Pipeline

1. Upstream SVGs are pinned verbatim under `lobe-icons/` (see below).
2. `render.sh` renders them offline with `rsvg-convert` into
   `Sources/EZSwitch/Resources/ProviderIcons/<key>.png` (128x128, transparent)
   and copies the upstream `LICENSE` to `.../ProviderIcons/LICENSE.txt`.
3. SwiftPM `.copy("Resources/ProviderIcons")` packs that directory (icons +
   `LICENSE.txt`) into `EZSwitch_EZSwitch.bundle`.
4. `Scripts/build-app.sh` copies the bundle into `EZSwitch.app/Contents/Resources/`
   and also copies the license and this README to
   `Contents/Resources/ThirdPartyLicenses/provider-icons/`, so the MIT notice
   ships inside the distributed app.

Rendering happens at authoring time, not app runtime: AppKit's `NSImage` support
for SVG is unreliable, so the app ships PNG and needs no network or extra tooling.

## Source and license

All icons come from **[lobehub/lobe-icons](https://github.com/lobehub/lobe-icons)**,
**MIT** licensed. Pinned commit:

**`05a9b8c41e4735a4a2b6d2f1e43574bd8ec6c8cb`** — the real upstream commit
`:bookmark: chore(release): v5.23.1 [skip ci]` (2026-10-13), verified via the
GitHub API and by fetching every file from the commit-pinned raw URL.

Upstream files live under `packages/static-svg/icons/`; the raw URL for each is:

```
https://raw.githubusercontent.com/lobehub/lobe-icons/<commit>/packages/static-svg/icons/<file>
```

The license is stored verbatim at `lobe-icons/LICENSE` and copied unchanged to
`ProviderIcons/LICENSE.txt` and into the app bundle (all three share the same
SHA-256 `add9d7531d1b21646317a8958e38fc727506fa39d24bdecb44154d943c82753a`).

| key (iconName) | upstream file (`lobe-icons/`) | render mode |
|----------------|-------------------------------|-------------|
| `zhipu` | `zhipu-color.svg` | brand color |
| `zai` | `zai.svg` | monochrome (template) |
| `opencode` | `opencode.svg` | monochrome (template) |
| `commandcode` | `commandcode.svg` | monochrome (template) |
| `openai` | `openai.svg` | monochrome (template) |
| `anthropic` | `anthropic.svg` | monochrome (template) |
| `google` | `google-color.svg` | brand color |
| `deepseek` | `deepseek-color.svg` | brand color |
| `kimi` | `kimi.svg` | monochrome (template) |
| `minimax` | `minimax-color.svg` | brand color |
| `alibaba` | `qwen-color.svg` | brand color |
| `siliconflow` | `siliconcloud-color.svg` | brand color |
| `openrouter` | `openrouter.svg` | monochrome (template) |

Notes:

- "Monochrome (template)" icons are single-color upstream (`fill="currentColor"`,
  rendered black). At runtime `ProviderPresetIcon` marks them as template and
  tints them with `Color.primary`, so they stay legible in light and dark
  appearance.
- "Brand color" icons keep their upstream colors, checked for adequate contrast
  on both light and dark backgrounds. `openrouter` intentionally renders from the
  monochrome source instead of `openrouter-color.svg`: its brand lime
  (`#C8FF00`) has almost no contrast on a light background.
- `alibaba` uses the Qwen mark (`qwen-color.svg`), the recognizable brand of
  Alibaba's Tongyi/Bailian model line.
- `google` uses the Google "G" (`google-color.svg`); the catalog's Gemini preset
  carries `iconName: "google"`.

## Regenerate

```
brew install librsvg
./ThirdParty/provider-icons/render.sh
```
