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
