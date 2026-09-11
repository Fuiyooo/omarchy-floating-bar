import QtQuick
import qs.Ui

// Clickable bar widget that opens this plugin's settings overlay. Follows
// the same third-party pattern as Keysmith: run the shell IPC toggle that
// the host resolves against this plugin's overlay entry point.
BarWidget {
  id: root

  moduleName: "dime.floating-bar"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button

    anchors.fill: parent
    bar: root.bar
    text: "◫"
    interactive: true
    tooltipText: "Floating Bar — settings & groups"

    onPressed: function (button) {
      if (button === Qt.LeftButton && root.bar)
        root.bar.run("omarchy-shell shell toggle dime.floating-bar")
    }
  }
}
