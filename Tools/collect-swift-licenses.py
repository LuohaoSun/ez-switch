"""Collect verbatim license files for the pinned Swift packages.

Reads Package.resolved, maps each pin identity to its local checkout under
.build/checkouts/<identity>, and copies the checkout's top-level LICENSE,
LICENCE, COPYING and NOTICE files unchanged. Every package must provide at
least one LICENSE/LICENCE/COPYING file; NOTICE files are retained but never
count as the license. The destination is rebuilt from scratch so removed
packages cannot leave stale files behind. Exits non-zero (leaving any previous
output untouched) when Package.resolved is malformed, a checkout is missing, or
a package lacks a license.

    collect-swift-licenses.py <destination> [root] [checkouts]

`root` defaults to the repository root and `checkouts` to
`<root>/.build/checkouts`; both are only overridden by tests/staging.
"""
import json
import pathlib
import shutil
import sys

LICENSE_PREFIXES = ("LICENSE", "LICENCE", "COPYING")
NOTICE_PREFIXES = ("NOTICE",)
# Mirrors the directory build-app.sh copies the collected tree into.
BUNDLE_SUBDIR = "ThirdPartyLicenses/swift"


def _is_within(child, parent):
    child = pathlib.Path(child).resolve()
    parent = pathlib.Path(parent).resolve()
    return child == parent or parent in child.parents


def _load_pins(resolved_path):
    try:
        document = json.loads(resolved_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SystemExit(f"Invalid Package.resolved: {error}")
    pins = document.get("pins") if isinstance(document, dict) else None
    if not isinstance(pins, list):
        raise SystemExit(f"Package.resolved has no 'pins' list: {resolved_path}")
    return pins


def _plan_package(pin, checkouts):
    if not isinstance(pin, dict) or not isinstance(pin.get("identity"), str):
        raise SystemExit(f"Invalid pin in Package.resolved: {pin!r}")
    identity = pin["identity"]
    state = pin["state"] if isinstance(pin.get("state"), dict) else {}
    checkout = checkouts / identity
    if not checkout.is_dir():
        raise SystemExit(f"Missing checkout for pinned package: {identity} ({checkout})")

    sources = [
        path for path in sorted(checkout.iterdir())
        if path.is_file() and path.name.upper().startswith(LICENSE_PREFIXES + NOTICE_PREFIXES)
    ]
    if not any(path.name.upper().startswith(LICENSE_PREFIXES) for path in sources):
        raise SystemExit(f"Missing license for pinned package: {identity} ({checkout})")
    return identity, state, pin.get("location"), sources


def collect(destination, root, checkouts):
    if _is_within(destination, checkouts) or _is_within(checkouts, destination):
        raise SystemExit(f"Destination overlaps checkouts: {destination} <-> {checkouts}")

    resolved_path = root / "Package.resolved"
    if not resolved_path.is_file():
        raise SystemExit(f"Missing Package.resolved: {resolved_path}")

    # Validate every pin and license file before touching the output tree.
    plan = []
    for pin in _load_pins(resolved_path):
        plan.append(_plan_package(pin, checkouts))
    plan.sort(key=lambda entry: entry[0])

    staging = destination.with_name(destination.name + ".tmp")
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    try:
        index = []
        for identity, state, location, sources in plan:
            target = staging / identity
            target.mkdir()
            for source in sources:
                shutil.copyfile(source, target / source.name)
            index.append({
                "identity": identity,
                "version": state.get("version") or state.get("revision"),
                "revision": state.get("revision"),
                "upstream": location,
                "bundledPath": f"{BUNDLE_SUBDIR}/{identity}",
                "licenseFiles": [source.name for source in sources],
            })
        (staging / "index.json").write_text(
            json.dumps(index, indent=2) + "\n", encoding="utf-8")
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise

    shutil.rmtree(destination, ignore_errors=True)
    staging.rename(destination)
    return index


def main(argv):
    if not 2 <= len(argv) <= 4:
        raise SystemExit(__doc__.strip().splitlines()[-1])
    destination = pathlib.Path(argv[1]).resolve()
    root = pathlib.Path(argv[2]).resolve() if len(argv) > 2 \
        else pathlib.Path(__file__).resolve().parents[1]
    checkouts = pathlib.Path(argv[3]).resolve() if len(argv) > 3 else root / ".build/checkouts"
    collect(destination, root, checkouts)


if __name__ == "__main__":
    main(sys.argv)
