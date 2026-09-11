import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Floating settings surface for dime.floating-bar. Toggles the floating
// layout (edge-gap stepper) and capsule groups, and assigns `group` names to
// bar entries per section. Everything persists through config-apply.py (the
// native file-writer pattern Keysmith uses): the plugin rewrites the whole
// `bar:` subtree of shell.json and the running bar hot-reloads it.
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
  readonly property bool hasConfigWriter: true

  // Authoritative working copy of the committed `bar:` subtree, deep-cloned
  // and re-seeded fresh from disk on every open(). Edits mutate this object;
  // commit replaces the whole subtree via config-apply.py.
  property var barTree: null

  readonly property bool floatingOn: !barTree || !Util.isPlainObject(barTree.floating)
    ? true : barTree.floating.enabled !== false
  readonly property int floatingGap: barTree && Util.isPlainObject(barTree.floating)
    && barTree.floating.gap !== undefined ? Math.round(Number(barTree.floating.gap)) : Style.space(9)
  readonly property bool capsulesOn: !!barTree && Util.isPlainObject(barTree.capsules)
    ? barTree.capsules.enabled !== false : true

  // Draft group edits per "section:index", keyed the same as the section
  // editor rows. Applied en-masse by Apply groups.
  property var draftGroups: ({})

  // Fresh read of shell.json through the plugin helper (synchronous through
  // the Process stdout collector), because an under-load FileView returns
  // empty text and a stale panel snapshot would clobber the whole bar tree.
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace("file://", "").replace(/\/$/, "/")

  Process {
    id: readProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.seedFromReply(text)
    }
  }

  function seedFromReply(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw)) } catch (e) { parsed = null }
    if (!parsed || parsed.ok !== true) {
      root.status = "failed: " + (parsed && parsed.error ? parsed.error : "config read")
      statusTimer.restart()
      return
    }
    var cfg = Util.isPlainObject(parsed.config) ? parsed.config : {}
    var bar = Util.isPlainObject(cfg.bar) ? cfg.bar : {}
    barTree = JSON.parse(JSON.stringify(bar))
    draftGroups = ({})
    if (!Util.isPlainObject(barTree.layout))
      barTree.layout = { left: [], center: [], right: [] }
    for (var i = 0; i < root.sections.length; i++)
      if (!Array.isArray(barTree.layout[root.sections[i]]))
        barTree.layout[root.sections[i]] = []
  }

  function seedBarTree() {
    readProc.command = ["python3", root.pluginDir + "config-apply.py", "read"]
    readProc.running = true
  }

  function applyBarTree() {
    if (!barTree) {
      root.status = "no config loaded"
      statusTimer.restart()
      return false
    }
    // Re-assign the clone so nested mutations notify the QML bindings —
    // that is what makes toggles flip on the spot instead of after reopen.
    barTree = JSON.parse(JSON.stringify(barTree))
    var payload = ""
    try { payload = JSON.stringify({ bar: JSON.parse(JSON.stringify(barTree)) }) } catch (e) {
      root.status = "failed: serialise"
      statusTimer.restart()
      return false
    }
    console.warn("PLUG applyBarTree: writing", payload.length, "bytes")
    var dir = String(Qt.resolvedUrl(".")).replace(/\/$/, "/")
    dir = dir.replace("file://", "")
    applyProc.command = ["python3", dir + "config-apply.py", payload]
    applyProc.running = true
    return true
  }

  function setFloating(on) {
    if (!barTree) return false
    if (!Util.isPlainObject(barTree.floating)) barTree.floating = {}
    barTree.floating.enabled = on
    if (barTree.floating.gap === undefined) barTree.floating.gap = Style.space(9)
    return applyBarTree()
  }

  function setGap(gap) {
    if (!barTree) return false
    var n = Math.max(0, Math.min(64, Math.round(gap)))
    if (!Util.isPlainObject(barTree.floating)) barTree.floating = { enabled: true }
    barTree.floating.gap = n
    return applyBarTree()
  }

  readonly property int cornerRadius: barTree && Util.isPlainObject(barTree.corners)
    && barTree.corners.radius !== undefined ? Math.round(Number(barTree.corners.radius)) : 0

  function setRadius(radius) {
    if (!barTree) return false
    var n = Math.max(0, Math.min(18, Math.round(radius)))
    if (!Util.isPlainObject(barTree.corners)) barTree.corners = {}
    barTree.corners.radius = n
    return applyBarTree()
  }

  function setCapsules(on) {
    if (!barTree) return false
    if (!Util.isPlainObject(barTree.capsules)) barTree.capsules = {}
    barTree.capsules.enabled = on
    return applyBarTree()
  }
  readonly property bool backdropOn: barTree && Util.isPlainObject(barTree.capsules)
    ? barTree.capsules.backdrop !== false : true

  function setBackdrop(on) {
    if (!barTree) return false
    if (!Util.isPlainObject(barTree.capsules)) barTree.capsules = {}
    barTree.capsules.backdrop = on
    return applyBarTree()
  }

  function setCapsuleColor(group, hex) {
    if (!barTree || String(group).length === 0) return false
    if (!Util.isPlainObject(barTree.capsules)) barTree.capsules = {}
    if (!Util.isPlainObject(barTree.capsules.styles)) barTree.capsules.styles = {}
    hex = String(hex || "").trim()
    var styles = barTree.capsules.styles
    var style = Util.isPlainObject(styles[group]) ? styles[group] : {}
    if (hex === "") delete style.color
    else try { Qt.color(style.color = hex) } catch (e) { return false }
    if (Object.keys(style).length > 0) styles[group] = style
    else delete styles[group]
    if (Object.keys(styles).length === 0) delete barTree.capsules.styles
    return applyBarTree()
  }

  function committedCapsuleColor(group) {
    var styles = barTree && Util.isPlainObject(barTree.capsules) && Util.isPlainObject(barTree.capsules.styles)
      ? barTree.capsules.styles : null
    var style = styles ? styles[group] : null
    return style && typeof style.color === "string" ? style.color : ""
  }

  function setBarColorField(which, hex) {
    if (!barTree) return false
    hex = String(hex || "").trim()
    if (hex !== "") { try { Qt.color(hex) } catch (e) { return false } }
    if (!Util.isPlainObject(barTree.colors)) barTree.colors = {}
    if (hex === "") delete barTree.colors[which]
    else barTree.colors[which] = hex
    if (Object.keys(barTree.colors).length === 0) delete barTree.colors
    return applyBarTree()
  }

  function committedBarColorField(which) {
    var colors = barTree && Util.isPlainObject(barTree.colors) ? barTree.colors : null
    return colors && typeof colors[which] === "string" ? colors[which] : ""
  }


  function commitGroups() {
    if (!barTree) return false
    var layout = Util.isPlainObject(barTree.layout) ? barTree.layout : null
    if (!layout) return false
    for (var si = 0; si < root.sections.length; si++) {
      var section = root.sections[si]
      var list = Array.isArray(layout[section]) ? layout[section] : []
      for (var i = 0; i < list.length; i++) {
        var key = section + ":" + i
        var entry = Util.isPlainObject(list[i]) ? list[i] : {}
        var group = draftGroups[key]
        if (group === undefined)
          group = typeof entry.group === "string" ? entry.group : ""
        if (group.length > 0) entry.group = group
        else delete entry.group
      }
    }
    return applyBarTree()
  }

  function open(payloadJson) {
    console.warn("PLUG settings open")
    opened = true
    seedBarTree()
  }

  function close() {
    opened = false
  }

  Timer {
    id: statusTimer

    interval: 2600
    onTriggered: root.status = ""
  }

  Process {
    id: applyProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var reply = JSON.parse(text)
          root.status = reply.ok === true ? "saved" : "failed: " + (reply.error || "unknown")
        } catch (e) {
          root.status = "failed: unparsable writer reply"
        }
        statusTimer.restart()
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && root.status.indexOf("failed") !== 0) {
        root.status = "failed: config-apply exited " + exitCode
        statusTimer.restart()
      }
    }
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
        anchors.fill: parent
        onClicked: root.close()
      }
    }

    BorderSurface {
      id: card

      implicitWidth: 760
      implicitHeight: contentCol.implicitHeight + Style.spacing.panelPadding
      anchors.centerIn: parent
      color: root.cardColor
      borderSpec: Border.surfaceSpec("menu", "border", root.borderColor, 1)
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: { } }

      Flickable {
        anchors.fill: parent
        contentHeight: contentCol.implicitHeight + Style.spacing.panelPadding
        clip: true

        Column {
          id: contentCol

          x: (card.implicitWidth - width) / 2
          y: Style.spacing.panelPadding / 2
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
            text: "Floating: inset the bar from the screen edges. Capsules: consecutive entries sharing the same group render in one capsule. Entries at the top and bottom of a group are labelled by position."
            color: root.fgColor
            opacity: 0.75
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            spacing: Style.spacing.lg

            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              checked: root.floatingOn
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

              Button { text: "-"; onClicked: root.setGap(root.floatingGap - 1) }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "gap " + root.floatingGap + "px"
                color: root.fgColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Button { text: "+"; onClicked: root.setGap(root.floatingGap + 1) }
            }
          }

          Row {
            spacing: Style.spacing.lg

            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              checked: root.capsulesOn
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

          // ---------- Corner rounding row
          Row {
            spacing: Style.spacing.lg

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Rounded corners"
              color: root.fgColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Row {
              spacing: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter

              Button { text: "-"; onClicked: root.setRadius(root.cornerRadius - 1) }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.cornerRadius + "px"
                color: root.fgColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Button { text: "+"; onClicked: root.setRadius(root.cornerRadius + 1) }
            }
          }

          Item { width: 1; height: Style.spacing.sm }

          Row {
            spacing: Style.spacing.panelGap

            Repeater {
              model: root.sections

              Column {
                id: pillSection

                required property string modelData
                readonly property string sectionName: modelData
                readonly property var entries: {
                  var layout = barTree && Util.isPlainObject(barTree.layout) ? barTree.layout : null
                  return layout && Array.isArray(layout[sectionName]) ? layout[sectionName] : []
                }

                width: (card.implicitWidth - Style.spacing.panelPadding * 2 - Style.spacing.panelGap * 2) / 3

                Text {
                  text: pillSection.sectionName.toUpperCase()
                  color: root.fgColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1.5
                  opacity: 0.7
                }

                Repeater {
                  model: pillSection.entries

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
                      initialText: {
                        var key = pillSection.sectionName + ":" + index
                        return draftGroups[key] !== undefined
                          ? draftGroups[key]
                          : ((modelData && typeof modelData.group === "string") ? modelData.group : "")
                      }
                      placeholderText: "no group"
                      enabled: root.opened
                      onGroupCommitted: {
                        var key = pillSection.sectionName + ":" + index
                        var committedGroup = (modelData && typeof modelData.group === "string")
                          ? modelData.group : ""
                        var draft = root.draftGroups
                        draft[key] = value
                        root.draftGroups = draft
                        // editingFinished also fires on focus loss; skip when the
                        // value equals what is already committed so focus change
                        // does not re-write identical config.
                        if (value !== committedGroup)
                          root.commitGroups()
                      }
                    }

                    // Capsule colour, editable only once the entry carries a
                    // committed group name (entries sharing a group edit the
                    // same style key).
                    ColorFieldRow {
                      visible: !!modelData && typeof modelData.group === "string"
                        && modelData.group.length > 0
                      property string groupName: modelData ? (modelData.group || "") : ""
                      hexValue: root.committedCapsuleColor(groupName)
                      swatchColor: {
                        var hex = root.committedCapsuleColor(groupName)
                        if (hex !== "") { try { return Qt.color(hex) } catch (e) { } }
                        return root.committedBarColorField("background") !== ""
                          ? Qt.color(root.committedBarColorField("background"))
                          : Color.bar.background
                      }
                      width: parent.width
                      onCommitted: function (hex) {
                        root.setCapsuleColor(groupName, hex)
                      }
                    }
                  }
                }
              }
            }
          }

          Text {
            visible: root.status !== ""
            text: root.status
            color: root.fgColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // Numeric row: -/+ buttons plus a manually editable text field. The text
  // re-syncs with the committed value whenever the committed value object is
  // reassigned (every write swaps in a fresh clone).
  component NumberStepper: Row {
    id: stepper

    property int stepperValue: 0
    property int minimum: 0
    property int maximum: 64
    signal committed(int value)

    function commitNow(raw) {
      var n = parseInt(raw, 10)
      if (!isFinite(n)) {
        valueField.text = "" + stepper.stepperValue
        return
      }
      stepper.committed(Math.max(stepper.minimum, Math.min(stepper.maximum, n)))
    }

    spacing: Style.spacing.xs

    Button { text: "-"; onClicked: stepper.commitNow("" + (stepper.stepperValue - 1)) }
    TextField {
      id: valueField

      width: 64
      horizontalPadding: 6
      verticalPadding: 2
      font.pixelSize: Style.font.caption
      placeholderText: stepper.minimum + "-" + stepper.maximum
      onAccepted: stepper.commitNow(text)
      Component.onCompleted: valueField.text = "" + stepper.stepperValue
      Connections {
        target: stepper
        function onStepperValueChanged() { valueField.text = "" + stepper.stepperValue }
      }
    }
    Button { text: "+"; onClicked: stepper.commitNow("" + (stepper.stepperValue + 1)) }
  }


  // Hex color row: small current-swatch chip next to a manual text field.
  // Empty commits restore the theme default for that key.
  component ColorFieldRow: Row {
    id: colorRow

    property string hexValue: ""
    property color swatchColor: "transparent"
    signal committed(string hex)

    spacing: Style.spacing.xs

    Rectangle {
      width: Style.font.body
      height: Style.font.body
      radius: Math.min(width, height) / 2
      color: colorRow.swatchColor
      border.width: 1
      border.color: root.borderColor
      anchors.verticalCenter: parent.verticalCenter
    }

    TextField {
      id: hexField

      width: 96
      horizontalPadding: 6
      verticalPadding: 2
      font.pixelSize: Style.font.caption
      placeholderText: "#RRGGBB"
      onAccepted: colorRow.committed(hexField.text.trim())
      Component.onCompleted: hexField.text = colorRow.hexValue
      Connections {
        target: colorRow
        function onHexValueChanged() { hexField.text = colorRow.hexValue }
      }
    }
  }

  component GroupField: TextField {
    id: gf

    property string initialText: ""
    signal groupCommitted(string value)

    font.pixelSize: Style.font.caption
    placeholderText: "no group"
    onAccepted: gf.groupCommitted(gf.text.trim())
    onEditingFinished: gf.groupCommitted(gf.text.trim())
    Component.onCompleted: text = gf.initialText
  }
}
