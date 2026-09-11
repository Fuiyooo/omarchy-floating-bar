# omarchy-floating-bar

Floating status bar for Omarchy with **capsule groups** — a restyled fork of
the built-in `omarchy.bar` shell plugin (Quickshell), shipped as a proper
third-party Omarchy plugin.

![preview](preview.png)

## Features

- **Floating bar** — inset from the screen edges with a fully rounded backdrop
- **Capsule groups** — bar entries that share the same `group` value render
  inside one fully-rounded capsule; ungrouped entries stay flat beside them
- Lives entirely in `~/.config/omarchy/plugins/` — survives `omarchy update`
- Drag-to-reorder, popups, tooltips, double-click transparency: all inherited
  from the upstream Omarchy bar engine

## Install

```bash
omarchy plugin remove dime.floating-bar --yes 2>/dev/null || true
omarchy plugin remove dime.bar --yes 2>/dev/null || true
omarchy plugin add https://github.com/dime/omarchy-floating-bar --enable --yes
```

(Replace the repo URL with your own if you fork it. A local checkout also
works: `omarchy plugin add file://$HOME/Work/omarchy-floating-bar --enable --yes`.)

## Group your widgets

Edit `~/.config/omarchy/shell.json` — consecutive entries that share the same
`group` string become one capsule:

```json
"right": [
  { "id": "omarchy.tray" },
  { "id": "omarchy.bluetooth", "group": "connectivity" },
  { "id": "omarchy.network",   "group": "connectivity" },
  { "id": "omarchy.audio",     "group": "connectivity" },
  { "id": "omarchy.power" }
]
```

- `tray` → standalone, no capsule
- `bluetooth + network + audio` → one capsule
- `power` → standalone

Layout is otherwise managed the usual Omarchy ways (`omarchy bar move ...`,
drag to reorder on the bar, `omarchy plugin enable/disable`).

## Custom sizing

Tweak these properties at the top of `Bar.qml`:

| Property | Default | Meaning |
|---|---|---|
| `floatingMargin` | `Style.space(9)` | Distance from screen edges |
| `pillGap` | `Style.space(4)` | Space between capsules |
| `pillPadding` | `Style.space(9)` | Inner capsule padding |

## Uninstall

```bash
omarchy plugin remove dime.floating-bar --yes
```

The built-in `omarchy.bar` takes over again automatically.

## Updating

This plugin is a snapshot of Omarchy's bar engine. If a future Omarchy update
changes `Bar.qml` upstream, re-clone onto your fork or re-apply your diffs.

## Credits

Bar engine by [Omarchy](https://omarchy.org) (MIT). Capsule/floating styling
inspired by [serpantinum](https://github.com/ilyamiro/serpantinum).
