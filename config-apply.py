#!/usr/bin/env python3
# Applies a full replacement of the `bar:` subtree in the user shell.json.
# The host shell watches this file and hot-reloads, so callers only need to
# write and let the bar recalculate.
import json, os, pathlib, sys

def fail(msg):
    print(json.dumps({"ok": False, "error": str(msg)}))
    sys.exit(1)

try:
    payload = json.loads(sys.argv[1])
    bar = payload.get("bar")
    if not isinstance(bar, dict):
        fail("bar object required")
except Exception as e:
    fail("invalid payload: " + str(e))

target = pathlib.Path.home() / ".config/omarchy/shell.json"
try:
    data = json.loads(target.read_text())
except Exception as e:
    fail("cannot read shell.json: " + str(e))

data["bar"] = bar

tmp = target.with_name(".omarchy-shell.json.tmp")
try:
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    os.replace(tmp, target)
except Exception as e:
    fail("cannot write shell.json: " + str(e))

print(json.dumps({"ok": True}))
