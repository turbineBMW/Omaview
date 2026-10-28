import QtQuick
import qs.Commons

// A small context menu drawn inside the surface that opened it, so native
// keyboard routing and pointer dismissal work without a separate Wayland
// popup or focus grab. The owner handles arrow keys and Enter by changing
// currentIndex and calling activated; a click outside the card dismisses it.
Item {
  id: menu

  property var actions: []
  property int currentIndex: 0
  property point at: Qt.point(0, 0)
  property int rowHeight: Style.space(38)
  property real radius: Style.space(6)
  // With above set, the card opens upward from the point instead of downward.
  property bool above: false
  property alias card: card

  signal activated(int index)
  signal hovered(int index)
  signal dismissed()

  anchors.fill: parent
  z: 100
  visible: actions.length > 0

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    onClicked: menu.dismissed()
    onWheel: function(wheel) { wheel.accepted = true }
  }

  Rectangle {
    id: card
    x: Math.max(Style.space(8), Math.min(menu.at.x, menu.width - width - Style.space(8)))
    y: Math.max(Style.space(8), Math.min(menu.above ? menu.at.y - height - Style.space(8) : menu.at.y, menu.height - height - Style.space(8)))
    width: Style.space(210)
    height: rows.height + Style.space(8)
    radius: menu.radius
    color: Color.menu.background
    border.width: 1
    border.color: Color.accent

    Column {
      id: rows
      anchors.centerIn: parent
      width: parent.width - Style.space(8)

      Repeater {
        model: menu.actions
        delegate: Rectangle {
          required property var modelData
          required property int index
          width: rows.width
          height: menu.rowHeight
          radius: Math.max(0, menu.radius - Style.space(4))
          color: menu.currentIndex === index ? Color.menu.selectedBackground : "transparent"

          Text {
            anchors.fill: parent
            anchors.leftMargin: Style.space(12)
            verticalAlignment: Text.AlignVCenter
            text: modelData.label
            color: menu.currentIndex === index ? Color.menu.selectedText : Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onEntered: menu.hovered(parent.index)
            onClicked: menu.activated(parent.index)
          }
        }
      }
    }
  }
}
