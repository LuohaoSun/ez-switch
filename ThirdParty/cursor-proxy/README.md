# cursor-proxy — CLIProxyAPI Plus (fixed release)

The built-in **Cursor 订阅连接器** (Cursor subscription connector) runs on top of a
pinned, unmodified **CLIProxyAPI Plus** binary. This directory holds the provenance
for that binary: the version pin, per-architecture download URLs and SHA-256
checksums, the upstream license (verbatim), and the packaging contract.

- Upstream project: <https://github.com/jc01rho/CLIProxyAPIPlus>
  (fork of <https://github.com/router-for-me/CLIProxyAPI>, MIT)
- Pinned release: **v8.0.28-2**
- Pinned commit: `67eadafb4ea36e5cf60d33fa349982da9b6dc31b`
- License: **MIT** (see `LICENSE`, verbatim from the release archive;
  sha256 `879792e89cf1bdd6a8d446033ec87e30496f97dcafc4656dc53f641509b346a6`)
- Release `checksums.txt` (sha256
  `2370498ae72eef9499dabb15e2ad21987043ac31e7f14bb49c57fbe2721cafde`) is the
  authoritative checksum list; `manifest.json` records the two macOS entries.

## Pinned artifacts

The release is fixed to a single tag; the build never falls back to another
version or project. `manifest.json` is the source of truth.

| arch | asset | asset sha256 | binary in archive |
| --- | --- | --- | --- |
| arm64 (Apple Silicon) | `CLIProxyAPI_8.0.28-2_darwin_aarch64.tar.gz` | `04db8608c1b4b2e3896c590e0c5d35ef92a8f8b44291edc36a7f32e53c768d9d` | `cli-proxy-api` (Mach-O arm64) |
| amd64 (Intel) | `CLIProxyAPI_8.0.28-2_darwin_amd64.tar.gz` | `5e72dfbcab64c04eead45c43f3da71d43c5acc8d5d376932108f90a6022ea978` | `cli-proxy-api` (Mach-O x86_64) |

The archive also contains `LICENSE`, `README.md`, `README_CN.md`,
`config.example.yaml` and `static/management.html`. Only the `cli-proxy-api`
executable is packaged into the app; the rest is not shipped.

## Packaging contract

- `Scripts/build-cursor-proxy.sh` downloads the pinned asset for the target
  architecture into `.build/cursor-proxy/`, verifies its SHA-256 against
  `manifest.json`, then safely extracts only the expected `cli-proxy-api` member
  (member whitelist, no absolute paths or `..` traversal) to
  `.build/ezs-cursor-proxy`.
- `Scripts/build-app.sh` copies that file to
  `EZSwitch.app/Contents/MacOS/ezs-cursor-proxy` and the notices in this
  directory to
  `EZSwitch.app/Contents/Resources/ThirdPartyLicenses/cursor-proxy/`.
- The helper is ad-hoc signed with the rest of the bundle; the released binary
  is never redistributed with its own certificate. Re-signing rewrites the
  Mach-O signature bytes, so the packaged executable is not byte-identical to
  the upstream release artifact.
- Set `EZSWITCH_DISABLE_CURSOR=1` to build the app without the Cursor connector:
  the proxy is neither downloaded nor packaged, and the host sources under
  `Sources/EZSwitch/Extensions/Cursor` are excluded from the target.

## Runtime properties (verified for this pin)

- **Upstream source is not modified.** The pinned archive and its executable
  are verified byte-for-byte by SHA-256 at download, and there are no source
  changes or rebuilds; the ad-hoc re-signing afterwards still rewrites the
  Mach-O signature bytes, so the shipped binary is not byte-identical to the
  release artifact.
- **Minimum macOS: 15.0** (`LC_BUILD_VERSION` `minos 15.0`, `sdk 15.5`, both
  architectures). This is higher than the EZ Switch host's own macOS 13 minimum,
  so the Cursor connector is only runnable on macOS 15+.
- **Dynamic dependencies:** system frameworks only
  (`/usr/lib/libresolv.9.dylib`, `CoreFoundation`, `Security`,
  `/usr/lib/libSystem.B.dylib`). No third-party dylibs are bundled or required.
  The darwin archives are CGO builds (they can dlopen optional dynamic-library
  plugins), but nothing outside the OS is linked at load time.
- The binary self-reports `Version: 8.0.28-2, Commit: 67eadafb4` on `--help`.
- The management control panel (`static/management.html`) is **not** embedded and
  is not packaged. At runtime the binary stores/refreshes it next to its config
  file (`<config dir>/static/management.html`, or `MANAGEMENT_STATIC_PATH` /
  `WRITABLE_PATH`), downloading the latest asset from GitHub when missing; it
  self-heals without the shipped copy.

## Reproducing the checksums

```bash
curl -fsSL -o checksums.txt \
  https://github.com/jc01rho/CLIProxyAPIPlus/releases/download/v8.0.28-2/checksums.txt
shasum -a 256 checksums.txt            # 2370498a…21cafde
shasum -a 256 CLIProxyAPI_8.0.28-2_darwin_aarch64.tar.gz   # 04db8608…c768d9d
shasum -a 256 CLIProxyAPI_8.0.28-2_darwin_amd64.tar.gz     # 5e72dfbc…022ea978
```
