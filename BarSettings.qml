import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Floating settings surface for the dime.floating-bar plugin. Lets the user
// toggle the floating layout (with an edge-gap stepper) and capsule groups,
// and assign `group` names to bar entries per section. All changes persist
// straight into the `bar:` subtree of shell.json via the host facade's
// mutateShellConfig, which the running bar hot-reloads.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property string status: ""

  readonly property color cardColor: Color.menu.background
  readonly property color fgColor: Color.menu.text
  readonly property color borderColor: Color.menu.border
  readonly property string fontFamily: Style.font.family
  readonly property var sections: ["left", "center", "right"]
  // Current committed state, read at open time from the facade's barConfig
  // snapshot. The overlay is not keepLoaded, so every open re-injects fresh.
  readonly property var barState: root.shell && Util.isPlainObject(root.shell.barConfig)
    ? root.shell.barConfig : {}
  readonly property var cFloating: Util.isPlainObject(barState.floating) ? barState.floating : {}
  readonly property bool floatingOn: cFloating.enabled !== false
  readonly property int floatingGap: {
    var n = Number(cFloating.gap !== undefined ? cFloating.gap : NaN)
    return isFinite(n) && n >= 0 ? Math.round(n) : Style.space(9)
  }
  readonly property bool capsulesOn: Util.isPlainObject(barState.capsules)
    ? barState.capsules.enabled !== false : false

  // Live text-field edits per section: map of "section:index" -> group string
  property var draftGroups: ({})

  readonly property bool hasConfigWriter: root.shell && typeof root.shell.mutateShellConfig === "function"

  function writeConfig(mutate) {
    if (!root.hasConfigWriter) {
      root.status = "config access unavailable"
      return false
    }
    var ok = root.shell.mutateShellConfig(mutate)
    root.status = ok ? "saved" : "config write failed"
    statusTimer.restart()
    return ok
  }

  function commitGroups() {
    // Flush every pending draft edit into the next config write.
    return writeConfig(function(cfg) {
      var bar = Util.isPlainObject(cfg.bar) ? cfg.bar : {}
      var layout = Util.isPlainObject(bar.layout) ? bar.layout : {}
      for (var si in root.sections) {
        var section = root.sections[si]
        var list = Util.isPlainObject(layout[section]) ? layout[section] : []
        for (var i = 0; i < list.length; i++) {
          var key = section + ":" + i
          var entry = Util.isPlainObject(list[i]) ? list[i] : {}
          var group = root.draftGroups[key]
          if (group === undefined) {
            group = typeof entry.group === "string" ? entry.group : ""
          }
          if (group.length > 0) entry.group = group
          else delete entry.group
        }
      }
      bar.layout = layout
      cfg.bar = bar
    })
  }

  function setFloating(on) {
    return writeConfig(function(cfg) {
      var bar = Util.isPlainObject(cfg.bar) ? cfg.bar : {}
      bar.floating = { enabled: on, gap: root.floatingGap }
      cfg.bar = bar
    })
  }

  function setGap(gap) {
    var n = Math.max(0, Math.min(64, Math.round(gap)))
    return writeConfig(function(cfg) {
      var bar = Util.isPlainObject(cfg.bar) ? cfg.bar : {}
      bar.floating = { enabled: root.floatingOn, gap: n }
      cfg.bar = bar
    })
  }

  function setCapsules(on) {
    return writeConfig(function(cfg) {
      var bar = Util.isPlainObject(cfg.bar) ? cfg.bar : {}
      bar.capsules = { enabled: on }
      cfg.bar = bar
    })
  }

  function open(payloadJson) {
    opened = true
    root.status = ""
    root.draftGroups = ({})
  }

  function close() {
    opened = false
  }

  Timer {
    id: statusTimer
    interval: 2500
    onTriggered: root.status = ""
  }

  PanelWindow {
    id: overlay

    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "dime-floating-bar-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim

      MouseArea {
        // Click-outside dismissals, matching other omarchy overlay panels.
        anchors.fill: parent
        onClicked: root.close()
      }
    }

    BorderSurface {
      id: card

      implicitWidth: 760
      implicitHeight: contentCol.implicitHeight + Style.spacing.panelPadding * 2
      anchors.centerIn: parent
      color: root.cardColor
      borderSpec: Border.surfaceSpec("menu", "border", root.borderColor, 1)
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: { } }

      Flickable {
        anchors.fill: parent
        contentHeight: contentCol.implicitHeight + Style.spacing.panelPadding * 2
        clip: true

        Column {
          id: contentCol

          x: parent.width / 2 - width / 2
          y: Style.spacing.panelPadding
          spacing: Style.spacing.panelGap

          Text {
            text: "FLOATING BAR"
            color: root.fgColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.letterSpacing: 1.2
          }

          Text {
            width: card.implicitWidth - Style.spacing.panelPadding * 2
            wrapMode: Text.Wrap
            text: "Floating: inset the bar from the screen edges. Capsules: entries sharing the same \"group\" render in one capsule. Group edits apply per section, in layout order."
            color: Qt.darker(root.fgColor, 1.8)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // ---------- Floating row
          Row {
            spacing: Style.spacing.lg

            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              checked: root.floatingOn
              interactive: root.hasConfigWriter
              onToggled: root.setFloating(!root.floatingOn)
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Floating bar"
              color: root.fgColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Row {
              visible: root.floatingOn
              spacing: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter

              Button {
                id: minusBtn
                text: "<"
                onClicked: root.setGap(root.floatingGap - 1)
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "gap " + root.floatingGap + "px"
                color: root.fgColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Button {
                id: plusBtn
                text: ">"
                onClicked: root.setGap(root.floatingGap + 1)
              }
            }
          }

          // ---------- Capsules row
          Row {
            spacing: Style.spacing.lg

            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              checked: root.capsulesOn
              interactive: root.hasConfigWriter
              onToggled: root.setCapsules(!root.capsulesOn)
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Capsule groups"
              color: root.fgColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          // ---------- Group editor per section
          // Spacer used purely for rhythm between the toggles and grouped
          // section editors.
          Item { width: 1; height: Style.spacing.sm }

          Row {
            spacing: Style.spacing.panelGap

            Repeater {
              model: root.sections

              Column {
                id: pillSection
                required property string modelData
                readonly property string label: modelData
                readonly property var entries: {
                  var cfg = root.barState
                  var layout = cfg && Util.isPlainObject(cfg.layout) ? cfg.layout : null
                  return layout && Array.isArray(layout[label]) ? layout[label] : []
                }

                width: (card.implicitWidth - Style.spacing.panelPadding * 2 - Style.spacing.panelGap * 2) / 3

                Text {
                  text: pillSection.label.toUpperCase()
                  color: root.fgColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1.5
                  opacity: 0.7
                }

                Repeater {
                  model: entries

                  Column {
                    required property var modelData
                    required property int index
                    width: parent.width
                    spacing: Style.spacing.xxs

                    Text {
                      width: parent.width
                      elide: Text.ElideMiddle
                      maximumLineCount: 1
                      text: (modelData && modelData.id) || "?"
                      color: root.fgColor
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    GroupField {
                      width: parent.width
                      horizontalPadding: 6
                      verticalPadding: 2
                      font.pixelSize: Style.font.caption
                      initialText: root.draftGroups[pillSection.label + ":" + index] !== undefined
                        ? root.draftGroups[pillSection.label + ":" + index]
                        : (modelData.group || "")
                      hint: "no group"
                      enabled: root.hasConfigWriter
                      onGroupEdited: function (value) {
                        var draft = root.draftGroups
                        draft[pillSection.label + ":" + index] = value
                        root.draftGroups = draft
                      }
                    }
                  }
                }
              }
            }
          }

          Button {
            text: "Apply groups"
            bordered: true
            enabled: root.hasConfigWriter
            onClicked: root.commitGroups()
          }

          Text {
            text: root.status === "" ? "" : root.status
            color: root.fgColor
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  component GroupField: TextField {
    id: gf

    property string hint: ""
    property string initialText: ""
    signal groupEdited(string value)

    placeholderText: gf.hint
    onAccepted: gf.groupEdited(gf.text.trim())

    Component.onCompleted: text = gf.initialText
  }
}
