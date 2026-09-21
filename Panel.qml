import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Shared.js" as Shared

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
  //
  // Quotes, charts, search results and the backoff gate live in Shared.js,
  // which every instance of this panel (one per monitor) shares. `revision`
  // is bumped whenever Shared changes so the bindings below re-evaluate.

  property int revision: 0
  property var _sharedListener: null

  property string activeId: defaultId
  readonly property bool viewingDefault: activeId === defaultId
  property string range: "1"

  readonly property var pinnedData: { root.revision; return Shared.quote(root.defaultId) }
  readonly property var activeData: { root.revision; return Shared.quote(root.activeId) }
  readonly property double activeUpdatedAt: { root.revision; return Shared.quoteAt(root.activeId) }
  readonly property var chartPoints: { root.revision; return Shared.chart(root.activeId, root.range) || [] }
  readonly property bool chartLoading: {
    root.revision
    return chartReq.running
      || Shared.isInFlight("chart:" + Shared.chartKey(root.activeId, root.range), Date.now())
  }
  readonly property var gate: { root.revision; return Shared.gate }

  property double nowMs: Date.now()

  property var searchResults: []
  property int suggestionIndex: 0

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

  Component.onCompleted: {
    root._sharedListener = function() { root.revision++ }
    Shared.subscribe(root._sharedListener)
    root.loadPinnedCache()
    // Deferred so every monitor's instance has subscribed before the first
    // check; the first one to run claims the request, the rest reuse it.
    Qt.callLater(root.backgroundCheck)
  }

  Component.onDestruction: {
    if (root._sharedListener) Shared.unsubscribe(root._sharedListener)
  }

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

  // User-initiated refresh (open, `r`, middle-click, IPC). Throttled: data
  // younger than the manual age is reused, and nothing goes out while the
  // backoff gate is closed, however often this is called.
  function refresh() {
    ensureQuote(defaultId, Shared.QUOTE_MANUAL_AGE_MS)
    if (!viewingDefault) ensureQuote(activeId, Shared.QUOTE_MANUAL_AGE_MS)
    ensureChart(true)
  }

  function backgroundCheck() {
    ensureQuote(defaultId, Shared.QUOTE_POLL_AGE_MS)
    if (!opened) return
    if (!viewingDefault) ensureQuote(activeId, Shared.QUOTE_POLL_AGE_MS)
    ensureChart(false)
  }

  function selectCoin(id) {
    if (!id) return
    activeId = id
    ensureQuote(id, Shared.QUOTE_MANUAL_AGE_MS)
    ensureChart(false)
  }

  function selectRange(value) {
    if (range === value) return
    range = value
    ensureChart(false)
  }

  function stepRange(delta) {
    var idx = 0
    for (var i = 0; i < ranges.length; i++) if (ranges[i].value === range) idx = i
    idx = Math.max(0, Math.min(ranges.length - 1, idx + delta))
    selectRange(ranges[idx].value)
  }

  // ---- Quotes ------------------------------------------------------------

  // Fetch a quote only if it is older than `maxAge`, the gate is open and no
  // instance already has it in flight. The pinned coin and the searched coin
  // use separate requests so a slow search never delays the pill.
  function ensureQuote(id, maxAge) {
    var now = Date.now()
    if (!Shared.needsQuote(id, maxAge, now)) return
    var req = id === defaultId ? pinnedReq : activeReq
    if (req.running) return  // completion re-checks the current coin
    if (!Shared.tryBegin(Shared.quoteKey(id), now)) return
    req.fetch(Model.marketsUrl(id), id)
    Shared.notify()
  }

  function onQuoteCompleted(status, body, id) {
    var now = Date.now()
    Shared.end(Shared.quoteKey(id))
    if (Shared.recordResult(status, now)) {
      var parsed = Model.parseMarkets(body)
      if (parsed && Shared.storeQuote(id, parsed, now) && id === defaultId) persistPinned(parsed, now)
    }
    Shared.notify()
    // The user may have picked another coin while this was in flight.
    if (id !== defaultId && id !== activeId && !viewingDefault)
      ensureQuote(activeId, Shared.QUOTE_MANUAL_AGE_MS)
  }

  Request {
    id: pinnedReq
    onCompleted: function(status, body, tag) { root.onQuoteCompleted(status, body, tag) }
  }

  Request {
    id: activeReq
    onCompleted: function(status, body, tag) { root.onQuoteCompleted(status, body, tag) }
  }

  // Last good pinned quote on disk, so the pill has a value right after
  // login or a shell restart, and a fresh one skips the startup request.
  FileView {
    id: pinnedCache
    path: Quickshell.env("HOME") + "/.cache/bch-crypto-panel.json"
    blockLoading: true
    printErrors: false
  }

  function loadPinnedCache() {
    var cached = Model.parsePinnedCache(pinnedCache.text())
    if (cached && Shared.storeQuote(defaultId, cached.data, cached.at)) Shared.notify()
  }

  function persistPinned(data, at) {
    pinnedCache.setText(JSON.stringify({ at: at, data: data }))
  }

  // ---- Charts ------------------------------------------------------------

  // `force` (user refresh) lowers the reuse window to CHART_MANUAL_AGE_MS;
  // otherwise the per-range TTL applies. One chart request per instance at a
  // time; completion re-checks whatever coin/range is current by then.
  function ensureChart(force) {
    var now = Date.now()
    var id = activeId
    var days = range
    if (!Shared.needsChart(id, days, force, now)) return
    if (chartReq.running) return
    var key = "chart:" + Shared.chartKey(id, days)
    if (!Shared.tryBegin(key, now)) return
    chartReq.fetch(Model.chartUrl(id, days), { id: id, days: days, key: key })
    Shared.notify()
  }

  Request {
    id: chartReq
    onCompleted: function(status, body, tag) {
      var now = Date.now()
      Shared.end(tag.key)
      if (Shared.recordResult(status, now)) {
        var points = Model.parseChart(body, 300)
        if (points.length > 1) Shared.storeChart(tag.id, tag.days, points, now)
      }
      Shared.notify()
      if (tag.id !== root.activeId || tag.days !== root.range) root.ensureChart(false)
    }
  }

  // ---- Search ------------------------------------------------------------

  // Debounced; one request at a time. Results are cached per query, so
  // retyping or backspacing to an earlier query costs nothing.
  property string searchPendingQuery: ""

  function clearSearch() {
    searchField.text = ""
    searchResults = []
    suggestionIndex = 0
    searchPendingQuery = ""
    searchDebounce.stop()
  }

  function requestSearch() {
    var query = searchField.text.trim()
    searchPendingQuery = ""
    if (query.length < 2) {
      searchResults = []
      return
    }
    var now = Date.now()
    var cached = Shared.cachedSearch(query, now)
    if (cached) {
      showSearchResults(cached)
      return
    }
    if (searchReq.running) {
      searchPendingQuery = query  // picked up when the current one finishes
      return
    }
    if (!Shared.canRequest(now)) return  // footer shows the retry countdown
    searchReq.fetch(Model.searchUrl(query), query)
  }

  function showSearchResults(results) {
    searchResults = results
    suggestionIndex = 0
  }

  function pickResult(result) {
    if (!result) return
    clearSearch()
    keyCatcher.forceActiveFocus()
    selectCoin(result.id)
  }

  Request {
    id: searchReq
    onCompleted: function(status, body, query) {
      var now = Date.now()
      if (Shared.recordResult(status, now)) Shared.storeSearch(query, Model.parseSearch(body, 6), now)
      Shared.notify()
      if (Shared.searchKey(query) === Shared.searchKey(searchField.text))
        root.showSearchResults(Shared.cachedSearch(query, now) || [])
      if (root.searchPendingQuery !== "") root.requestSearch()
    }
  }

  Timer {
    id: searchDebounce
    interval: 400
    onTriggered: root.requestSearch()
  }

  // ---- Timers ------------------------------------------------------------

  // Staleness check, not a fetch: a request only goes out when data is older
  // than QUOTE_POLL_AGE_MS and the gate is open, so across all instances the
  // pill costs about one request a minute, and a closed gate is retried
  // within one tick of reopening.
  Timer {
    interval: 15 * 1000
    running: true
    repeat: true
    onTriggered: root.backgroundCheck()
  }

  // Drives the "updated …" / "retrying in …" footer.
  Timer {
    interval: 1000
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

  readonly property bool gateClosed: gate.blockedUntil > nowMs

  function statusText() {
    if (gateClosed) {
      var wait = Math.ceil((gate.blockedUntil - nowMs) / 1000)
      return (gate.rateLimited ? "Rate limited" : "Offline") + " · retrying in " + wait + "s"
    }
    if (!activeUpdatedAt) return "CoinGecko"
    var s = Math.max(0, Math.round((nowMs - activeUpdatedAt) / 1000))
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
            text: root.statusText()
            color: root.gateClosed ? root.downColor : root.muted
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
