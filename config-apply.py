#!/usr/bin/env python3
# Native config writer for dime.floating-bar (the Keysmith pattern).
#
# Usage:
#   config-apply.py read              -> {"ok":true,"config":<full shell.json>}
#   config-apply.py <json-payload>    -> payload {"bar": {...}} replaces the
#                                        whole `bar:` subtree of shell.json.
#
# Guard: a replacement that drops `bar.id` or `bar.layout` is refused, so a
# stale panel snapshot can never knock the shell back to the default bar.
import json, os, pathlib, sys

def fail(msg):
    print(json.dumps({"ok": False, "error": str(msg)}))
    sys.exit(1)

target = pathlib.Path.home() / ".config/omarchy/shell.json"

try:
    data = json.loads(target.read_text())
except Exception as e:
    fail("cannot read shell.json: " + str(e))

if len(sys.argv) == 2 and sys.argv[1] == "read":
    print(json.dumps({"ok": True, "config": data}))
    sys.exit(0)

try:
    payload = json.loads(sys.argv[1])
    bar = payload.get("bar")
    if not isinstance(bar, dict):
        fail("bar object required")
except Exception as e:
    fail("invalid payload: " + str(e))

old_bar = data.get("bar") if isinstance(data.get("bar"), dict) else {}

if "layout" not in bar or not isinstance(bar["layout"], dict):
    fail("bar.layout missing — refusing to replace config")

if not bar.get("id") and old_bar.get("id"):
    bar["id"] = old_bar["id"]

data["bar"] = bar

tmp = target.with_name(".omarchy-shell.json.tmp")
try:
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    os.replace(tmp, target)
except Exception as e:
    fail("cannot write shell.json: " + str(e))

print(json.dumps({"ok": True}))
