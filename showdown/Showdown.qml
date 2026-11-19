import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Two pixel cowboys duel on the bar.
// ready (back to back) -> pace (walk apart) -> turn (face off, tense pause)
// -> draw (both aim, "DRAW!") -> shot (random winner fires, bullet flies)
// -> after (loser down, score shown) -> gone (blink out) -> ready ...
BarWidget {
  id: root
  moduleName: "cxdog.showdown"

  readonly property int trackWidth: Number(setting("trackWidth", 300))
  // Runs even with Hyprland animations off, unless "followReduceMotion": true.
  readonly property bool followReduceMotion: setting("followReduceMotion", false) === true
  readonly property bool still: vertical || (followReduceMotion && Style.reduceMotion)

  visible: !vertical
  implicitWidth: vertical ? 0 : trackWidth
  implicitHeight: barSize

  readonly property int p: Math.max(1, Math.floor((barSize - 6) / 10))
  readonly property int cw: 10 * p
  readonly property int ch: 10 * p
  readonly property int groundY: Math.round((height - ch) / 2)
  readonly property int margin: 4
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- Sprites, 10 x 10, facing right ----
  // h hat  s skin  k eye  v vest  n belt/boots  p pants  g gun
  readonly property var headRows: [
    "...hhh....",
    ".hhhhhhh..",
    "...ssk....",
    "...sss....",
    "..vvvv...."
  ]
  readonly property var armsDown: [".svvvvs...", "..nnnn...."]
  readonly property var armsAim:  [".svvvvvssg", "..nnnn...."]
  readonly property var legsStand: ["..pppp....", "..p..p....", ".nn..nn..."]
  readonly property var legsA:     ["..pppp....", ".p....p...", "nn....nn.."]
  readonly property var legsB:     ["..pppp....", "...pp.....", "..nnnn...."]
  readonly property var deadRows: [
    "..........",
    "..........",
    "..........",
    "..........",
    "..........",
    "..........",
    "..........",
    "hhh..s....",
    ".ssvvvvppn",
    ".ssvvvvppn"
  ]

  function sprite(pose) {
    if (pose === "dead") return deadRows
    var arms = pose === "aim" ? armsAim : armsDown
    var legs = pose === "walkA" ? legsA : pose === "walkB" ? legsB : legsStand
    return headRows.concat(arms).concat(legs)
  }

  readonly property var basePalette: ({
    "s": "#e8b896", "k": "#141414", "n": "#8a5a3c", "p": "#6a7aa0", "g": "#c8c8c8"
  })
  function palette(hat, vest) {
    var out = {}
    for (var key in basePalette) out[key] = basePalette[key]
    out["h"] = hat
    out["v"] = vest
    return out
  }

  // ---- Duel state ----
  property string phase: "ready"
  property int ticks: 0
  property int phaseLen: 0
  property int winner: 0          // 0 = left cowboy, 1 = right cowboy
  property int scoreL: 0
  property int scoreR: 0
  property int frame: 0
  property real lx: 0
  property real rx: 0
  property bool lFacingRight: false
  property bool rFacingRight: true
  property string lPose: "stand"
  property string rPose: "stand"
  property bool shown: true
  property real bulletX: -100
  property bool bulletLive: false
  property int flashTicks: 0
  property string banner: ""
  property bool bannerHot: false

  function ticksFor(minS, maxS) {
    return Math.max(1, Math.round((minS + Math.random() * (maxS - minS)) * 1000 / tick.interval))
  }

  function enter(next, len) {
    phase = next
    ticks = 0
    phaseLen = len
  }

  function reset() {
    lx = Math.round(width / 2 - 9 * p)
    rx = Math.round(width / 2 - p)
    lFacingRight = false
    rFacingRight = true
    lPose = "stand"
    rPose = "stand"
    bulletLive = false
    flashTicks = 0
    banner = ""
    shown = true
    enter("ready", ticksFor(3, 7))
  }

  Timer {
    id: tick
    interval: 45
    repeat: true
    running: !root.still && root.visible && root.width > 0
    onTriggered: {
      root.ticks++
      if (root.flashTicks > 0) root.flashTicks--

      switch (root.phase) {
      case "ready":
        if (root.ticks >= root.phaseLen) {
          root.lPose = "walkA"; root.rPose = "walkA"
          root.enter("pace", 0)
        }
        break

      case "pace": {
        var done = true
        if (root.lx > root.margin) { root.lx -= 1; done = false }
        if (root.rx < root.width - root.cw - root.margin) { root.rx += 1; done = false }
        if (root.ticks % 5 === 0) {
          root.frame++
          var pose = root.frame % 2 ? "walkB" : "walkA"
          root.lPose = pose; root.rPose = pose
        }
        if (done) {
          root.lPose = "stand"; root.rPose = "stand"
          root.lFacingRight = true; root.rFacingRight = false
          root.enter("turn", root.ticksFor(0.8, 2.4))
        }
        break
      }

      case "turn":
        if (root.ticks >= root.phaseLen) {
          root.lPose = "aim"; root.rPose = "aim"
          root.banner = "DRAW!"; root.bannerHot = true
          root.winner = Math.random() < 0.5 ? 0 : 1
          root.enter("draw", root.ticksFor(0.15, 0.6))   // the winner's reaction time
        }
        break

      case "draw":
        if (root.ticks >= root.phaseLen) {
          root.bulletX = root.winner === 0 ? root.lx + root.cw : root.rx - 2 * root.p
          root.bulletLive = true
          root.flashTicks = 3
          root.enter("shot", 0)
        }
        break

      case "shot": {
        var dir = root.winner === 0 ? 1 : -1
        root.bulletX += dir * 7
        var hit = root.winner === 0
          ? root.bulletX + 2 * root.p >= root.rx + 3 * root.p
          : root.bulletX <= root.lx + 7 * root.p
        if (hit) {
          root.bulletLive = false
          if (root.winner === 0) { root.rPose = "dead"; root.lPose = "stand"; root.scoreL++ }
          else { root.lPose = "dead"; root.rPose = "stand"; root.scoreR++ }
          root.banner = root.scoreL + " – " + root.scoreR
          root.bannerHot = false
          root.enter("after", root.ticksFor(3, 4.5))
        }
        break
      }

      case "after":
        if (root.ticks >= root.phaseLen) {
          root.shown = false
          root.banner = ""
          root.enter("gone", root.ticksFor(0.6, 0.6))
        }
        break

      case "gone":
        if (root.ticks >= root.phaseLen) root.reset()
        break
      }
    }
  }

  onWidthChanged: if (phase === "ready" || phase === "gone") reset()
  onStillChanged: if (still) reset()
  Component.onCompleted: reset()

  // ---- Drawing ----
  component Cowboy: Canvas {
    id: cv
    property var rows: []
    property var pal: ({})
    property bool facingRight: true
    width: root.cw
    height: root.ch
    y: root.groundY
    visible: root.shown
    onRowsChanged: requestPaint()
    onPalChanged: requestPaint()
    transform: Scale { origin.x: cv.width / 2; xScale: cv.facingRight ? 1 : -1 }
    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      for (var r = 0; r < rows.length; r++) {
        var line = rows[r]
        for (var c = 0; c < line.length; c++) {
          var col = pal[line[c]]
          if (!col) continue
          ctx.fillStyle = col
          ctx.fillRect(c * root.p, r * root.p, root.p, root.p)
        }
      }
    }
  }

  Cowboy {
    // White hat, vest in the theme accent.
    x: Math.round(root.lx)
    rows: root.sprite(root.lPose)
    pal: root.palette("#ece2d0", Commons.Color.accent)
    facingRight: root.lFacingRight
  }

  Cowboy {
    // Brown hat, blue vest.
    x: Math.round(root.rx)
    rows: root.sprite(root.rPose)
    pal: root.palette("#a87452", "#8fb3e0")
    facingRight: root.rFacingRight
  }

  // Muzzle flash
  Rectangle {
    visible: root.flashTicks > 0 && root.shown
    width: 2 * root.p; height: 2 * root.p
    color: "#f7e3a1"
    x: root.winner === 0 ? root.lx + root.cw : root.rx - 2 * root.p
    y: root.groundY + 4 * root.p
  }

  // Bullet
  Rectangle {
    visible: root.bulletLive
    width: 2 * root.p; height: root.p
    color: "#f7e3a1"
    x: Math.round(root.bulletX)
    y: root.groundY + 5 * root.p
  }

  // "DRAW!" and the running score, in the empty street between them.
  Text {
    visible: root.banner !== ""
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.banner
    color: root.bannerHot ? Commons.Color.accent : Commons.Color.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    font.bold: root.bannerHot
  }
}
