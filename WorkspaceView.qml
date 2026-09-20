import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import qs.Commons

// One workspace drawn to scale: the monitor as a wallpaper rectangle, always
// centered, with each window at its real position. In the scrolling layout,
// columns that sit outside the monitor spill past the wallpaper on either
// side; where they run past the view's edge they fade out. With clipToMonitor
// the view is just the monitor rectangle (used for the workspace strip).
Item {
  id: view

  property int wsId: 0
  property string wsName: ""
  property var clients: []
  property real monW: 1920
  property real monH: 1080
  property real s: 0.25
  property string wallpaper: ""
  property bool clipToMonitor: false
  property bool live: true
  property bool isActive: false
  property bool showBadges: true
  property int radius: 0
  // Resolves a Hyprland address to the Wayland toplevel to capture, and a
  // window class to an icon URL. Both are supplied by Omaview.qml.
  property var toplevelFor: null
  property var iconFor: null

  signal windowActivated(string address)
  signal windowAccepted(string address)
  signal windowCloseRequested(string address)
  signal workspaceActivated(int wsId)

  readonly property real wallW: monW * s
  readonly property real wallH: monH * s
  readonly property real fadeW: Style.space(90)
  readonly property real originX: clipToMonitor ? 0 : (width - wallW) / 2
  // The parent clips the previous/next workspace to a narrow peek. Capture
  // only windows intersecting that peek or the main overview viewport.
  readonly property real captureTop: Math.max(0, -y)
  readonly property real captureBottom: Math.min(height, parent ? parent.height - y : height)

  function previewStatus() {
    var result = []
    for (var i = 0; i < windowPreviews.count; i++) {
      var preview = windowPreviews.itemAt(i)
      if (!preview) continue
      var position = preview.mapToItem(null, 0, 0)
      result.push({ address: preview.address, capturing: preview.previewActive,
                    hasContent: preview.hasPreview, x: position.x, y: position.y,
                    w: preview.width, h: preview.height })
    }
    return result
  }

  // Whether any window runs past the left / right edge of the view.
  readonly property bool overflowLeft: {
    if (clipToMonitor) return false
    for (var i = 0; i < clients.length; i++) if (originX + clients[i].x * s < 0) return true
    return false
  }
  readonly property bool overflowRight: {
    if (clipToMonitor) return false
    for (var i = 0; i < clients.length; i++) if (originX + (clients[i].x + clients[i].w) * s > width) return true
    return false
  }

  height: wallH
  clip: true

  // Windows live in a ListModel keyed by address so a refresh updates the
  // existing previews in place: geometry animates and captures keep running
  // instead of every delegate being rebuilt.
  ListModel { id: windows }

  function syncWindows() {
    var seen = ({})
    for (var i = 0; i < clients.length; i++) {
      var c = clients[i]
      seen[c.address] = true
      var row = { address: c.address, cx: c.x, cy: c.y, cw: c.w, ch: c.h, cls: c.cls,
                  title: c.title, floating: c.floating === true, focused: c.focused === true }
      var at = -1
      for (var j = 0; j < windows.count; j++) if (windows.get(j).address === c.address) { at = j; break }
      if (at >= 0) windows.set(at, row)
      else windows.append(row)
    }
    for (var k = windows.count - 1; k >= 0; k--) if (!seen[windows.get(k).address]) windows.remove(k)
  }
  onClientsChanged: syncWindows()
  Component.onCompleted: syncWindows()

  Item {
    id: edgeMask
    anchors.fill: parent
    visible: false
    layer.enabled: true

    Rectangle {
      anchors.fill: parent
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: view.overflowLeft ? "transparent" : "black" }
        GradientStop { position: Math.min(0.49, view.fadeW / Math.max(1, view.width)); color: "black" }
        GradientStop { position: 1 - Math.min(0.49, view.fadeW / Math.max(1, view.width)); color: "black" }
        GradientStop { position: 1.0; color: view.overflowRight ? "transparent" : "black" }
      }
    }
  }

  Item {
    id: flick
    anchors.fill: parent

    // The mask is a sibling of this layer: a mask inside the item it masks
    // never renders.
    layer.enabled: view.overflowLeft || view.overflowRight
    layer.effect: MultiEffect {
      maskEnabled: true
      maskSource: edgeMask
      // Without a spread the mask is a hard alpha threshold, not a gradient.
      maskThresholdMin: 0.5
      maskSpreadAtMin: 1.0
    }

    Rectangle {
      id: wall
      x: view.originX
      y: 0
      width: view.wallW
      height: view.wallH
      radius: view.radius
      color: Color.background
      clip: true

      Image {
        anchors.fill: parent
        source: view.wallpaper
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize.width: Math.round(view.wallW * 2)
      }

      MouseArea {
        anchors.fill: parent
        onClicked: view.workspaceActivated(view.wsId)
      }
    }

    Repeater {
      id: windowPreviews
      model: windows

      delegate: Item {
        id: win
        required property string address
        required property real cx
        required property real cy
        required property real cw
        required property real ch
        required property string cls
        required property string title
        required property bool floating
        required property bool focused
        readonly property var toplevel: view.toplevelFor ? view.toplevelFor(address) : null
        readonly property bool previewActive: view.live && view.visible
          && x + width > 0 && x < view.width
          && y + height > view.captureTop && y < view.captureBottom
        readonly property bool hasPreview: capture.hasContent

        x: view.originX + cx * view.s
        y: cy * view.s
        width: Math.max(4, cw * view.s)
        height: Math.max(4, ch * view.s)
        z: floating ? 2 : (focused ? 1 : 0)

        Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        Rectangle {
          anchors.fill: parent
          color: Color.background
        }

        ScreencopyView {
          id: capture
          anchors.fill: parent
          captureSource: win.previewActive ? win.toplevel : null
          live: win.previewActive
          paintCursor: false
        }

        Rectangle {
          anchors.fill: parent
          color: hover.containsMouse ? Util.alpha(Color.accent, 0.10) : "transparent"
          border.width: (win.focused && view.isActive) || hover.containsMouse ? Math.max(1, Style.space(2)) : 0
          border.color: Color.accent
        }

        Image {
          visible: view.showBadges
          width: Math.min(Style.space(34), win.height * 0.4)
          height: width
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(4)
          source: view.showBadges && view.iconFor ? view.iconFor(win.cls) : ""
          sourceSize.width: 96
          sourceSize.height: 96
          asynchronous: true
        }

        Rectangle {
          visible: view.showBadges && hover.containsMouse
          anchors.top: parent.top
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.topMargin: Style.space(4)
          width: Math.min(parent.width - Style.space(8), titleText.implicitWidth + Style.space(12))
          height: titleText.implicitHeight + Style.space(6)
          radius: height / 2
          color: Util.alpha(Color.background, 0.85)

          Text {
            id: titleText
            anchors.centerIn: parent
            width: parent.width - Style.space(12)
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: win.title
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.MiddleButton
          onDoubleClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton) view.windowAccepted(win.address)
          }
          onClicked: function(mouse) {
            if (mouse.button === Qt.MiddleButton) view.windowCloseRequested(win.address)
            else view.windowActivated(win.address)
          }
        }
      }
    }

    Rectangle {
      x: view.originX + Style.space(6)
      y: Style.space(6)
      visible: view.showBadges
      width: Math.max(height, wsLabel.implicitWidth + Style.space(10))
      height: wsLabel.implicitHeight + Style.space(4)
      radius: height / 2
      color: Util.alpha(Color.background, 0.8)

      Text {
        id: wsLabel
        anchors.centerIn: parent
        text: view.wsName
        color: view.isActive ? Color.accent : Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  Rectangle {
    visible: view.clipToMonitor
    anchors.fill: parent
    color: "transparent"
    radius: view.radius
    border.width: view.isActive ? Math.max(1, Style.space(2)) : 0
    border.color: Color.accent
  }
}
