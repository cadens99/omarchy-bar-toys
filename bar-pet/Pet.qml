import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A small pixel T-rex that lives in the bar.
// States: "walk" (wanders back and forth), "sit" (short rest), "sleep" (nap with z's),
// "hop" (on click). With animations turned off it just sits quietly.
BarWidget {
  id: root
  moduleName: "cxdog.bar-pet"

  readonly property int trackWidth: Number(setting("trackWidth", 260))
  // Walks even when Hyprland animations are off (the pet is the point), unless
  // "followReduceMotion": true is set on this widget in shell.json.
  readonly property bool followReduceMotion: setting("followReduceMotion", false) === true
  readonly property bool still: vertical || (followReduceMotion && Style.reduceMotion)

  implicitWidth: vertical ? barSize : trackWidth
  implicitHeight: vertical ? barSize : barSize

  // ---- Sprite data (facing right). 16 x 10 pixels. ----
  //  o = fur (accent)   d = shade   w = cream   k = eyes/nose/paws
  // A little T-rex: big head, tiny arm, back spikes, swinging tail.
  readonly property int eyeRow: 1
  readonly property var bodyTop: [
    "..........ooooo.",
    ".........ookoooo",
    ".........ooooooo",
    "........oooowww.",
    "o....d.d.oooo...",
    "oo...oooooooo.o.",
    "dooooooooowwo...",
    ".ddoooooowwwo..."
  ]
  readonly property var bodyTopWag: [
    "..........ooooo.",
    ".........ookoooo",
    ".........ooooooo",
    "........oooowww.",
    ".....d.d.oooo...",
    "o....oooooooo.o.",
    "oooooooooowwo...",
    ".ddoooooowwwo..."
  ]
  readonly property var legsA: [
    ".....oo...oo....",
    ".....dd...dd...."
  ]
  readonly property var legsB: [
    "......oo.oo.....",
    "......dd.dd....."
  ]
  readonly property var legsSit: [
    "....ooo...ooo...",
    "....ddd...ddd..."
  ]

  property string mode: "walk"
  property int frame: 0          // toggles the walk cycle
  property bool facingRight: true
  property real petX: 0
  property real hopOffset: 0

  readonly property int pixel: Math.max(1, Math.floor((barSize - 6) / 10))
  readonly property int spriteW: 16 * pixel
  readonly property int spriteH: 10 * pixel
  readonly property real maxX: Math.max(0, width - spriteW)

  function rows() {
    var top = (mode === "walk" && frame % 2 === 1) ? bodyTopWag : bodyTop
    var legs = mode === "walk" ? (frame % 2 === 0 ? legsA : legsB)
             : mode === "hop" ? legsB : legsSit
    var out = top.slice()
    if (mode === "sleep") out[eyeRow] = out[eyeRow].replace("k", "d")   // closed eye
    return out.concat(legs)
  }

  function rand(min, max) { return min + Math.random() * (max - min) }

  function setMode(next) {
    mode = next
    frame = 0
    if (next === "walk") {
      if (Math.random() < 0.35) facingRight = !facingRight
      stateTimer.interval = rand(6000, 16000)
    } else if (next === "sit") {
      stateTimer.interval = rand(2500, 6000)
    } else if (next === "sleep") {
      stateTimer.interval = rand(10000, 22000)
    }
    stateTimer.restart()
    sprite.requestPaint()
  }

  // Decide what to do next when the current activity runs out.
  Timer {
    id: stateTimer
    running: !root.still
    repeat: false
    interval: 8000
    onTriggered: {
      if (root.mode === "walk") root.setMode(Math.random() < 0.25 ? "sleep" : "sit")
      else root.setMode("walk")
    }
  }

  // Movement + walk cycle. Cheap: moves one item a pixel at a time.
  Timer {
    id: stepTimer
    interval: 45
    repeat: true
    running: !root.still && root.mode === "walk" && root.visible
    property int ticks: 0
    onTriggered: {
      var nx = root.petX + (root.facingRight ? 1 : -1)
      if (nx >= root.maxX) { nx = root.maxX; root.facingRight = false }
      else if (nx <= 0) { nx = 0; root.facingRight = true }
      root.petX = nx
      ticks++
      if (ticks % 5 === 0) { root.frame++; sprite.requestPaint() }
    }
  }

  // Keep the fox inside the track if the widget resizes.
  onMaxXChanged: if (petX > maxX) petX = maxX
  onStillChanged: { if (still) { mode = "sit"; sprite.requestPaint() } else setMode("walk") }
  Component.onCompleted: {
    petX = rand(0, Math.max(0, trackWidth - 16 * pixel))
    if (still) { mode = "sit"; sprite.requestPaint() } else setMode("walk")
  }

  Item {
    id: pet
    x: root.vertical ? (root.width - root.spriteW) / 2 : Math.round(root.petX)
    y: Math.round((root.height - root.spriteH) / 2 - root.hopOffset)
    width: root.spriteW
    height: root.spriteH

    Canvas {
      id: sprite
      anchors.fill: parent
      transform: Scale {
        origin.x: sprite.width / 2
        xScale: root.facingRight ? 1 : -1
      }

      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        var fur = Commons.Color.accent
        var palette = {
          "o": fur,
          "d": Qt.darker(fur, 1.35),
          "w": Qt.lighter(Commons.Color.foreground, 1.05),
          "k": "#141414"
        }
        var data = root.rows()
        var p = root.pixel
        for (var r = 0; r < data.length; r++) {
          var line = data[r]
          for (var c = 0; c < line.length; c++) {
            var col = palette[line[c]]
            if (!col) continue
            ctx.fillStyle = col
            ctx.fillRect(c * p, r * p, p, p)
          }
        }
      }
    }

    // Snooze bubble
    Text {
      textFormat: Text.PlainText
      visible: root.mode === "sleep"
      text: "z"
      color: Commons.Color.muted
      font.pixelSize: Math.max(8, root.pixel * 4)
      font.bold: true
      x: root.facingRight ? parent.width - width / 2 : -width / 2
      y: -height / 3 - zFloat.value
      opacity: 1 - zFloat.value / (root.pixel * 4)
      QtObject {
        id: zFloat
        property real value: 0
        NumberAnimation on value {
          running: root.mode === "sleep" && !root.still
          from: 0; to: root.pixel * 4
          duration: 1600
          loops: Animation.Infinite
        }
      }
    }
  }

  // Repaint when the theme changes so the fox follows the accent color.
  Connections {
    target: Commons.Color
    function onAccentChanged() { sprite.requestPaint() }
    function onForegroundChanged() { sprite.requestPaint() }
  }

  SequentialAnimation {
    id: hop
    NumberAnimation { target: root; property: "hopOffset"; to: root.pixel * 3; duration: 140; easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "hopOffset"; to: 0; duration: 120; easing.type: Easing.OutCubic }
    onFinished: if (!root.still) root.setMode("walk")
  }

  // Click the fox to wake it / make it hop.
  MouseArea {
    x: pet.x; y: 0
    width: pet.width; height: root.height
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      if (root.still) return
      root.mode = "hop"
      sprite.requestPaint()
      hop.restart()
    }
  }
}
