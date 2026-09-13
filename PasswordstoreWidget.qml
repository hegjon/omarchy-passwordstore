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
    // The active vault's name, read from this entry's settings: `vaults` is
    // an array, or a string holding one when set without --json.
    readonly property string activeVaultName: {
      var s = root.settings || {}
      var vaults = s.vaults
      if (typeof vaults === "string") { try { vaults = JSON.parse(vaults) } catch (e) { vaults = [] } }
      if (!Array.isArray(vaults) || vaults.length === 0) return ""
      var active = String(s.activeVaultId || "")
      for (var i = 0; i < vaults.length; i++)
        if (vaults[i] && vaults[i].id === active) return String(vaults[i].name || vaults[i].id)
      return String(vaults[0].name || vaults[0].id || "")
    }
    tooltipText: "Password Store" + (activeVaultName !== "" ? " · " + activeVaultName : "")
    slotSize: Style.bar.statusSlot

    onPressed: function(buttonCode) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle " + root.pluginId)
    }
  }
}
