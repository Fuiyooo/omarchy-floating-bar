import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import "NightlightModel.js" as NightlightModel

// Self-contained night-light indicator for replacement bars.
//
// The first-party proxy reports `enabled` as a static false, so this copy
// reads the real state directly: `hyprctl hyprsunset temperature` (the same
// probe the omarchy nightlight service itself uses) and toggles through the
// omarchy-shell IPC channel (`nightlight toggle`).
BarIndicator {
  id: root

  property bool plugDebug: Quickshell.env("OMARCHY_PLUG_DEBUG") === "1"
  property int temperature: -1
  readonly property bool nightlight: root.temperature >= 0
    && NightlightModel.isNightlight(root.temperature)

  function dbg() {
    if (!plugDebug) return
    var parts = []
    for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i]))
    console.warn("PLUG nightlight " + parts.join(" "))
  }

  function probe() {
    if (probeProc.running) return
    // One call reads the real temperature and reports the engine's debug flag.
    // hyprctl's "couldn't connect" error leaks digits (the socket path), so
    // only an all-numeric value counts; anything else means "not running".
    probeProc.command = [ "bash", "-c",
      "t=\"\"; c=$(hyprctl hyprsunset temperature 2>/dev/null); "
      + "printf '%s' \"$c\" | grep -Eq '^[0-9]+$' && t=\"$c\"; "
      + "d=0; [ -f $HOME/.local/state/omarchy/plugins/dime.floating-bar/debug ] && d=1; "
      + "echo \"state:${t}|dbg:${d}\"" ]
    probeProc.running = true
  }

  function toggle() {
    var wantNight = !root.nightlight
    root.dbg("press want=" + (wantNight ? "night" : "daylight"))
    // Flip from the state the user sees, never from the service's `enabled`
    // (they can desync, which turns every click into the opposite action).
    toggleProc.command = [ "/usr/share/omarchy/bin/omarchy-shell", "nightlight",
      wantNight ? "enable" : "disable" ]
    toggleProc.running = true
  }

  onPressed: function() { root.toggle() }

  active: nightlight
  activeText: "󰔎"
  inactiveText: "󰔎"
  activeTooltipText: "Day Light"
  inactiveTooltipText: "Night Light"

  Process {
    id: toggleProc

    stdout: SplitParser {
      onRead: function(line) { root.dbg("ipc:", String(line).trim()) }
    }
    onExited: function(exitCode) { root.dbg("ipc-exit", exitCode); root.probe() }
  }

  Process {
    id: probeProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var text0 = String(text)
        var tmpMatch = text0.match(/state:([^|]*)/)
        var dbgMatch = text0.match(/dbg:([0-9]+)/)
        var tempMatch = tmpMatch ? String(tmpMatch[1]).match(/[0-9]+/) : null
        root.temperature = tempMatch ? Number(tempMatch[0]) : -1
        root.plugDebug = root.plugDebug || (dbgMatch && dbgMatch[1] === "1")
        root.dbg("state temp=" + root.temperature,
          root.nightlight ? "night" : "day")
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.temperature = -1
        root.dbg("state temp=none rc=" + exitCode, root.nightlight ? "night" : "day")
      }
    }
  }

  // hyprctl's temperature is not a file anyone watchable changes, so re-probe
  // periodically. Otherwise a toggle from a menu/keybinding leaves the icon
  // stuck on the previous state, which reads as an inverted button.
  Timer {
    id: syncTimer
    interval: 2000
    running: true
    repeat: true
    onTriggered: root.probe()
  }

  Component.onCompleted: root.probe()
}