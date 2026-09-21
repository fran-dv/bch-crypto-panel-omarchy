import QtQuick
import qs.Commons
import "Model.js" as Model

// Area chart for a [{ t, p }] price series. The line/fill is painted on a
// Canvas; the hover crosshair lives in plain items on top so moving the
// pointer never forces a repaint.
Item {
  id: root

  property var points: []
  property string range: "1"
  property color lineColor: Color.accent
  property color textColor: Color.foreground
  property color mutedColor: Color.muted
  property string fontFamily: Style.font.family
  property bool loading: false

  readonly property real padTop: Style.space(18)
  readonly property real padBottom: Style.space(18)
  readonly property bool hasData: points && points.length > 1

  readonly property var bounds: {
    var pts = root.points
    if (!pts || pts.length < 2) return { lo: 0, hi: 0 }
    var lo = Infinity, hi = -Infinity
    for (var i = 0; i < pts.length; i++) {
      if (pts[i].p < lo) lo = pts[i].p
      if (pts[i].p > hi) hi = pts[i].p
    }
    return { lo: lo, hi: hi }
  }
  readonly property real minP: bounds.lo
  readonly property real maxP: bounds.hi
  property int hoverIndex: -1

  function xAt(i) {
    return points.length < 2 ? 0 : i / (points.length - 1) * width
  }

  function yAt(p) {
    var span = maxP - minP
    var h = height - padTop - padBottom
    if (span <= 0) return padTop + h / 2
    return padTop + (1 - (p - minP) / span) * h
  }

  function formatTime(t) {
    var d = new Date(t)
    if (range === "1") return Qt.formatDateTime(d, "HH:mm")
    if (range === "365") return Qt.formatDateTime(d, "d MMM yyyy")
    return Qt.formatDateTime(d, "d MMM, HH:mm")
  }

  function withAlpha(c, a) {
    return Qt.rgba(c.r, c.g, c.b, a)
  }

  onPointsChanged: { hoverIndex = -1; canvas.requestPaint() }
  onBoundsChanged: canvas.requestPaint()
  onLineColorChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    opacity: root.loading ? 0.35 : 1
    renderStrategy: Canvas.Cooperative

    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (!root.hasData) return

      var pts = root.points
      var n = pts.length

      function trace() {
        ctx.moveTo(root.xAt(0), root.yAt(pts[0].p))
        // Midpoint quadratic smoothing: passes near every sample without
        // the overshoot a cardinal spline gives on sharp moves.
        for (var i = 1; i < n - 1; i++) {
          var x = root.xAt(i), y = root.yAt(pts[i].p)
          var nx = root.xAt(i + 1), ny = root.yAt(pts[i + 1].p)
          ctx.quadraticCurveTo(x, y, (x + nx) / 2, (y + ny) / 2)
        }
        ctx.lineTo(root.xAt(n - 1), root.yAt(pts[n - 1].p))
      }

      // Area fill
      var grad = ctx.createLinearGradient(0, root.padTop, 0, height)
      grad.addColorStop(0, root.withAlpha(root.lineColor, 0.32))
      grad.addColorStop(1, root.withAlpha(root.lineColor, 0.0))
      ctx.beginPath()
      trace()
      ctx.lineTo(root.xAt(n - 1), height)
      ctx.lineTo(0, height)
      ctx.closePath()
      ctx.fillStyle = grad
      ctx.fill()

      // Dashed reference line at the opening price of the range.
      ctx.beginPath()
      ctx.setLineDash([3, 4])
      ctx.lineWidth = 1
      ctx.strokeStyle = root.withAlpha(root.mutedColor, 0.6)
      var y0 = Math.round(root.yAt(pts[0].p)) + 0.5
      ctx.moveTo(0, y0)
      ctx.lineTo(width, y0)
      ctx.stroke()
      ctx.setLineDash([])

      // Line
      ctx.beginPath()
      trace()
      ctx.lineWidth = 2
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.strokeStyle = root.lineColor
      ctx.stroke()
    }
  }

  // High / low labels
  Text {
    visible: root.hasData
    anchors.top: parent.top
    anchors.right: parent.right
    text: "H " + Model.formatPrice(root.maxP)
    color: root.mutedColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
  Text {
    visible: root.hasData
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    text: "L " + Model.formatPrice(root.minP)
    color: root.mutedColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    visible: !root.hasData
    anchors.centerIn: parent
    text: root.loading ? "Loading chart…" : "No chart data"
    color: root.mutedColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.italic: true
  }

  // Loading bar sweeping across the top while a fetch is in flight.
  Rectangle {
    id: sweep
    visible: root.loading
    y: 0
    height: Math.max(1, Style.space(2))
    width: parent.width * 0.25
    radius: height / 2
    color: root.lineColor
    opacity: 0.8
    NumberAnimation on x {
      running: sweep.visible
      loops: Animation.Infinite
      from: -sweep.width
      to: root.width
      duration: 1100
      easing.type: Easing.InOutQuad
    }
  }

  // ---- Hover crosshair
  Item {
    id: hoverLayer
    anchors.fill: parent
    visible: root.hasData && root.hoverIndex >= 0 && root.hoverIndex < root.points.length

    readonly property var pt: visible ? root.points[root.hoverIndex] : null
    readonly property real px: visible ? root.xAt(root.hoverIndex) : 0
    readonly property real py: pt ? root.yAt(pt.p) : 0

    Rectangle {
      x: Math.round(hoverLayer.px)
      y: 0
      width: 1
      height: parent.height
      color: root.withAlpha(root.textColor, 0.25)
    }

    Rectangle {
      width: Style.space(9)
      height: width
      radius: width / 2
      x: hoverLayer.px - width / 2
      y: hoverLayer.py - height / 2
      color: root.lineColor
      border.width: 2
      border.color: Color.popups.background
    }

    Rectangle {
      id: tip
      readonly property real gap: Style.space(10)
      width: tipCol.implicitWidth + Style.space(16)
      height: tipCol.implicitHeight + Style.space(10)
      radius: Style.cornerRadius
      color: Color.popups.background
      border.width: 1
      border.color: root.withAlpha(root.textColor, 0.18)
      x: hoverLayer.px + gap + width > root.width ? hoverLayer.px - gap - width : hoverLayer.px + gap
      y: Math.max(0, Math.min(root.height - height, hoverLayer.py - height - gap))

      Column {
        id: tipCol
        anchors.centerIn: parent
        spacing: Style.space(2)
        Text {
          text: hoverLayer.pt ? Model.formatPrice(hoverLayer.pt.p) : ""
          color: root.textColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Text {
          text: hoverLayer.pt ? root.formatTime(hoverLayer.pt.t) : ""
          color: root.mutedColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
    onPositionChanged: function(mouse) {
      if (!root.hasData || root.width <= 0) return
      var i = Math.round(mouse.x / root.width * (root.points.length - 1))
      root.hoverIndex = Math.max(0, Math.min(root.points.length - 1, i))
    }
    onExited: root.hoverIndex = -1
  }
}
