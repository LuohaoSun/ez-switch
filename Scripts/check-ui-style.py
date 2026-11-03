#!/usr/bin/env python3
"""Lightweight static guard for the app's UI style rules.

Run: python3 Scripts/check-ui-style.py

This checker is deliberately narrow. It asserts the rules that are easy to
regress and that have one correct answer, without mirroring the SwiftUI
implementation:

1. One card surface implementation. `cardSurface` and `ezsCardSurface` are thin
   wrappers over `CardSurfaceModifier`; no second card-surface `ViewModifier`
   (for example the removed `EZSCardSurface`) reappears.
2. Production Swift contains no real `.backgroundExtensionEffect(` call. The
   comment in `SettingsView.swift` that explains why it is banned is not a call.
3. Primary pages do not inline the retired card template: the 4% black shadow,
   `controlBackgroundColor` fill and 9% primary-color stroke it used.

It intentionally does not police literal corner radii, spacing values or every
`shadow(` call: graph nodes, tiles and rows legitimately use their own shapes.
Style guidance lives in `Docs/ui-style.md`.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "Sources" / "EZSwitch"

# Pages that own card layout. Renaming one of these must fail loudly instead of
# silently shrinking the covered area.
PRIMARY_PAGES = (
    "SettingsView.swift",
    "RouteWorkspaceView.swift",
    "ProviderEditSheet.swift",
    "ExtensionsPane.swift",
    "GeneralPane.swift",
    "UsageView.swift",
    "PerformanceView.swift",
    "ActivityRequestList.swift",
    "ActivityRouteGraph.swift",
    "LogWindowView.swift",
    "ExtensionCard.swift",
    "ProviderPresetPicker.swift",
    "MenuUsageSummary.swift",
)

# Exact values from the retired inline card template. They are not generic
# prohibitions: any other shadow radius or radius literal is out of scope.
RETIRED_CARD_MARKERS = (
    ("retired card shadow", re.compile(r"Color\.black\.opacity\(0\.04\)")),
    ("retired card fill", re.compile(r"Color\(nsColor:\s*\.controlBackgroundColor\)")),
    ("retired card stroke", re.compile(r"Color\.primary\.opacity\(0\.09\)")),
)

# Shapes allowed to be a card-surface modifier: the single implementation plus
# its private clip helper. Anything else, such as `EZSCardSurface`, is a
# duplicate surface.
ALLOWED_SURFACE_MODIFIERS = {"CardSurfaceModifier", "CardSurfaceClip"}

BACKGROUND_EXTENSION_CALL = re.compile(r"\.\s*backgroundExtensionEffect\s*\(")
SURFACE_MODIFIER_DECL = re.compile(r"struct\s+(\w*CardSurface\w*)\s*:\s*ViewModifier")
SURFACE_WRAPPER = re.compile(r"func\s+(cardSurface|ezsCardSurface)\s*\(")

# A wrapper that reimplements shading or clipping instead of delegating would
# show up here. Values such as padding and trailingInset remain the wrapper's
# business.
FORBIDDEN_WRAPPER_BODY = ("shadow(", "strokeBorder(", "clipShape(", ".fill(")


def sanitize(source: str) -> str:
    """Blank out comments and string contents, preserving newlines and offsets.

    Comments must not count as calls or declarations. String contents must not
    break brace matching (interpolations may contain braces).
    """
    out: list[str] = []
    i = 0
    n = len(source)
    while i < n:
        if source.startswith("//", i):
            while i < n and source[i] != "\n":
                i += 1
        elif source.startswith("/*", i):
            depth = 1
            i += 2
            while i < n and depth > 0:
                if source.startswith("/*", i):
                    depth += 1
                    i += 2
                elif source.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    if source[i] == "\n":
                        out.append("\n")
                    i += 1
        elif source.startswith('"""', i):
            out.append("   ")
            i += 3
            while i < n and not source.startswith('"""', i):
                out.append("\n" if source[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append("   ")
                i += 3
        elif source[i] == '"':
            out.append('"')
            i += 1
            while i < n:
                char = source[i]
                if char == "\\" and i + 1 < n:
                    out.append("  ")
                    i += 2
                elif char == '"':
                    out.append('"')
                    i += 1
                    break
                else:
                    out.append("\n" if char == "\n" else " ")
                    i += 1
        else:
            out.append(source[i])
            i += 1
    return "".join(out)


def brace_block(text: str, start: int) -> str:
    """Return the brace-delimited body that follows `start`."""
    opening = text.find("{", start)
    if opening < 0:
        return ""
    depth = 0
    for index in range(opening, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[opening:index + 1]
    return text[opening:]


def line_of(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def check(root: Path) -> list[str]:
    violations: list[str] = []
    if not SOURCE_DIR.is_dir():
        return [f"missing source directory: {SOURCE_DIR}"]

    files = sorted(SOURCE_DIR.rglob("*.swift"))
    if not files:
        return [f"no Swift files under {SOURCE_DIR}"]

    sanitized: dict[Path, str] = {}
    for path in files:
        try:
            sanitized[path] = sanitize(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError) as error:
            violations.append(f"{path.relative_to(ROOT)}: unreadable ({error})")

    pages = {SOURCE_DIR / name for name in PRIMARY_PAGES}
    for page in sorted(pages):
        if not page.is_file():
            violations.append(f"{page.relative_to(ROOT)}: primary page is missing; update PRIMARY_PAGES")

    # 1. Card surface delegation.
    implementation_sites: list[Path] = []
    wrapper_sites: dict[str, list[Path]] = {"cardSurface": [], "ezsCardSurface": []}
    for path, text in sanitized.items():
        relative = path.relative_to(ROOT)
        for match in SURFACE_MODIFIER_DECL.finditer(text):
            name = match.group(1)
            if name == "CardSurfaceModifier":
                implementation_sites.append(path)
            if name not in ALLOWED_SURFACE_MODIFIERS:
                violations.append(
                    f"{relative}:{line_of(text, match.start())}: duplicate card surface modifier `{name}`")
        for match in SURFACE_WRAPPER.finditer(text):
            name = match.group(1)
            wrapper_sites[name].append(path)
            body = brace_block(text, match.start())
            if "CardSurfaceModifier(" not in body:
                violations.append(
                    f"{relative}:{line_of(text, match.start())}: `{name}` does not delegate to CardSurfaceModifier")
            for marker in FORBIDDEN_WRAPPER_BODY:
                if marker in body:
                    violations.append(
                        f"{relative}:{line_of(text, match.start())}: `{name}` reimplements the card surface (`{marker}`)")

    if len(implementation_sites) != 1:
        locations = ", ".join(str(p.relative_to(ROOT)) for p in implementation_sites) or "none"
        violations.append(f"expected exactly one CardSurfaceModifier, found {len(implementation_sites)} ({locations})")
    for name, sites in wrapper_sites.items():
        if len(sites) != 1:
            locations = ", ".join(str(p.relative_to(ROOT)) for p in sites) or "none"
            violations.append(f"expected exactly one `{name}`, found {len(sites)} ({locations})")

    # 2. No real backgroundExtensionEffect call in production code.
    for path, text in sanitized.items():
        for match in BACKGROUND_EXTENSION_CALL.finditer(text):
            violations.append(
                f"{path.relative_to(ROOT)}:{line_of(text, match.start())}: "
                "backgroundExtensionEffect() call found (banned on content views)")

    # 3. Primary pages must not restore the retired inline card template.
    for page in sorted(pages):
        text = sanitized.get(page)
        if text is None:
            continue
        for label, pattern in RETIRED_CARD_MARKERS:
            for match in pattern.finditer(text):
                violations.append(
                    f"{page.relative_to(ROOT)}:{line_of(text, match.start())}: "
                    f"{label} reintroduced; use cardSurface/ezsCardSurface")

    return violations


def main() -> int:
    violations = check(ROOT)
    if violations:
        print("UI style checks failed:", file=sys.stderr)
        for violation in violations:
            print(f"  {violation}", file=sys.stderr)
        print(f"\n{len(violations)} violation(s). See Docs/ui-style.md.", file=sys.stderr)
        return 1
    swift_count = len(list(SOURCE_DIR.rglob("*.swift")))
    print(f"UI style checks passed: {swift_count} Swift files, "
          f"{len(PRIMARY_PAGES)} primary pages, one card surface implementation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
