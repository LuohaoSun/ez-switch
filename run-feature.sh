#!/bin/bash
# Run the preview with an isolated config and port. Never writes the normal config.
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/dist/EZSwitch-ChatPreview.app"
PREVIEW_CONFIG=${EZSWITCH_PREVIEW_CONFIG:-"$HOME/Library/Application Support/EZSwitch-ChatPreview/config.json"}
PREVIEW_PORT=${EZSWITCH_PREVIEW_PORT:-18988}
if [[ ! -x "$APP/Contents/MacOS/EZSwitch" ]]; then
    echo "Build the preview first with ./build-feature.sh" >&2
    exit 1
fi
python3 - "$PREVIEW_CONFIG" "$PREVIEW_PORT" <<'PY'
import json, os, pathlib, sys
path = pathlib.Path(sys.argv[1])
if not path.exists():
    source = pathlib.Path.home() / 'Library/Application Support/EZSwitch/config.json'
    data = json.loads(source.read_text())
    data['port'] = int(sys.argv[2])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        json.dump(data, output, ensure_ascii=False, indent=2)
        output.write('\n')
print('Preview config:', path)
PY
exec env EZSWITCH_CONFIG="$PREVIEW_CONFIG" EZSWITCH_PORT="$PREVIEW_PORT" "$APP/Contents/MacOS/EZSwitch"
