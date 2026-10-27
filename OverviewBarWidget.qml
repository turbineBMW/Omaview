import QtQuick
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Navigation.js" as Navigation

BarWidget {
  id: root
  moduleName: "turbinebmw.omaview"
  visible: setting("showButton", true) !== false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  property real wheelAccumulator: 0

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    fontFamily: "omarchy"
    horizontalMargin: 7.5
    onPressed: function(button) {
      if (!root.bar) return
      if (button === Qt.RightButton) root.bar.run("xdg-terminal-exec")
      else root.bar.run("omarchy-shell shell toggle turbinebmw.omaview '{}'")
    }
    // Scrolling down moves to the next workspace and up to the previous one,
    // matching the overview. One notch is one step.
    onWheelMoved: function(delta) {
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      Hyprland.dispatch(Navigation.stepWorkspace(wheel.steps < 0 ? 1 : -1))
    }
  }
}
