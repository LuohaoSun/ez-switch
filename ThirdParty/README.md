# CLIProxyAPI protocol translation

EZ Switch's experimental Responses → Chat bridge depends on
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), MIT licensed.

Pinned release: **v8.0.3** (commit inspected: **acdace936fa7df2905500c7f5e0a97d683138dea**)
Dependency checksums: `Tools/ResponsesBridge/go.sum`.

The bridge calls the upstream `sdk/translator` and `sdk/translator/builtin`;
it does not copy or reimplement the converter. It owns no HTTP listener, API
credentials, session database or OAuth login. The Swift host owns upstream
connections and request cancellation. One helper process handles one request.

This preview supports full-history Responses requests, streaming and JSON
responses, function tools and custom tools through the upstream translator.
Server-side `previous_response_id`/`conversation` and remote compaction are
explicitly unsupported. Their requests fail before contacting the upstream.
Use Codex's full-history/local compaction path. This is not a promise of full
OpenAI Responses API equivalence. Future dependency upgrades must rerun the
bridge tests and real Codex tool-loop checks.

The distribution includes CLIProxyAPI and dependency license notices collected
by `Tools/ResponsesBridge/collect-licenses.py` during the build.
