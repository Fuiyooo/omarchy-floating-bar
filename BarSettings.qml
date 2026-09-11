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

  // Moves a layout entry across sections (or within one). Draft group edits
  // are cleared: each field immediately commits its value on edit, so stale
  // index-keyed drafts would otherwise repaint the wrong rows after a move.
  function moveEntry(fromSection, fromIndex, toSection, toIndex) {
    if (!barTree || !Util.isPlainObject(barTree.layout)) return false
    var fromList = Array.isArray(barTree.layout[fromSection]) ? barTree.layout[fromSection] : null
    var toList = Array.isArray(barTree.layout[toSection]) ? barTree.layout[toSection] : null
    if (!fromList || !toList) return false
    if (fromIndex < 0 || fromIndex >= fromList.length) return false
    if (toIndex < 0) toIndex = toList.length
    if (fromSection === toSection && fromIndex === toIndex) return false

    var entry = fromList.splice(fromIndex, 1)[0]
    if (fromSection === toSection && fromIndex < toIndex) toIndex -= 1
    if (toIndex < 0) toIndex = 0
    if (toIndex > toList.length) toIndex = toList.length
    toList.splice(toIndex, 0, entry)
    draftGroups = ({})
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

          Item { width: 1; height: Style.spacing.sm }

          Text {
            text: "DRAG ⋮⋮ widgets within/between sections — drop above another widget to slot in front of it. Empty group field = standalone."
            wrapMode: Text.Wrap
            width: card.implicitWidth - Style.spacing.panelPadding * 2
            color: root.fgColor
            opacity: 0.65
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            spacing: Style.spacing.panelGap

            Repeater {
              model: root.sections

              SectionColumn {
                required property string modelData
                columnWidth: (card.implicitWidth - Style.spacing.panelPadding * 2 - Style.spacing.panelGap * 2) / 3
                sectionName: modelData
              }
            }
          }

          Item { width: 1; height: Style.spacing.sm }

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
  // One bar layout section: header, horizontal drag drop zones, the entry
  // rows, and a footer drop slot for appending.
  component SectionColumn: Column {
    id: pillSection

    property real columnWidth: 0
    property string sectionName: ""
    readonly property var entries: {
      var cfg = root.barTree
      var layout = cfg && Util.isPlainObject(cfg.layout) ? cfg.layout : null
      return layout && Array.isArray(layout[sectionName]) ? layout[sectionName] : []
    }

    width: columnWidth > 0 ? columnWidth : 150
    spacing: Style.spacing.xs

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

      EntryCell {
        required property var modelData
        required property int index
        entryModel: modelData
        entryIndex: index
        owningSection: pillSection.sectionName
      }
    }

    // Footer drop slot: append at the end of the section.
    DropArea {
      width: parent.width
      height: Style.spacing.controlHeight
      keys: ["dime-bar-entry"]

      BorderSurface {
        anchors.fill: parent
        visible: parent.containsDrag
        color: "transparent"
        borderSpec: Border.flat(root.fgColor, 1)
        radius: Style.space(4)
      }

      Text {
        anchors.centerIn: parent
        text: "drop to append"
        color: root.fgColor
        opacity: parent.containsDrag ? 0.9 : 0.3
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      onDropped: function (drag) {
        var payload = drag.source && drag.source.dragPayload ? drag.source.dragPayload : null
        if (payload) root.moveEntry(payload.fromSection, payload.fromIndex, pillSection.sectionName, -1)
      }
    }
  }

  component EntryCell: Item {
    id: entryCell

    property var entryModel: null
    property int entryIndex: 0
    property string owningSection: ""
    readonly property var dragPayload: ({
      fromSection: owningSection,
      fromIndex: entryIndex
    })
    readonly property bool dragging: cellArea.drag.active
    readonly property bool hasGroup: !!entryModel && typeof entryModel.group === "string"
      && entryModel.group.length > 0

    width: parent ? parent.width : 150
    implicitHeight: cellCol.implicitHeight
    height: cellCol.implicitHeight

    DropArea {
      anchors { fill: parent; margins: -Style.spacing.xxs }
      keys: ["dime-bar-entry"]
      onDropped: function (drag) {
        var payload = drag.source && drag.source.dragPayload ? drag.source.dragPayload : null
        if (payload)
          root.moveEntry(payload.fromSection, payload.fromIndex, entryCell.owningSection, entryCell.entryIndex)
      }
    }

    BorderSurface {
      anchors.fill: cellCol
      color: root.fgColor
      opacity: entryCell.dragging ? 0.12 : 0.0
      radius: Style.space(3)
    }

    Column {
      id: cellCol

      width: parent.width
      spacing: Style.spacing.xxs

      Row {
        width: parent.width

        Rectangle {
          id: handle

          width: Style.space(14)
          height: Style.space(14)
          radius: width / 2
          color: entryCell.dragging ? Qt.rgba(0, 0, 0, 0.001) : "transparent"
          border.width: 1
          border.color: root.fgColor
          opacity: 0.4
          anchors.verticalCenter: parent.verticalCenter

          MouseArea {
            id: cellArea

            width: Style.space(18)
            height: Style.space(16)
            acceptedButtons: Qt.LeftButton
            cursorShape: Qt.DragMoveCursor
            drag.target: entryCell
            drag.axis: Drag.XAndYAxis
            onPressed: entryCell.Drag.start()
            onReleased: {
              entryCell.x = 0
              entryCell.y = 0
              entryCell.Drag.drop()
            }
          }
        }

        Text {
          width: parent.width - handle.width
          elide: Text.ElideMiddle
          maximumLineCount: 1
          text: entryCell.entryId
          color: root.fgColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      GroupField {
        width: parent.width
        horizontalPadding: 6
        verticalPadding: 2
        font.pixelSize: Style.font.caption
        initialText: {
          var key = entryCell.owningSection + ":" + entryCell.entryIndex
          return root.draftGroups[key] !== undefined
            ? root.draftGroups[key]
            : ((entryCell.entryModel && typeof entryCell.entryModel.group === "string")
               ? entryCell.entryModel.group : "")
        }
        placeholderText: "no group"
        onGroupCommitted: {
          var key = entryCell.owningSection + ":" + entryCell.entryIndex
          var committedGroup = entryCell.entryModel && typeof entryCell.entryModel.group === "string"
            ? entryCell.entryModel.group : ""
          var draft = root.draftGroups
          draft[key] = value
          root.draftGroups = draft
          // editingFinished also fires on focus loss; skip when the value
          // equals what is already committed so refocusing does not re-write
          // identical config.
          if (value !== committedGroup) root.commitGroups()
        }
      }

      ColorFieldRow {
        visible: entryCell.hasGroup
        property string groupName: entryCell.entryModel && typeof entryCell.entryModel.group === "string"
          ? entryCell.entryModel.group : ""
        hexValue: root.committedCapsuleColor(groupName)
        swatchColor: {
          var hex = root.committedCapsuleColor(groupName)
          if (hex !== "") { try { return Qt.color(hex) } catch (e) { } }
          return root.committedBarColorField("background") !== ""
            ? Qt.color(root.committedBarColorField("background"))
            : Color.bar.background
        }
        width: parent.width
        onCommitted: function (hex) { root.setCapsuleColor(groupName, hex) }
      }
    }

    // Strip the visual drag offset the moment the drop resolves (or not):
    // the data model rebuild re-positions everything anyway.
    Drag.active: entryCell.dragging
    Drag.dragType: Drag.Automatic
    Drag.keys: ["dime-bar-entry"]
  }

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
