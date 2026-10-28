import Quickshell
import QtQuick
import qs.Commons

// The dock strip: pinned apps, then anything else that is running, with hover
// tooltips, running-window dots, Ctrl letter hints and drag-to-reorder for the
// pinned section. Omaview shows one at full size inside the overview and, when
// enabled, a scaled copy on the desktop. Items are supplied by Omaview.qml:
//   [{ key, appId, name, icon, pinned, windows: [{ address, focused, focusOrder }], sepBefore }]
Rectangle {
  id: dock

  property var items: []
  property var pinnedOrder: []
  property real maxWidth: 1e9
  property int iconSize: Style.space(44)
  property bool hintsVisible: false
  property var shortcutKeys: []
  property var iconSource: null
  property color backgroundColor: Color.bar.background
  property real backgroundOpacity: 0.85
  property bool borderVisible: true
  property color borderColor: Util.alpha(Color.foreground, 0.18)

  signal activated(var item, bool forceNew)
  // Points are in window coordinates, so the caller can place a menu.
  signal contextRequested(var item, point at)
  signal backgroundContextRequested(point at)
  signal reordered(var appIds)
  signal scrolled(int steps)

  // Slots are keyed by item key and updated in place, so a window opening,
  // closing or changing focus never rebuilds an icon. They also freeze during
  // a pointer press so a changing list cannot destroy the MouseArea that owns
  // the grab.
  property var displayItems: []
  readonly property var itemsByKey: {
    var byKey = ({})
    for (var i = 0; i < displayItems.length; i++) byKey[displayItems[i].key] = displayItems[i]
    return byKey
  }
  readonly property var emptyItem: ({ key: "", appId: "", name: "", icon: "", pinned: false, windows: [], sepBefore: false })
  property var pressedItem: null
  property bool dragging: false
  property bool dragCanceled: false
  property point dragPoint: Qt.point(0, 0)
  property bool dropValid: false
  property string dropBefore: ""
  property real dropX: 0
  property real wheelAccumulator: 0

  ListModel { id: slots }

  function syncItems() {
    if (dock.pressedItem) return
    dock.displayItems = dock.items
    var keys = dock.items.map(function(item) { return item.key })
    for (var i = 0; i < keys.length; i++) {
      if (i < slots.count && slots.get(i).key === keys[i]) continue
      var found = -1
      for (var j = i + 1; j < slots.count; j++) if (slots.get(j).key === keys[i]) { found = j; break }
      if (found >= 0) slots.move(found, i, 1)
      else slots.insert(i, { key: keys[i] })
    }
    if (slots.count > keys.length) slots.remove(keys.length, slots.count - keys.length)
  }
  onItemsChanged: syncItems()
  Component.onCompleted: syncItems()

  function letterFor(key) {
    var index = dock.shortcutKeys.indexOf(key)
    return index >= 0 ? String.fromCharCode(97 + index) : ""
  }

  function clearDrag() {
    dock.dragging = false
    dock.dragCanceled = false
    dock.dropValid = false
    dock.pressedItem = null
    dock.syncItems()
  }

  function cancelDrag() {
    dock.dragCanceled = true
    dock.dragging = false
    dock.dropValid = false
  }

  function slotGeometry() {
    var result = []
    for (var i = 0; i < dockIcons.count; i++) {
      var slot = dockIcons.itemAt(i)
      if (!slot) continue
      var point = slot.mapToItem(null, 0, 0)
      result.push({ key: slot.item.key, pinned: slot.item.pinned,
                    x: point.x, y: point.y, w: slot.width * dock.scale, h: slot.height * dock.scale })
    }
    return result
  }

  function updateDrag(point) {
    if (!dock.pressedItem || dock.dragCanceled) return
    dock.dragging = true
    dock.dragPoint = point
    dock.dropValid = false
    dock.dropBefore = ""
    var left = 0, right = 0, found = false, targetFound = false
    for (var i = 0; i < dockIcons.count; i++) {
      var slot = dockIcons.itemAt(i)
      if (!slot || !slot.item.pinned) continue
      var position = slot.mapToItem(dock, 0, 0)
      if (!found) { left = position.x; found = true }
      right = position.x + slot.width
      if (!targetFound && slot.item.key !== dock.pressedItem.key && point.x < position.x + slot.width / 2) {
        dock.dropBefore = slot.item.appId
        dock.dropX = position.x - dockRow.spacing / 2
        targetFound = true
      }
    }
    if (!targetFound) dock.dropX = right + dockRow.spacing / 2
    var margin = Style.space(8)
    dock.dropValid = found && point.x >= left - margin && point.x <= right + margin
      && point.y >= -margin && point.y <= dock.height + margin
  }

  function finishDrag() {
    if (dock.dragging && dock.dropValid && !dock.dragCanceled && dock.pressedItem) {
      var next = dock.pinnedOrder.slice()
      var from = next.indexOf(dock.pressedItem.appId)
      if (from >= 0) {
        next.splice(from, 1)
        var to = dock.dropBefore ? next.indexOf(dock.dropBefore) : next.length
        if (to >= 0) {
          next.splice(to, 0, dock.pressedItem.appId)
          if (JSON.stringify(next) !== JSON.stringify(dock.pinnedOrder)) dock.reordered(next)
        }
      }
    }
    // MouseArea emits clicked after released. Keep the drag flag and frozen
    // slots until that event finishes so a drop cannot launch the app.
    Qt.callLater(dock.clearDrag)
  }

  width: Math.min(maxWidth, dockRow.implicitWidth + Style.space(20))
  height: iconSize + Style.space(22)
  radius: Math.max(Style.cornerRadius, Style.space(12))
  color: Util.alpha(backgroundColor, backgroundOpacity)
  border.width: borderVisible ? 1 : 0
  border.color: borderColor
  visible: displayItems.length > 0

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) dock.backgroundContextRequested(mapToItem(null, mouse.x, mouse.y))
    }
    onWheel: function(event) {
      event.accepted = true
      if (event.phase === Qt.ScrollMomentum) return
      var wheel = Util.wheelSteps(dock.wheelAccumulator, event.angleDelta.y)
      dock.wheelAccumulator = wheel.remainder
      if (wheel.steps !== 0) dock.scrolled(wheel.steps)
    }
  }

  Row {
    id: dockRow
    anchors.centerIn: parent
    spacing: Style.space(6)

    Repeater {
      id: dockIcons
      model: slots

      delegate: Row {
        id: dockSlot
        required property string key
        readonly property var item: dock.itemsByKey[key] || dock.emptyItem
        readonly property string shortcutLetter: dock.letterFor(key)
        spacing: Style.space(6)

        Rectangle {
          visible: dockSlot.item.sepBefore
          width: 1
          height: dock.iconSize * 0.7
          anchors.verticalCenter: parent.verticalCenter
          color: Util.alpha(Color.foreground, 0.25)
        }

        Item {
          id: dockItem
          width: dock.iconSize + Style.space(8)
          height: dock.iconSize + Style.space(10)
          opacity: dock.dragging && dock.pressedItem && dock.pressedItem.key === dockSlot.key ? 0.3 : 1

          Rectangle {
            anchors.fill: parent
            radius: Style.space(10)
            color: dockMouse.containsMouse ? Color.menu.selectedBackground : "transparent"
          }

          Image {
            id: dockImage
            width: dock.iconSize
            height: dock.iconSize
            anchors.horizontalCenter: parent.horizontalCenter
            y: dockMouse.containsMouse ? 0 : Style.space(2)
            scale: dockMouse.containsMouse ? 1.12 : 1.0
            source: dock.iconSource ? dock.iconSource(dockSlot.item.icon) : ""
            sourceSize.width: 128
            sourceSize.height: 128
            asynchronous: true
            Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
            Behavior on y { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            spacing: Style.space(3)
            Repeater {
              model: Math.min(3, dockSlot.item.windows.length)
              delegate: Rectangle {
                required property int index
                width: index === 0 ? Style.space(10) : Style.space(4)
                height: Style.space(4)
                radius: height / 2
                color: Color.accent
              }
            }
          }

          Rectangle {
            visible: dock.hintsVisible && dockSlot.shortcutLetter !== ""
            anchors.top: dockImage.top
            anchors.right: dockImage.right
            anchors.topMargin: -Style.space(3)
            anchors.rightMargin: -Style.space(3)
            width: Style.space(20)
            height: width
            radius: Style.space(6)
            color: Color.accent
            border.width: Math.max(1, Style.space(1))
            border.color: Color.background

            Text {
              anchors.centerIn: parent
              text: dockSlot.shortcutLetter
              color: Color.background
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          Rectangle {
            visible: dockMouse.containsMouse && !dock.dragging
            anchors.bottom: parent.top
            anchors.bottomMargin: Style.space(12)
            anchors.horizontalCenter: parent.horizontalCenter
            width: tipText.implicitWidth + Style.space(14)
            height: tipText.implicitHeight + Style.space(8)
            radius: height / 2
            color: Color.tooltip.background
            border.width: 1
            border.color: Util.alpha(Color.tooltip.border, 0.4)

            Text {
              id: tipText
              anchors.centerIn: parent
              text: dockSlot.item.name
              color: Color.tooltip.text
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            id: dockMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
            preventStealing: true
            cursorShape: dock.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
            property point pressPoint: Qt.point(0, 0)

            onPressed: function(mouse) {
              pressPoint = Qt.point(mouse.x, mouse.y)
              if (mouse.button === Qt.LeftButton && dockSlot.item.pinned) {
                dock.pressedItem = dockSlot.item
                dock.dragCanceled = false
              }
            }
            onPositionChanged: function(mouse) {
              if (!(mouse.buttons & Qt.LeftButton) || !dock.pressedItem
                  || dock.pressedItem.key !== dockSlot.key || dock.dragCanceled) return
              var dx = mouse.x - pressPoint.x, dy = mouse.y - pressPoint.y
              if (!dock.dragging && dx * dx + dy * dy < drag.threshold * drag.threshold) return
              dock.updateDrag(mapToItem(dock, mouse.x, mouse.y))
            }
            onReleased: function(mouse) {
              if (mouse.button === Qt.LeftButton && dock.pressedItem) dock.finishDrag()
            }
            onCanceled: {
              dock.cancelDrag()
              Qt.callLater(dock.clearDrag)
            }
            onClicked: function(mouse) {
              if (dock.dragging || dock.dragCanceled) return
              if (mouse.button === Qt.RightButton) dock.contextRequested(dockSlot.item, mapToItem(null, mouse.x, mouse.y))
              else dock.activated(dockSlot.item, mouse.button === Qt.MiddleButton)
            }
          }
        }
      }
    }
  }

  Rectangle {
    visible: dock.dragging && dock.dropValid
    x: dock.dropX - width / 2
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(3)
    height: dock.iconSize
    radius: width / 2
    color: Color.accent
    z: 10
  }

  Image {
    visible: dock.dragging
    x: dock.dragPoint.x - width / 2
    y: dock.dragPoint.y - height / 2
    width: dock.iconSize
    height: width
    source: dock.pressedItem && dock.iconSource ? dock.iconSource(dock.pressedItem.icon) : ""
    sourceSize.width: 128
    sourceSize.height: 128
    scale: 1.12
    opacity: dock.dropValid ? 1 : 0.6
    z: 20
  }
}
