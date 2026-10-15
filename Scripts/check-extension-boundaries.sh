#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$PROJECT_ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
forbidden = re.compile(r"Cursor|cursorCLI|cursorConnector|cursorRunner|cursorConnection")
violations = []
for directory in (root / "Sources/EZSwitch", root / "Tests/EZSwitchTests"):
    for path in sorted(directory.rglob("*.swift")):
        relative = path.relative_to(directory)
        if relative.parts[:2] == ("Extensions", "Cursor"):
            continue
        if directory.name == "EZSwitch" and relative == Path("BuiltinExtensions.swift"):
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if forbidden.search(line):
                violations.append(f"{path.relative_to(root)}:{number}: {line.strip()}")
if violations:
    print("Connector implementation leaked into the host:", file=sys.stderr)
    print("\n".join(violations), file=sys.stderr)
    sys.exit(1)
print("Extension boundaries passed: Cursor is referenced only by its directory and composition point.")
PY
