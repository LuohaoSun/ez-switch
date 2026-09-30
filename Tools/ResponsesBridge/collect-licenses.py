"""Bundle licenses for modules actually linked into the helper."""
import json
import pathlib
import shutil
import subprocess
import sys

go, destination = sys.argv[1:]
root = pathlib.Path(__file__).resolve().parents[2]
bridge = root / "Tools/ResponsesBridge"
text = subprocess.check_output([go, "list", "-deps", "-json", "."], cwd=bridge, text=True)
decoder = json.JSONDecoder()
modules = {}
while text.strip():
    value, end = decoder.raw_decode(text.lstrip())
    text = text.lstrip()[end:]
    module = value.get("Module", {})
    if module.get("Version") and module.get("Dir"):
        modules[module["Path"]] = module
out = root / destination
out.mkdir(parents=True, exist_ok=True)
for path, module in sorted(modules.items()):
    directory = pathlib.Path(module["Dir"])
    target = out / path.replace("/", "_")
    target.mkdir(exist_ok=True)
    found = False
    for source in directory.iterdir():
        if source.is_file() and source.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE")):
            output = target / source.name
            if output.exists():
                output.chmod(0o644)
            shutil.copyfile(source, output)
            output.chmod(0o644)
            found = True
    if not found:
        raise SystemExit(f"Missing license for dependency: {path} ({directory})")
(out / "modules.json").write_text(json.dumps(
    [{"path": p, "version": m["Version"]} for p, m in sorted(modules.items())], indent=2) + "\n")
