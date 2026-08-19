import QtQuick
import qs.Commons
import qs.Ui

// Bar button for the Password Store overlay. The search card itself is
// PasswordstoreOverlay.qml; this only summons it, the way the Omarchy menu's
// bar button summons the menu. The widget's settings (store directory, clip
// time, …) are stored on this bar entry and read by the overlay from there.
BarWidget {
  id: root

  readonly property string pluginId: "hegjon.passwordstore"
  moduleName: pluginId

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: String.fromCodePoint(0xF0306)   // nf-md-key
    tooltipText: "Password Store"
    slotSize: Style.bar.statusSlot

    onPressed: function(buttonCode) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle " + root.pluginId)
    }
  }
}
