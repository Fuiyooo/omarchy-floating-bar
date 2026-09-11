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

  // ---------- drag engine (custom hit-testing, no QML Drag/DropAreas)
  property var _sectionColumns: ({})   // sectionName -> SectionColumn item
  property var _cellsBySection: ({})   // sectionName -> [EntryCell, ...]
  property var dragState: null         // {fromSection, fromIndex, id} | null
  property string dragHoverSection: ""
  property int dragHoverIndex: -2      // -1 append, -2 nothing

  function registerSectionColumn(name, column) {
    var next = ({})
    for (var k in _sectionColumns) next[k] = _sectionColumns[k]
    next[name] = column
    _sectionColumns = next
  }

  function unregisterSectionColumn(name) {
    var next = ({})
    for (var k in _sectionColumns) if (k !== name) next[k] = _sectionColumns[k]
    _sectionColumns = next
  }

  property int _revision: 0

  function registerCell(section, cell) {
    var list = Util.isPlainObject(_cellsBySection) ? (_cellsBySection[section] || []) : []
    if (list.indexOf(cell) !== -1) return
    list.push(cell)
    _cellsBySection[section] = list
  }

  function unregisterCell(section, cell) {
    var list = _cellsBySection[section]
    if (!Array.isArray(list)) return
    var idx = list.indexOf(cell)
    if (idx !== -1) list.splice(idx, 1)
  }

  function allGroups() {
    var out = []
    var layout = barTree && Util.isPlainObject(barTree.layout) ? barTree.layout : null
    if (layout) {
      for (var i = 0; i < root.sections.length; i++) {
        var list = Array.isArray(layout[root.sections[i]]) ? layout[root.sections[i]] : []
        for (var j = 0; j < list.length; j++) {
          var entry = list[j]
          var grp = entry && typeof entry.group === "string" ? entry.group : ""
          if (grp.length > 0 && out.indexOf(grp) === -1) out.push(grp)
        }
      }
    }
    return out
  }

  function capsulePreviewColor(groupName, fallback) {
    var hex = root.committedCapsuleColor(groupName)
    if (hex !== "") { try { return Qt.color(hex) } catch (e) { } }
    return fallback
  }

  function capsuleFill() {
    var hex = root.committedBarColorField("background")
    if (hex !== "") { try { return Qt.color(hex) } catch (e) { } }
    return Color.bar.background
  }

  function shortWidgetId(id) {
    var parts = String(id || "").split(".")
    if (parts.length > 1 && (parts[0] === "omarchy" || parts[0] === "dime"))
      parts.shift()
    return parts.join(".")
  }

  function startDrag(cell) {
    if (!cell) return
    var center = cell.mapToItem(null, cell.width / 2, cell.height / 2)
    dragState = {
      cell: cell,
      fromSection: cell.owningSection,
      fromIndex: cell.entryIndex,
      id: cell.entryId
    }
    try {
      var rootPoint = root.mapFromItem(null, center.x, center.y)
      dragGhost.ghostX = rootPoint.x
      dragGhost.ghostY = rootPoint.y
      dragScene = { x: center.x, y: center.y }
    } catch (e) { }
  }

  function updateDragHover(scenePoint) {
    if (!dragState) return
    try {
      var rootPointNow = root.mapFromItem(null, scenePoint.x, scenePoint.y)
      dragGhost.ghostX = rootPointNow.x
      dragGhost.ghostY = rootPointNow.y
      dragScene = { x: scenePoint.x, y: scenePoint.y }
    } catch (e) { }
    var hover = { section: "", index: -2 }
    for (var name in _sectionColumns) {
      var column = _sectionColumns[name]
      if (!column) continue
      var local = column.mapFromItem(null, scenePoint.x, scenePoint.y)
      if (local.x < 0 || local.x > column.width || local.y < 0 || local.y > column.height) continue
      hover = { section: name, index: -1 }
      var cells = _cellsBySection[name]
      if (Array.isArray(cells)) {
        for (var i = 0; i < cells.length; i++) {
          var cell = cells[i]
          if (!cell || cell === dragState.cell) continue
          var center = cell.mapToItem(null, cell.width / 2, cell.height / 2)
          if (scenePoint.y < center.y) {
            hover = { section: name, index: cell.entryIndex }
            break
          }
        }
      }
      break
    }
    dragHoverSection = hover.section
    dragHoverIndex = hover.index

    try {
      var rootPoint = root.mapFromItem(null, scenePoint.x, scenePoint.y)
      dragGhost.ghostX = rootPoint.x
      dragGhost.ghostY = rootPoint.y
    } catch (e) { }
  }

  function finishDrag() {
    if (dragState && dragHoverSection !== "") {
      var sameSection = dragHoverSection === dragState.fromSection
      var sameIndex = dragHoverIndex === dragState.fromIndex
      if (!sameSection || !sameIndex)
        moveEntry(dragState.fromSection, dragState.fromIndex, dragHoverSection, dragHoverIndex)
    }
    dragState = null
    dragHoverSection = ""
    dragHoverIndex = -2
  }

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

  // Floating drag ghost: shows the dragged widget's real name so the user
  // always knows what is being moved.
  Item {
    id: dragGhost

    visible: root.dragState !== null
    z: 1000
    width: Math.max(90, ghostLabel.implicitWidth + 20)
    height: ghostLabel.implicitHeight + 12
    property real ghostX: 0
    property real ghostY: 0

    x: ghostX - width / 2
    y: ghostY - height / 2

    Row {
      anchors.centerIn: parent
      spacing: Style.spacing.xs

      Rectangle {
        width: Style.space(8)
        height: Style.space(8)
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: {
          if (!root.dragState) return "transparent"
          var cell = root.dragState.cell
          var group = cell && cell.entryModel && typeof cell.entryModel.group === "string"
            ? cell.entryModel.group : ""
          var hex = root.committedCapsuleColor(group)
          if (hex !== "") { try { return Qt.color(hex) } catch (e) { } }
          return root.fgColor
        }
      }

      Text {
        id: ghostLabel

        text: root.dragState ? root.shortWidgetId(root.dragState.id) : ""
        color: root.fgColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    BorderSurface {
      anchors.fill: parent
      color: root.cardColor
      borderSpec: Border.surfaceSpec("menu", "border", root.borderColor, 1)
      radius: Style.space(6)
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

            NumberStepper {
              visible: root.floatingOn
              stepperValue: root.floatingGap
              minimum: 0
              maximum: 64
              anchors.verticalCenter: parent.verticalCenter
              onCommitted: function (value) { root.setGap(value) }
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

            NumberStepper {
              stepperValue: root.cornerRadius
              minimum: 0
              maximum: 18
              anchors.verticalCenter: parent.verticalCenter
              onCommitted: function (value) { root.setRadius(value) }
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

          // ---------- Capsule colour editor (separate from the drag cards)
          Item { width: 1; height: Style.spacing.xs }

          Text {
            text: "CAPSULE COLOURS"
            color: root.fgColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.5
            opacity: 0.7
          }

          Repeater {
            model: root.allGroups()

            Row {
              required property string modelData
              spacing: Style.spacing.sm

              Text {
                width: 110
                elide: Text.ElideMiddle
                maximumLineCount: 1
                text: modelData
                color: root.fgColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              ColorFieldRow {
                property string grp: modelData
                hexValue: root.committedCapsuleColor(modelData)
                swatchColor: root.capsulePreviewColor(modelData, root.fgColor)
                onCommitted: function (hex) { root.setCapsuleColor(modelData, hex) }
              }
            }
          }

          Item { width: 1; height: Style.spacing.lg }

          Text {
            text: "CAPSULE items sharing a group render in one capsule; ungrouped widgets float as single capsules when the full bar background is off."
            wrapMode: Text.Wrap
            width: card.implicitWidth - Style.spacing.panelPadding * 2
            color: root.fgColor
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
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
  // One bar layout section: header, entry cells, and a footer slot that is
  // the append drop target. Hit-testing runs against the live column rects;
  // no QML Drag/DropArea involvement.
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

    // Footer append slot highlight.
    Item {
      width: parent.width
      height: Style.spacing.controlHeight

      Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: root.dragHoverSection === pillSection.sectionName
          && root.dragHoverIndex === -1 ? 1 : 0
        border.color: root.fgColor
        opacity: 0.6
        radius: Style.space(4)
      }

      Text {
        anchors.centerIn: parent
        text: "drop to append"
        color: root.fgColor
        opacity: root.dragHoverSection === pillSection.sectionName
          && root.dragHoverIndex === -1 ? 0.9 : 0.3
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Component.onCompleted: root.registerSectionColumn(sectionName, pillSection)
    Component.onDestruction: root.unregisterSectionColumn(sectionName)
  }

  component EntryCell: Item {
    id: entryCell

    property var entryModel: null
    property int entryIndex: 0
    property string owningSection: ""
    readonly property string entryId: entryModel && entryModel.id ? String(entryModel.id) : "?"
    readonly property var dragPayload: ({
      fromSection: owningSection,
      fromIndex: entryIndex,
      id: entryModel && entryModel.id ? entryModel.id : "?"
    })
    readonly property bool dragging: root.dragState !== null && root.dragState.cell === entryCell
    readonly property bool hasGroup: !!entryModel && typeof entryModel.group === "string"
      && entryModel.group.length > 0
    readonly property bool hovered: root.dragState !== null
      && root.dragHoverSection === owningSection && root.dragHoverIndex === entryIndex

    width: parent ? parent.width : 150
    implicitHeight: 21
    height: 21
    opacity: dragging ? 0.45 : 1.0


    Rectangle {
      id: cardFrame

      width: parent.width
      height: 21
      radius: 5
      border.width: entryCell.hovered ? 2 : 1
      border.color: root.fgColor
      color: entryCell.hasGroup
        ? Qt.rgba(capsuleFill().r, capsuleFill().g, capsuleFill().b, 0.16)
        : "transparent"

      Item {
        id: handle

        x: 4
        width: 18
        height: 20

        Text {
          anchors.centerIn: parent
          text: "⋮⋮"
          color: root.fgColor
          opacity: 0.55
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          id: cellArea

          anchors.fill: parent
          acceptedButtons: Qt.LeftButton
          cursorShape: Qt.DragMoveCursor
          onPressed: root.startDrag(entryCell)
          onPositionChanged: function (mouse) {
            if (!entryCell.dragging) return
            var scene = mapToItem(null, mouse.x + width / 2, mouse.y + height / 2)
            root.updateDragHover(scene)
          }
          onReleased: root.finishDrag()
          onCanceled: root.finishDrag()
        }
      }

      Rectangle {
        x: 26
        width: 8
        height: 8
        radius: 4
        y: 6
        visible: entryCell.hasGroup
        color: {
          var grp = entryCell.entryModel && typeof entryCell.entryModel.group === "string"
            ? entryCell.entryModel.group : ""
          var hex = root.committedCapsuleColor(grp)
          if (hex !== "") { try { return Qt.color(hex) } catch (e) { } }
          return root.fgColor
        }
      }

      Text {
        readonly property string label: root.shortWidgetId(entryCell.entryId)

        anchors.left: handle.right
        anchors.leftMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - 60
        elide: Text.ElideRight
        text: label
        color: root.fgColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption

      }

      Item {
        // keeps the clickable handle above the label row in stacking order
        z: 2
      }
    }

    Component.onCompleted: root.registerCell(owningSection, entryCell)
    Component.onDestruction: root.unregisterCell(owningSection, entryCell)
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
