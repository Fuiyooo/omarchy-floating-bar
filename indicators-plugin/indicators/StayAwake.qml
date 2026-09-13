import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

// Self-contained stay-awake indicator for replacement bars.
//
// The first-party proxy handed to replacement bars reports `stayAwake` as a
// static false and forgets the state whenever the bar rebuilds, so this copy
// never trusts it: the display reads the real idle service's marker file
// (~/.local/state/omarchy/indicators/stay-awake, exists = staying awake) and
// clicks go through the omarchy-shell IPC channel (`omarchy-shell idle
// enable|disable`), which the service itself answers.
BarIndicator {
  id: root

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/indicators"
  readonly property string flagDir: Quickshell.env("HOME") + "/.local/state/omarchy/plugins/dime.floating-bar"
  // The engine root's flag-file debug switch; env fallback for manual runs.
  property bool plugDebug: Quickshell.env("OMARCHY_PLUG_DEBUG") === "1"
  property bool stayAwakeState: false

  function dbg() {
    if (!plugDebug) return
    var parts = []
    for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i]))
    console.warn("PLUG stayAwake " + parts.join(" "))
  }

  function toggle() {
    var want = !root.stayAwakeState
    root.dbg("press want=" + (want ? "awake" : "idle"))
    // disable -> setIdleEnabled(false) -> applyStayAwake(true)
    toggleProc.command = [ "/usr/share/omarchy/bin/omarchy-shell", "idle", want ? "disable" : "enable" ]
    toggleProc.running = true
  }

  onPressed: function() { root.toggle() }

  active: stayAwakeState
  activeText: "󰅶"
  inactiveText: "󰅶"
  activeTooltipText: "Allow Idle Lock & Screensaver"
  inactiveTooltipText: "Stay Awake"

  Process {
    id: toggleProc

    stdout: SplitParser {
      onRead: function(line) { root.dbg("ipc:", String(line).trim()) }
    }
    onExited: function(exitCode) { root.dbg("ipc-exit", exitCode) }
  }

  Process {
    id: stateProbe

    command: [ "bash", "-c",
      "s=no; d=0; "
      + "[ -f $HOME/.local/state/omarchy/indicators/stay-awake ] && s=yes; "
      + "[ -f $HOME/.local/state/omarchy/plugins/dime.floating-bar/debug ] && d=1; "
      + "echo \"$s $d\"" ]
    stdout: SplitParser {
      onRead: function(line) {
        var parts = String(line).trim().split(/\s+/)
        root.stayAwakeState = parts[0] === "yes"
        root.plugDebug = root.plugDebug || parts[1] === "1"
        root.dbg("state", root.stayAwakeState ? "awake" : "idle")
      }
    }
  }

  // FileView cannot watch a file that may not exist yet, so watch the parent
  // directory and re-probe on every event (same pattern as the bar's debug
  // flag switch). Survives pluginReloading: the probe reruns on each mount.
  FileView {
    path: root.stateDir
    watchChanges: true
    printErrors: false
    onFileChanged: stateProbe.running = true
  }

  Component.onCompleted: stateProbe.running = true
}