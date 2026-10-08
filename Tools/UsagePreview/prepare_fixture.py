#!/usr/bin/env python3
"""Write an isolated EZSwitch preview ``config.json`` for the usage harness.

The generated config:

* validates against the real ``Sources/EZSwitch/Config.swift`` schema,
* points every remote at the loopback mock (127.0.0.1) with dummy API keys,
* labels every provider as ``演示供应商 A`` / ``演示供应商 B`` so it is obvious
  this is a test fixture and cannot be mistaken for production traffic,
* never touches ``~/Library/Application Support``.

Default output directory: ``/tmp/ezswitch-usage-preview``. The SQLite database
(``usage.sqlite``) will be created in the same directory by the preview app, so
``EZSWITCH_CONFIG`` keeps the fixture and its database fully isolated.

Typical use:

    python3 prepare_fixture.py                 # writes config.json, prints run cmds
    python3 prepare_fixture.py --force         # overwrite an existing fixture
    python3 prepare_fixture.py --include-cache # add the optional cache-usage route

This script does not start the app, the mock or any service. It only checks that
the preview/mock ports are free (it never kills a process) and writes the files.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import mock_server  # noqa: E402  (local sibling module)

DEFAULT_OUT_DIR = "/tmp/ezswitch-usage-preview"
DEFAULT_PREVIEW_PORT = 19007
DEFAULT_MOCK_PORT = mock_server.DEFAULT_PORT  # 19008

# A sane default app path produced by the parent's staging script.
DEFAULT_APP = "/Users/sunluohao/WorkingSpace/model-router/dist/UsagePreview.noindex/EZSwitch-UsagePreview.app"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--out-dir", default=DEFAULT_OUT_DIR,
                        help=f"fixture directory (default {DEFAULT_OUT_DIR})")
    parser.add_argument("--preview-port", type=int, default=DEFAULT_PREVIEW_PORT,
                        help=f"preview listen port (default {DEFAULT_PREVIEW_PORT})")
    parser.add_argument("--mock-port", type=int, default=DEFAULT_MOCK_PORT,
                        help=f"mock upstream port (default {DEFAULT_MOCK_PORT})")
    parser.add_argument("--include-cache", action="store_true",
                        help="also emit the opt-in Anthropic cache-usage route")
    parser.add_argument("--force", action="store_true",
                        help="overwrite an existing config.json")
    parser.add_argument("--app", default=DEFAULT_APP,
                        help="preview .app path printed in the run instructions")
    parser.add_argument("--json", action="store_true",
                        help="print the generated config to stdout instead of a summary")
    return parser


def _guard_out_dir(out_dir: Path) -> None:
    resolved = str(out_dir.resolve())
    protected = str(Path.home() / "Library" / "Application Support")
    if resolved.startswith(protected):
        raise SystemExit(
            "refusing to write a preview fixture inside Application Support; "
            "pass --out-dir pointing at a temporary directory"
        )


def main() -> int:
    args = build_parser().parse_args()
    out_dir = Path(args.out_dir).expanduser()
    _guard_out_dir(out_dir)

    config_path = out_dir / "config.json"
    db_path = out_dir / "usage.sqlite"

    # Verify the ports are free without killing anything.
    preview_busy = mock_server.port_in_use(mock_server.HOST, args.preview_port)
    mock_busy = mock_server.port_in_use(mock_server.HOST, args.mock_port)
    if mock_busy:
        print(f"error: mock port {args.mock_port} is already in use "
              f"(close the other process; this script will not kill it)", file=sys.stderr)
        return 1
    if preview_busy:
        print(f"warning: preview port {args.preview_port} is already in use "
              f"(not killing it)", file=sys.stderr)

    config = mock_server.build_config(
        preview_port=args.preview_port,
        mock_port=args.mock_port,
        include_cache=args.include_cache,
    )

    if config_path.exists() and not args.force:
        print(f"error: {config_path} already exists; pass --force to overwrite",
              file=sys.stderr)
        return 1

    out_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(out_dir, 0o700)
    tmp_path = config_path.with_suffix(".json.tmp")
    tmp_path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n",
                        encoding="utf-8")
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, config_path)

    if args.json:
        print(json.dumps(config, ensure_ascii=False, indent=2))
        return 0

    totals = mock_server.expected_totals(args.include_cache)
    routes = mock_server.scenarios(args.include_cache)

    print(f"wrote {config_path}")
    print(f"isolated DB will be {db_path}")
    print(f"remotes={len(config['remotes'])} routes={len(config['fakes'])} "
          f"(mock http://127.0.0.1:{args.mock_port})")
    print()
    print("Expected after a full run (for the usage page / screenshot):")
    print(f"  requests={totals['requests']} attempts={totals['attempts']} "
          f"known={totals['known_attempts']} unknown={totals['unknown_attempts']} "
          f"failed={totals['failed_attempts']}")
    print(f"  input_sum={totals['input_sum']} output_sum={totals['output_sum']} "
          f"total_sum={totals['total_sum']}")
    print(f"  routes: {', '.join(s['route'] for s in routes)}")
    print()
    print("Next steps (run by the parent, once the preview app is built):")
    print(f"  1. python3 {Path(__file__).name} --out-dir {out_dir}  "
          f"# already done")
    print(f"  2. EZSWITCH_CONFIG={config_path} EZSWITCH_PORT={args.preview_port} \\")
    print(f"       {args.app}/Contents/MacOS/EZSwitch")
    print(f"  3. python3 {Path(__file__).parent / 'verify_usage.py'} full \\")
    print(f"       --config {config_path} \\")
    print(f"       --preview-port {args.preview_port} --mock-port {args.mock_port}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
