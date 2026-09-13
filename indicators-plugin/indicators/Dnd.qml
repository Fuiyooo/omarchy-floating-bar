import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

// Self-contained do-not-disturb indicator for replacement bars.
//
// The first-party proxy reports `doNotDisturb` as a static false, so like
// StayAwake this copy never trusts it: the display asks the real
// notifications service over the omarchy-shell IPC channel (dndState,
// toggleDnd) and watches the persisted state file
// (~/.local/state/omarchy/notifications.json, written by the service on
// every toggle) so the icon follows external changes as well.
BarIndicator {
  id: root

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy"
  readonly property string stateFile: stateDir + "/notifications.json"
  property bool plugDebug: Quickshell.env("OMARCHY_PLUG_DEBUG") === "1"
  property bool dnd: false

  function dbg() {
    if (!plugDebug) return
    var parts = []
    for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i]))
    console.warn("PLUG dnd " + parts.join(" "))
  }

  function probe() {
    if (probeProc.running) return
    // One call queries the service and reports the engine's debug flag.
    probeProc.command = [ "bash", "-c",
      "v=$(/usr/share/omarchy/bin/omarchy-shell notifications dndState 2>/dev/null); "
      + "d=0; [ -f $HOME/.local/state/omarchy/plugins/dime.floating-bar/debug ] && d=1; "
      + "echo \"state:${v}|dbg:${d}\"" ]
    probeProc.running = true
  }

  function toggle() {
    var silent = !root.dnd
    root.dbg("press want=" + (silent ? "silence" : "allow"))
    toggleProc.command = [ "/usr/share/omarchy/bin/omarchy-shell", "notifications",
      "setDnd", silent ? "true" : "false" ]
    toggleProc.running = true
  }

  onPressed: function() { root.toggle() }

  active: dnd
  activeText: "󰂛"
  inactiveText: "󰂛"
  activeTooltipText: "Allow Notifications"
  inactiveTooltipText: "Silence Notifications"

  Process {
    id: toggleProc

    stdout: SplitParser {
      onRead: function(line) { root.dbg("ipc:", String(line).trim()) }
    }
    onExited: function(exitCode) { root.dbg("ipc-exit", exitCode); root.probe() }
  }

  Process {
    id: probeProc

    stdout: SplitParser {
      onRead: function(line) {
        var text0 = String(line)
        var stateMatch = text0.match(/state:([^|]*)/)
        var dbgMatch = text0.match(/dbg:([0-9]+)/)
        root.dnd = stateMatch && String(stateMatch[1]).toLowerCase() === "on"
        root.plugDebug = root.plugDebug || (dbgMatch && dbgMatch[1] === "1")
        root.dbg("state", root.dnd ? "on" : "off")
      }
    }
  }

  // Watch the state directory (the json file may not exist yet) and re-probe
  // whenever the service writes its persisted DND preference.
  FileView {
    path: root.stateDir
    watchChanges: true
    printErrors: false
    onFileChanged: root.probe()
  }

  Component.onCompleted: root.probe()
}