#!/bin/bash
# Download a checksum-pinned helper; reuse the verified archive for offline builds.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
if [[ "${EZSWITCH_DISABLE_CURSOR:-}" == "1" ]]; then
    printf '%s\n' 'Cursor extension excluded; skip helper packaging.'
    exit 0
fi
ARCH="${EZS_CURSOR_PROXY_ARCH:-$(uname -m)}"
case "$ARCH" in
    arm64|aarch64) ARCH=arm64 ;;
    x86_64|amd64) ARCH=amd64 ;;
    *) printf 'Unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;;
esac
python3 - "$ARCH" <<'PY'
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile
import urllib.request
import sys

manifest_path = Path('ThirdParty/cursor-proxy/manifest.json')
manifest = json.loads(manifest_path.read_text())
artifact = next(a for a in manifest['artifacts'] if a['os'] == 'darwin' and a['arch'] == sys.argv[1])
cache = Path('.build/cursor-proxy')
cache.mkdir(parents=True, exist_ok=True)
archive = cache / artifact['assetFilename']
output = Path('.build') / manifest['bundleBinaryName']


def sha(path):
    with path.open('rb') as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
        return digest.hexdigest()


if not archive.exists() or sha(archive) != artifact['sha256']:
    request = urllib.request.Request(artifact['assetUrl'], headers={'User-Agent': 'EZSwitch-build'})
    with tempfile.TemporaryDirectory(prefix='download-', dir=cache) as staging:
        downloaded = Path(staging) / 'archive.tar.gz'
        with urllib.request.urlopen(request, timeout=120) as response, downloaded.open('wb') as stream:
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > artifact['size']:
                    raise RuntimeError('Release archive exceeds pinned size')
                stream.write(chunk)
        if total != artifact['size'] or sha(downloaded) != artifact['sha256']:
            raise RuntimeError('Release archive checksum or size mismatch')
        os.replace(downloaded, archive)

with tempfile.TemporaryDirectory(prefix='extract-', dir=cache) as staging:
    binary = Path(staging) / manifest['bundleBinaryName']
    license_path = Path(staging) / 'LICENSE'
    with tarfile.open(archive, 'r:gz') as bundle:
        members = bundle.getmembers()
        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts:
                raise RuntimeError('Unsafe archive path')
        for name, destination in ((artifact['binary']['name'], binary), (manifest['license']['file'], license_path)):
            matches = [m for m in members if m.name == name and m.isfile()]
            if len(matches) != 1:
                raise RuntimeError(f'Missing or duplicate archive member: {name}')
            with bundle.extractfile(matches[0]) as source, destination.open('wb') as target:
                shutil.copyfileobj(source, target)
    if sha(binary) != artifact['binary']['sha256']:
        raise RuntimeError('Release executable checksum mismatch')
    if sha(license_path) != manifest['license']['sha256']:
        raise RuntimeError('Release license checksum mismatch')
    if sha(manifest_path.parent / 'LICENSE') != manifest['license']['sha256']:
        raise RuntimeError('Bundled license differs from pinned release')
    binary.chmod(0o755)
    os.replace(binary, output)
print(f"{output}: {manifest['repository']} {manifest['tag']} ({manifest['commit'][:9]}), {sys.argv[1]}")
PY
