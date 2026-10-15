# Third-party notices and attribution conventions

This directory holds the attribution source files copied into the application
bundle under `Contents/Resources/`, and is also the project's own conventions
document. Upstream license and notice texts are preserved verbatim: each such
file keeps its original name and bytes.

Bundle layout in `EZSwitch.app/Contents/Resources/`:

- `LICENSE.txt` — EZ Switch's own MIT license. **This is the project's own
  license, not a third-party notice.**
- `ThirdPartyLicenses/README.md` — this file.
- `ThirdPartyLicenses/modules.json` and one directory per Go module — notices
  for the Responses bridge's linked modules, collected from the build by
  `Tools/ResponsesBridge/collect-licenses.py`.
- `ThirdPartyLicenses/swift/` — the pinned Swift packages' license and notice
  files, collected verbatim by `Tools/collect-swift-licenses.py`, plus
  `ThirdPartyLicenses/swift/index.json`. Current pins: swift-nio 2.103.0,
  swift-atomics 1.3.1, swift-collections 1.6.0 and swift-system 1.8.1, all
  Apache-2.0; SwiftNIO also ships a `NOTICE.txt`.
- `EZSwitch_EZSwitch.bundle/` — the SwiftPM resource bundle for the `EZSwitch`
  target (`.copy("Resources/ProviderIcons")`). It carries the provider preset
  brand icons at `ProviderIcons/<key>.png` and their MIT notice at
  `ProviderIcons/LICENSE.txt`; see `ThirdParty/provider-icons/`.
- `ThirdPartyLicenses/provider-icons/` — `LICENSE` (verbatim
  `provider-icons/lobe-icons/LICENSE`, lobehub/lobe-icons, MIT) and `README.md`
  for those icons.
- `ThirdPartyLicenses/cursor-proxy/` — the Cursor connector helper's provenance:
  `manifest.json` (pin, per-arch URLs and SHA-256), `LICENSE` (verbatim upstream
  MIT) and `README.md`; see `ThirdParty/cursor-proxy/`.
- `Contents/MacOS/ezs-cursor-proxy` — the pinned, unmodified CLIProxyAPI Plus
  binary (v8.0.28-2) that the built-in Cursor connector runs; see below.

Attribution conventions:

- Each component's own license/notice file is shipped verbatim under its own
  directory; no license text is merged, summarized or edited.
- A Swift package must provide a LICENSE/LICENCE/COPYING file; NOTICE files are
  retained in addition but never substitute for it.
- Index metadata lists what is bundled: the Go `modules.json` records each
  module path and version, while the Swift `swift/index.json` additionally
  records each package's upstream URL and the bundle path where its notices
  live.
- Packaging fails when a pinned component's checkout or license file is
  missing, so the app cannot ship without notices.
- `Tools/collect-swift-licenses.py` reads `Package.resolved` and copies from
  `.build/checkouts/<identity>`; `Tools/ResponsesBridge/collect-licenses.py`
  reads `go list -deps` for the bridge.

## CLIProxyAPI protocol translation

EZ Switch's experimental Responses → Chat bridge depends on
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), MIT licensed. The
wrapper uses **unmodified CLIProxyAPI v8.0.3**.

Pinned release: **v8.0.3** (commit inspected: **acdace936fa7df2905500c7f5e0a97d683138dea**)
Dependency checksums: `Tools/ResponsesBridge/go.sum`.

The bridge calls the upstream `sdk/translator` and `sdk/translator/builtin`;
it does not copy or reimplement the converter. It owns no HTTP listener, API
credentials, session database or OAuth login. The Swift host owns upstream
connections and request cancellation. One helper process handles one request.

The bridge supports full-history Responses requests, streaming and JSON
responses, function tools and custom tools through the upstream translator.
Server-side `previous_response_id`/`conversation` and remote compaction are
explicitly unsupported. Their requests fail before contacting the upstream.
Use Codex's full-history/local compaction path. This is not a promise of full
OpenAI Responses API equivalence. Future dependency upgrades must rerun the
bridge tests and real Codex tool-loop checks.

Current packaging includes the CLIProxyAPI and Go dependency notices collected
by `Tools/ResponsesBridge/collect-licenses.py`, and the pinned Swift packages'
licenses and notices collected by `Tools/collect-swift-licenses.py` from 0.3.2.
The 0.3.1 DMG contains the Go notices but predates the Swift license packaging fix.

## Cursor connector helper (CLIProxyAPI Plus)

The built-in Cursor 订阅连接器 runs on a pinned, unmodified
[jc01rho/CLIProxyAPIPlus](https://github.com/jc01rho/CLIProxyAPIPlus) release
(fork of `router-for-me/CLIProxyAPI`, MIT). It is packaged as
`Contents/MacOS/ezs-cursor-proxy` (archive name `cli-proxy-api`).

Pinned release: **v8.0.28-2** (commit **67eadafb4ea36e5cf60d33fa349982da9b6dc31b**).
Per-architecture asset URLs, archive/binary SHA-256 digests and the license are
recorded in `ThirdParty/cursor-proxy/manifest.json`; the exact upstream `LICENSE`
is shipped verbatim alongside it.

- `Scripts/build-cursor-proxy.sh` downloads the pinned darwin asset into
  `.build/cursor-proxy/`, verifies its SHA-256, and safely extracts only the
  `cli-proxy-api` member to `.build/ezs-cursor-proxy`. It never falls back to a
  different project or version, and never `curl | sh`.
- `Scripts/build-app.sh` copies it into the bundle and ad-hoc signs it. Set
  `EZSWITCH_DISABLE_CURSOR=1` to skip both the download and the packaging.
- The binary is redistributed byte-for-byte; upstream source is not modified.
- Minimum macOS is **15.0** (both architectures); the helper's only dynamic
  dependencies are OS frameworks/libraries, so no third-party dylibs are bundled.
  See `ThirdParty/cursor-proxy/README.md` for details.

## Provider preset brand icons

The "add provider" preset picker renders a brand icon for each
`ProviderPreset.iconName`. These come from
[lobehub/lobe-icons](https://github.com/lobehub/lobe-icons), MIT licensed,
pinned at commit `05a9b8c41e4735a4a2b6d2f1e43574bd8ec6c8cb`. Upstream SVGs are
stored verbatim under `provider-icons/lobe-icons/` and rendered offline to PNG by
`provider-icons/render.sh` (AppKit's SVG support is unreliable, so the app ships
PNG). `provider-icons/README.md` lists the key→source mapping and the
monochrome/color policy. The bundle ships the PNGs in
`EZSwitch_EZSwitch.bundle/ProviderIcons/` and the license and source notes under
`ThirdPartyLicenses/provider-icons/`.
