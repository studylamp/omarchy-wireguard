import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.studylamp.wireguard"
  ipcTarget: "io.github.studylamp.wireguard"
  manageIpc: false

  property string focusSection: "header"
  property int tunnelIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property bool hasTunnels: wireguard.tunnels.length > 0
  readonly property bool primaryActive: wireguard.isActive(wireguard.primary)
  // Accent while up, dimmed while down — the bar has room for one glyph, so
  // colour carries the whole state.
  readonly property color barIconColor: {
    if (!wireguard.loaded || !hasTunnels) return Qt.darker(barForeground, 1.9)
    if (wireguard.anyActive) return Color.accent
    return Qt.darker(barForeground, 1.55)
  }
  readonly property string toggleHint: {
    if (!wireguard.primary) return "No WireGuard tunnel configured"
    return (primaryActive ? "Disconnect " : "Connect ") + wireguard.primary.name
  }

  // The bar sizes each widget from its root item's implicit size; without
  // this the button draws at zero width and the widget is invisible.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function tunnelAt(index) {
    if (wireguard.tunnels.length === 0) return null
    return wireguard.tunnels[Math.max(0, Math.min(index, wireguard.tunnels.length - 1))]
  }

  function selectedTunnel() {
    return focusSection === "tunnels" ? tunnelAt(tunnelIndex) : wireguard.primary
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
  }

  function setTunnelCursor(index) {
    cursorActive = true
    focusSection = "tunnels"
    tunnelIndex = index
  }

  // One flat vertical run: the hero switch, then a row per tunnel.
  function moveCursor(dx, dy) {
    var step = dy !== 0 ? dy : dx
    if (step === 0) return
    var count = wireguard.tunnels.length
    var position = focusSection === "header" ? 0 : tunnelIndex + 1
    var next = position + step
    if (next < 0) next = 0
    if (next > count) next = count
    if (next === 0) setHeaderCursor()
    else setTunnelCursor(next - 1)
  }

  function activateCursor() {
    if (focusSection === "header") wireguard.toggleTunnel("")
    else {
      var tunnel = tunnelAt(tunnelIndex)
      if (tunnel) wireguard.toggleTunnel(tunnel.uuid)
    }
  }

  function ensureCursor() {
    var count = wireguard.tunnels.length
    if (count === 0) { focusSection = "header"; tunnelIndex = 0; return }
    if (tunnelIndex > count - 1) tunnelIndex = count - 1
  }

  Service {
    id: wireguard
    settings: root.settings
  }

  Connections {
    target: wireguard
    function onTunnelsChanged() { root.ensureCursor() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { wireguard.refresh(); return "ok" }
    // `toggleTunnel` with no argument acts on the primary tunnel; this is what
    // the Hyprland keybinding calls.
    function toggleTunnel(name: string): string { wireguard.toggleTunnel(name || ""); return "ok" }
    function up(name: string): string { wireguard.up(name || (wireguard.primary ? wireguard.primary.uuid : "")); return "ok" }
    function down(name: string): string { wireguard.down(name || (wireguard.primary ? wireguard.primary.uuid : "")); return "ok" }
    function status(): string { return wireguard.statusText }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖂"
    foreground: root.barIconColor
    useActiveColor: false
    tooltipText: wireguard.statusText
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) wireguard.toggleTunnel("")
      else if (buttonCode === Qt.MiddleButton) wireguard.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        if (t === "t" || t === "T") wireguard.toggleTunnel("")
        else if (t === "r" || t === "R") wireguard.refresh()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // The hero's trailingControl resolves `root` to PanelHero, not this
            // Panel, so panel state is reached through `header`.
            readonly property bool ringVisible: root.cursorActive && root.focusSection === "header" && root.hasTunnels
            function focusHero() { root.setHeaderCursor() }

            PanelHero {
              id: hero
              width: parent.width
              title: "WireGuard"
              meta: wireguard.statusText
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: wireguard.anyActive ? 1.0 : 0.5
              iconComponent: Component {
                Text {
                  text: "󰖂"
                  color: wireguard.anyActive ? Color.accent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: root.hasTunnels
                  checked: root.primaryActive
                  busy: wireguard.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function (on) { if (on) header.focusHero() }
                  onToggled: wireguard.toggleTunnel("")

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: root.toggleHint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: wireguard.lastError !== ""
            width: parent.width
            text: wireguard.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          CursorSurface {
            visible: wireguard.loaded && !root.hasTunnels
            width: parent.width
            implicitHeight: emptyText.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground

            Text {
              id: emptyText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              text: "No WireGuard tunnels yet.\nImport one with:\nnmcli connection import type wireguard file <tunnel>.conf"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator {
            visible: root.hasTunnels
            foreground: root.foreground
          }

          Column {
            visible: root.hasTunnels
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "TUNNELS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: wireguard.tunnels
              TunnelRow {
                required property var modelData
                required property int index
                width: parent.width
                tunnel: modelData
                rowIndex: index
              }
            }
          }
        }
      }
    }
  }

  component TunnelRow: CursorSurface {
    id: tunnelRow
    property var tunnel: null
    property int rowIndex: 0
    readonly property bool tunnelActive: wireguard.isActive(tunnel)
    readonly property string detailText: Model.tunnelDetail(tunnel)
    readonly property string transferText: Model.transferDetail(tunnel)

    hasCursor: root.cursorActive && root.focusSection === "tunnels" && root.tunnelIndex === rowIndex
    current: tunnelActive
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill

    implicitHeight: rowInner.implicitHeight + Style.spacing.rowPaddingX

    Item {
      id: rowInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(labels.implicitHeight, rowSwitch.implicitHeight)

      Column {
        id: labels
        anchors.left: parent.left
        anchors.right: rowSwitch.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: tunnelRow.tunnel ? tunnelRow.tunnel.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: tunnelRow.tunnelActive
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: tunnelRow.detailText !== ""
          text: tunnelRow.detailText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: tunnelRow.transferText !== ""
          text: tunnelRow.transferText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }

      ToggleSwitch {
        id: rowSwitch
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        checked: tunnelRow.tunnelActive
        busy: wireguard.isPending(tunnelRow.tunnel)
        hasCursor: tunnelRow.hasCursor
        foreground: root.foreground
        onHovered: function (on) { if (on) root.setTunnelCursor(tunnelRow.rowIndex) }
        onToggled: if (tunnelRow.tunnel) wireguard.toggleTunnel(tunnelRow.tunnel.uuid)
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      // The switch handles its own clicks; keep the row's own hit area clear of
      // it so one click never toggles twice.
      anchors.rightMargin: rowSwitch.width + Style.space(20)
      onEntered: root.setTunnelCursor(tunnelRow.rowIndex)
      onClicked: if (tunnelRow.tunnel) wireguard.toggleTunnel(tunnelRow.tunnel.uuid)
    }
  }
}
