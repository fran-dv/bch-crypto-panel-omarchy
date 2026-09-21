import QtQuick
import qs.Commons
import qs.Ui

// Bar pill: "BCH $267.79 ▲8.5%". Left click toggles the chart popup,
// middle click refreshes. Data and fetching live in Panel.qml.
BarWidget {
  id: root
  moduleName: "bch-crypto-panel"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // needs open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  readonly property var panel: panelLoader.item
  readonly property string coinGlyph: "\uf15a"  // nf-fa-btc
  readonly property bool hasPrice: panel ? panel.label !== "" : false
  readonly property string priceText: hasPrice ? panel.label : "—"
  readonly property string arrowText: panel && panel.pillUp ? "▲" : "▼"
  readonly property color changeColor: panel ? (panel.pillUp ? panel.upColor : panel.downColor) : Color.foreground

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Compact pill: coin glyph, rounded price, 24h direction arrow (green/red).
  // The button's own label stays hidden; the pill is sized to the Row below.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.priceText
    labelVisible: false
    dimmed: !root.hasPrice
    fixedWidth: pill.implicitWidth + button.scaledHorizontalMargin * 2
    tooltipText: root.panel ? root.panel.pillTooltip : ""

    Row {
      id: pill
      anchors.centerIn: parent
      spacing: Style.space(4)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.coinGlyph
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Math.round(button.fontSize * 1.25)
        font.bold: true
        renderType: Text.NativeRendering
      }
      Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.priceText
          color: button.foreground
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
          font.weight: Font.DemiBold
          renderType: Text.NativeRendering
        }
        Text {
          visible: root.hasPrice
          anchors.verticalCenter: parent.verticalCenter
          text: root.arrowText
          color: root.changeColor
          font.family: button.fontFamily
          font.pixelSize: Math.round(button.fontSize * 0.75)
          renderType: Text.NativeRendering
        }
      }
    }

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.MiddleButton) root.refresh()
      else if (b === Qt.LeftButton) root.togglePanel()
    }
  }
}
