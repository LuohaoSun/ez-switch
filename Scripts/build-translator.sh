#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
GO_BIN=${GO_BIN:-$(command -v go || true)}
if [[ -z "$GO_BIN" && -x "$PWD/.build/bridge-toolchain/go/bin/go" ]]; then
    GO_BIN="$PWD/.build/bridge-toolchain/go/bin/go"
fi
if [[ -z "$GO_BIN" ]]; then
    echo "Responses bridge requires Go 1.26 or newer; set GO_BIN to its executable." >&2
    exit 1
fi
mkdir -p .build
"$GO_BIN" -C Tools/ResponsesBridge build -trimpath -o ../../.build/ezs-responses-bridge .
python3 Tools/ResponsesBridge/collect-licenses.py "$GO_BIN" .build/bridge-licenses
