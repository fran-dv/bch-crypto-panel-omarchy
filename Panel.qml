import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Crypto price popup. Owns every CoinGecko fetch: the pinned coin that feeds
// the bar pill, a temporarily searched coin, its chart, and coin search.
Panel {
  id: root
  moduleName: "bch-crypto-panel"
  ipcTarget: "bch-crypto-panel"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string defaultId: "bitcoin-cash"
  readonly property var ranges: [
    { value: "1", label: "1D" },
    { value: "7", label: "7D" },
    { value: "30", label: "30D" },
    { value: "365", label: "1Y" }
  ]

  // ---- State -------------------------------------------------------------

  property var pinnedData: null        // default coin, feeds the pill
  property var searchedData: null      // coin picked from search, panel only
  property string activeId: defaultId
  readonly property bool viewingDefault: activeId === defaultId
  readonly property var activeData: viewingDefault ? pinnedData : (searchedData && searchedData.id === activeId ? searchedData : null)

  property string range: "1"
  property var chartPoints: []
  property var chartCache: ({})        // "id:days" -> { at, points }
  property bool chartLoading: false

  property double lastUpdated: 0
  property int failures: 0
  property bool rateLimited: false
  property double nowMs: Date.now()

  property var searchResults: []
  property int suggestionIndex: 0
  property string searchPendingQuery: ""
  property string searchActiveQuery: ""

  // Theme market colors (colors.toml green/red), falling back to palette roles.
  property var themeColors: ({ green: "", red: "" })
  readonly property color upColor: themeColors.green !== "" ? themeColors.green : Color.accent
  readonly property color downColor: themeColors.red !== "" ? themeColors.red : Color.urgent
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color muted: Qt.darker(fg, 1.5)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // ---- Pill data (read by BarWidget) -------------------------------------

  readonly property string label: pinnedData ? Model.formatPillPrice(pinnedData.price) : ""
  readonly property bool pillUp: pinnedData ? pinnedData.change24h >= 0 : true
  readonly property string pillTooltip: pinnedData
    ? pinnedData.name + "  " + Model.formatPrice(pinnedData.price) + "  " + Model.formatPct(pinnedData.change24h) + " 24h"
    : ""

  // ---- Lifecycle ---------------------------------------------------------

  function open() {
    themeFile.reload()
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() { open() }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // A searched coin is a temporary look: every close returns to the default.
  onOpenedChanged: {
    if (opened) return
    clearSearch()
    if (!viewingDefault) selectCoin(defaultId)
    keyCatcher.forceActiveFocus()
  }

  function refresh() {
    fetchPinned()
    if (!viewingDefault) fetchActive()
    requestChart(true)
  }

  function selectCoin(id) {
    if (!id) return
    activeId = id
    if (!viewingDefault) {
      if (!searchedData || searchedData.id !== id) searchedData = null
      fetchActive()
    }
    requestChart(false)
  }

  function selectRange(value) {
    if (range === value) return
    range = value
    requestChart(false)
  }

  function stepRange(delta) {
    var idx = 0
    for (var i = 0; i < ranges.length; i++) if (ranges[i].value === range) idx = i
    idx = Math.max(0, Math.min(ranges.length - 1, idx + delta))
    selectRange(ranges[idx].value)
  }

  // ---- Fetching ----------------------------------------------------------

  function curl(url) {
    return ["curl", "-sS", "--max-time", "8", "-w", "\n%{http_code}", url]
  }

  function noteResult(status) {
    if (status === 200) {
      failures = 0
      rateLimited = false
      lastUpdated = Date.now()
      return true
    }
    failures = Math.min(failures + 1, 3)
    rateLimited = status === 429
    return false
  }

  function fetchPinned() {
    if (pinnedProc.running) return
    pinnedProc.command = curl(Model.marketsUrl(defaultId))
    pinnedProc.running = true
  }

  Process {
    id: pinnedProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = Model.splitResponse(text)
        if (!root.noteResult(res.status)) return
        var parsed = Model.parseMarkets(res.body)
        if (!parsed) return
        root.pinnedData = parsed
        pinnedCache.setText(JSON.stringify(parsed))
      }
    }
  }

  // Last good pinned quote, so a restart during a rate-limit window still
  // shows a (stale) price instead of an empty pill.
  FileView {
    id: pinnedCache
    path: Quickshell.env("HOME") + "/.cache/bch-crypto-panel.json"
    printErrors: false
    onLoaded: {
      if (root.pinnedData) return
      try {
        var cached = JSON.parse(text())
        if (cached && isFinite(Number(cached.price))) root.pinnedData = cached
      } catch (e) {}
    }
  }

  property string activeFetchId: ""

  function fetchActive() {
    if (viewingDefault) return
    if (activeProc.running) return
    activeFetchId = activeId
    activeProc.command = curl(Model.marketsUrl(activeId))
    activeProc.running = true
  }

  Process {
    id: activeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = Model.splitResponse(text)
        var fetched = root.activeFetchId
        if (root.noteResult(res.status)) {
          var parsed = Model.parseMarkets(res.body)
          if (parsed && fetched === root.activeId) root.searchedData = parsed
        }
        // The user may have picked another coin mid-flight.
        if (fetched !== root.activeId && !root.viewingDefault) Qt.callLater(root.fetchActive)
      }
    }
  }

  property string chartFetchKey: ""
  readonly property string chartKey: activeId + ":" + range

  function chartTtl(days) {
    return days === "1" ? 60 * 1000 : 5 * 60 * 1000
  }

  // Serve the cached series if fresh; otherwise fetch. Only one chart
  // request runs at a time; a stale finish re-requests the current key.
  function requestChart(force) {
    var key = chartKey
    var cached = chartCache[key]
    if (cached) chartPoints = cached.points
    else chartPoints = []
    var fresh = cached && Date.now() - cached.at < chartTtl(range)
    if (fresh && !force) { chartLoading = false; return }
    if (fresh && force && Date.now() - cached.at < 30 * 1000) { chartLoading = false; return }
    chartLoading = true
    if (chartProc.running) return
    chartFetchKey = key
    chartProc.command = curl(Model.chartUrl(activeId, range))
    chartProc.running = true
  }

  Process {
    id: chartProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = Model.splitResponse(text)
        var key = root.chartFetchKey
        if (root.noteResult(res.status)) {
          var pts = Model.parseChart(res.body, 300)
          if (pts.length > 1) {
            var next = ({})
            for (var k in root.chartCache) next[k] = root.chartCache[k]
            next[key] = { at: Date.now(), points: pts }
            root.chartCache = next
            if (key === root.chartKey) root.chartPoints = pts
          }
        }
        if (key !== root.chartKey) Qt.callLater(function() { root.requestChart(false) })
        else root.chartLoading = false
      }
    }
  }

  // ---- Search ------------------------------------------------------------

  function clearSearch() {
    searchField.text = ""
    searchResults = []
    suggestionIndex = 0
    searchDebounce.stop()
  }

  function requestSearch() {
    var query = searchField.text.trim()
    if (query.length < 2) {
      searchResults = []
      return
    }
    searchPendingQuery = query
    if (!searchProc.running) startSearch()
  }

  function startSearch() {
    searchActiveQuery = searchPendingQuery
    searchProc.command = curl(Model.searchUrl(searchActiveQuery))
    searchProc.running = true
  }

  function pickResult(result) {
    if (!result) return
    clearSearch()
    keyCatcher.forceActiveFocus()
    selectCoin(result.id)
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = Model.splitResponse(text)
        if (res.status === 429) root.rateLimited = true
        root.searchResults = res.status === 200 && searchField.text.trim().length >= 2
          ? Model.parseSearch(res.body, 6) : []
        root.suggestionIndex = 0
        if (root.searchPendingQuery !== root.searchActiveQuery) Qt.callLater(root.startSearch)
      }
    }
  }

  Timer {
    id: searchDebounce
    interval: 400
    onTriggered: root.requestSearch()
  }

  // ---- Timers ------------------------------------------------------------

  // Pill poll. Backs off 60s -> 120s -> 240s while requests fail.
  Timer {
    interval: 60 * 1000 * Math.pow(2, Math.min(root.failures, 2))
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.fetchPinned()
  }

  // While open, keep the searched coin and chart fresh too.
  Timer {
    interval: 60 * 1000 * Math.pow(2, Math.min(root.failures, 2))
    running: root.opened
    repeat: true
    onTriggered: {
      root.fetchActive()
      root.requestChart(false)
    }
  }

  // Drives the "updated Xs ago" footer.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  FileView {
    id: themeFile
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.themeColors = Model.parseThemeColors(text())
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  // ---- UI ----------------------------------------------------------------

  function updatedText() {
    if (rateLimited) return "Rate limited · retrying soon"
    if (failures > 0) return "Offline · showing last data"
    if (!lastUpdated) return "CoinGecko"
    var s = Math.max(0, Math.round((nowMs - lastUpdated) / 1000))
    var ago = s < 10 ? "just now" : (s < 60 ? s + "s ago" : Math.round(s / 60) + "m ago")
    return "CoinGecko · updated " + ago
  }

  readonly property real chartChange: Model.rangeChange(chartPoints)
  readonly property bool chartUp: isNaN(chartChange) ? (activeData ? activeData.change24h >= 0 : true) : chartChange >= 0

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus
      onCloseRequested: {
        if (!root.viewingDefault) root.selectCoin(root.defaultId)
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { if (dx !== 0) root.stepRange(dx) }
      onTextKey: function(t) {
        if (t === "/" || t === "s") searchField.forceActiveFocus()
        else if (t === "r") root.refresh()
        else if (t >= "1" && t <= "4") root.selectRange(root.ranges[Number(t) - 1].value)
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        // ---- Search
        TextField {
          id: searchField
          width: parent.width
          placeholderText: "Search any coin…   ( / )"
          foreground: root.fg
          font.family: root.fontFamily

          onTextChanged: searchDebounce.restart()

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              if (text !== "") root.clearSearch()
              else keyCatcher.forceActiveFocus()
              event.accepted = true
            } else if (event.key === Qt.Key_Down) {
              if (root.suggestionIndex < root.searchResults.length - 1) root.suggestionIndex++
              event.accepted = true
            } else if (event.key === Qt.Key_Up) {
              if (root.suggestionIndex > 0) root.suggestionIndex--
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.pickResult(root.searchResults[root.suggestionIndex])
              event.accepted = true
            }
          }
        }

        Column {
          visible: root.searchResults.length > 0 && searchField.text.trim().length >= 2
          width: parent.width
          spacing: 0

          Repeater {
            model: root.searchResults

            Rectangle {
              required property var modelData
              required property int index
              readonly property bool hot: index === root.suggestionIndex
              width: parent.width
              height: resultRow.implicitHeight + Style.space(12)
              radius: Style.cornerRadius
              color: hot ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

              Row {
                id: resultRow
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  text: modelData.name
                  color: hot ? Style.hoverStateColor(root.fg, Color.accent) : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  text: modelData.symbol
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
              Text {
                visible: !isNaN(modelData.rank)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: "#" + modelData.rank
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: root.suggestionIndex = index
                onClicked: root.pickResult(modelData)
              }
            }
          }
        }

        // ---- Hero
        Item {
          width: parent.width
          height: heroCol.implicitHeight

          Column {
            id: heroCol
            width: parent.width
            spacing: Style.space(4)

            Row {
              spacing: Style.space(8)

              Text {
                id: coinName
                text: root.activeData ? root.activeData.name : (root.viewingDefault ? "Bitcoin Cash" : "Loading…")
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                visible: !!root.activeData
                text: root.activeData ? root.activeData.symbol + (isNaN(root.activeData.rank) ? "" : "  ·  #" + root.activeData.rank) : ""
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.baseline: coinName.baseline
              }
            }

            Row {
              spacing: Style.space(10)

              Text {
                id: bigPrice
                text: root.activeData ? Model.formatPrice(root.activeData.price) : "—"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: 34
                font.bold: true
              }
              Text {
                visible: !!root.activeData
                anchors.baseline: bigPrice.baseline
                text: root.activeData ? Model.formatPct(root.activeData.change24h) : ""
                color: root.activeData && root.activeData.change24h >= 0 ? root.upColor : root.downColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
              Text {
                visible: !!root.activeData
                anchors.baseline: bigPrice.baseline
                text: "24h"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // Back to the pinned coin while viewing a search result.
          Rectangle {
            visible: !root.viewingDefault
            anchors.right: parent.right
            anchors.top: parent.top
            width: backLabel.implicitWidth + Style.space(16)
            height: backLabel.implicitHeight + Style.space(8)
            radius: Style.cornerRadius
            color: backArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
            border.width: 1
            border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.2)

            Text {
              id: backLabel
              anchors.centerIn: parent
              text: "← " + (root.pinnedData ? root.pinnedData.symbol : "BCH")
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: backArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.selectCoin(root.defaultId)
            }
          }
        }

        // ---- Range selector + range change
        Item {
          width: parent.width
          height: rangeGroup.implicitHeight

          ButtonGroup {
            id: rangeGroup
            options: root.ranges
            value: root.range
            focusable: false
            foreground: root.fg
            background: Color.popups.background
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            spacing: Style.space(6)
            onChanged: function(v) { root.selectRange(v) }
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: !isNaN(root.chartChange)
            text: Model.formatPct(root.chartChange) + "  "
              + root.ranges.filter(function(r) { return r.value === root.range })[0].label
            color: root.chartUp ? root.upColor : root.downColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---- Chart
        PriceChart {
          width: parent.width
          height: Style.space(170)
          points: root.chartPoints
          range: root.range
          loading: root.chartLoading
          lineColor: root.chartUp ? root.upColor : root.downColor
          textColor: root.fg
          mutedColor: root.muted
          fontFamily: root.fontFamily
        }

        PanelSeparator { width: parent.width }

        // ---- Stats
        Grid {
          width: parent.width
          columns: 2
          rowSpacing: Style.space(10)
          columnSpacing: 0

          Repeater {
            model: root.activeData ? [
              { label: "24h High", value: Model.formatPrice(root.activeData.high24h) },
              { label: "24h Low", value: Model.formatPrice(root.activeData.low24h) },
              { label: "Market cap", value: Model.formatCompact(root.activeData.marketCap) },
              { label: "24h Volume", value: Model.formatCompact(root.activeData.volume) }
            ] : []

            Column {
              required property var modelData
              width: content.width / 2
              spacing: Style.space(2)

              Text {
                text: modelData.label
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                text: modelData.value
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }
          }
        }

        // ---- Footer
        Item {
          width: parent.width
          height: footer.implicitHeight

          Text {
            id: footer
            text: root.updatedText()
            color: root.rateLimited || root.failures > 0 ? root.downColor : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            anchors.right: parent.right
            text: "/ search · 1-4 range · r refresh"
            color: Qt.rgba(root.muted.r, root.muted.g, root.muted.b, 0.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
