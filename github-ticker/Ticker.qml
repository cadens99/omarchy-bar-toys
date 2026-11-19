import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Sports-ticker style scroll of recent GitHub activity.
// Data comes from fetch.py (which uses the authenticated `gh` CLI) every
// `refreshMinutes`. Hover pauses the scroll; click a headline to open it.
BarWidget {
  id: root
  moduleName: "cxdog.github-ticker"

  readonly property int tickerWidth: Number(setting("width", 520))
  readonly property int refreshMinutes: Math.max(2, Number(setting("refreshMinutes", 5)))
  readonly property int speed: Math.max(5, Number(setting("speed", 30)))

  readonly property color fg: bar ? bar.barForeground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string scriptPath: decodeURIComponent(String(Qt.resolvedUrl("fetch.py")).replace(/^file:\/\//, ""))

  readonly property color fixedColor: "#a8cc95"

  property var items: []
  property string status: "Loading GitHub activity…"
  property bool paused: hover.hovered

  visible: !vertical
  implicitWidth: vertical ? 0 : tickerWidth
  implicitHeight: barSize

  // Only ever open plain github.com links.
  function safeUrl(u) {
    var s = String(u || "")
    return /^https:\/\/github\.com\/[A-Za-z0-9._\-\/#?=&]{1,400}$/.test(s) ? s : ""
  }

  function sanitize(list) {
    var out = []
    if (!Array.isArray(list)) return out
    for (var i = 0; i < list.length && out.length < 40; i++) {
      var it = list[i] || {}
      out.push({
        tag: String(it.tag || "").slice(0, 12),
        text: String(it.text || "").slice(0, 160),
        age: String(it.age || "").slice(0, 6),
        url: safeUrl(it.url)
      })
    }
    return out
  }

  Process {
    id: fetcher
    command: ["python3", "-I", root.scriptPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw.length > 200000) raw = ""
        try {
          var data = JSON.parse(raw)
          if (data && data.ok) {
            var list = root.sanitize(data.items)
            root.items = list
            root.status = list.length ? "" : "No recent GitHub activity"
          } else if (!root.items.length) {
            root.status = "GitHub: " + String((data && data.error) || "unavailable").slice(0, 120)
          }
        } catch (e) {
          if (!root.items.length) root.status = "GitHub: couldn't read activity"
        }
      }
    }
  }

  Timer {
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!fetcher.running) fetcher.running = true
  }

  // ---- Layout: [GITHUB] badge + scrolling window ----
  Rectangle {
    id: badge
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    height: Math.round(root.barSize * 0.62)
    width: badgeText.implicitWidth + 12
    radius: 3
    color: Commons.Color.accent

    Text {
      id: badgeText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: "GITHUB"
      color: Commons.Color.background
      font.family: root.fontFamily
      font.pixelSize: Style.font.body - 2
      font.bold: true
    }
  }

  Item {
    id: window
    anchors.left: badge.right
    anchors.leftMargin: 8
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    clip: true

    HoverHandler { id: hover }

    // Status line when there is nothing to scroll.
    Text {
      visible: root.items.length === 0
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.status
      color: Commons.Color.muted
      elide: Text.ElideRight
      width: parent.width
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    // Content is laid out twice back-to-back so the loop is seamless.
    Row {
      id: strip
      visible: root.items.length > 0
      anchors.verticalCenter: parent.verticalCenter
      x: window.width
      property real singleWidth: width / 2

      Repeater {
        model: root.items.length ? root.items.concat(root.items) : []
        delegate: Row {
          required property var modelData
          spacing: 6
          rightPadding: 22

          Text {
            textFormat: Text.PlainText
            text: modelData.tag
            // CI results stand out: red for failures (theme red), green when fixed.
            color: modelData.tag === "FAIL" ? Commons.Color.urgent
                 : modelData.tag === "FIXED" ? root.fixedColor
                 : Commons.Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            id: headline
            textFormat: Text.PlainText
            text: modelData.text
            color: linkArea.containsMouse && modelData.url ? Commons.Color.accent : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.underline: linkArea.containsMouse && modelData.url !== ""
            MouseArea {
              id: linkArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: modelData.url ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: if (modelData.url) Qt.openUrlExternally(modelData.url)
            }
          }
          Text {
            textFormat: Text.PlainText
            text: modelData.age ? modelData.age : ""
            color: Commons.Color.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body - 1
          }
          Text {
            textFormat: Text.PlainText
            text: "•"
            color: Commons.Color.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }
      }
    }

    // Constant-speed scroll. Steps ~30 times a second; pauses on hover.
    Timer {
      interval: 33
      repeat: true
      running: root.items.length > 0 && !root.paused && root.visible
      onTriggered: {
        var step = root.speed * interval / 1000
        var nx = strip.x - step
        if (strip.singleWidth > 0 && nx <= -strip.singleWidth) nx += strip.singleWidth
        strip.x = nx
      }
    }
  }
}
