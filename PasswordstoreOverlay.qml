pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Centered type-to-search overlay for pass, the standard unix password
// manager, styled like the Omarchy menu: same surface tokens, same card, same
// rows. Summoned with `omarchy-shell shell toggle hegjon.passwordstore`, from
// a keybinding or the bar button.
//
// The overlay never sees a secret. passwordstore-list walks the store for the
// names of the *.gpg files, and passwordstore-action hands a chosen entry to
// pass itself (or wtype, for typing) once the card has closed. gpg-agent
// prompts through pinentry as it would from a terminal.
Item {
  id: root

  readonly property string pluginId: "hegjon.passwordstore"

  // Injected by the shell's panel loader.
  property var shell: null
  property var manifest: null

  property bool opened: false

  // --- state ------------------------------------------------------------

  property var entries: []
  property var recent: []
  property string storePath: ""
  property bool otpAvailable: false
  property string lastError: ""
  property bool initialized: false

  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: true

  // --- settings ---------------------------------------------------------

  // Settings live on the bar widget's entry in shell.json (that is where
  // `omarchy bar set` and the widget settings dialog write them), so the
  // overlay reads them from the live shell config, falling back to the
  // manifest defaults when the widget is not on the bar at all.
  readonly property var widgetSettings: {
    var layout = shell && shell.shellConfig && shell.shellConfig.bar ? shell.shellConfig.bar.layout : null
    if (!layout) return ({})
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = layout[sections[s]]
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i]
        var id = typeof entry === "string" ? entry : (entry && entry.id)
        if (id !== pluginId) continue
        return typeof entry === "string" ? ({}) : entry
      }
    }
    return ({})
  }

  function setting(key, fallback) {
    var value = widgetSettings ? widgetSettings[key] : undefined
    if (value === undefined || value === null || value === "") {
      var defaults = manifest && manifest.barWidget ? manifest.barWidget.defaults : null
      if (defaults && defaults[key] !== undefined && defaults[key] !== null) return defaults[key]
      return fallback
    }
    return value
  }

  // `omarchy bar set` stores booleans as strings unless given --json, so a
  // boolean setting has to be coerced rather than read straight through.
  function boolSetting(key, fallback) {
    var value = setting(key, fallback)
    if (typeof value === "string") return value !== "false" && value !== "0" && value !== ""
    return value !== false
  }

  function intSetting(key, fallback, min, max) {
    var value = parseInt(setting(key, fallback), 10)
    if (!isFinite(value)) return fallback
    return Math.max(min, Math.min(max, value))
  }

  readonly property string storeDir: String(setting("storeDir", "")).trim()
  readonly property int clipTimeSec: intSetting("clipTimeSec", 45, 5, 600)
  readonly property string usernameKeys: String(setting("usernameKeys", "login,user,username,email")).trim()
  readonly property bool allowTyping: boolSetting("allowTyping", true)
  readonly property bool notifyOnCopy: boolSetting("notifyOnCopy", true)

  // Qt.resolvedUrl yields a file:// URL; Process wants a plain path.
  readonly property string listPath:
    Qt.resolvedUrl("passwordstore-list").toString().replace(/^file:\/\//, "")
  readonly property string actionPath:
    Qt.resolvedUrl("passwordstore-action").toString().replace(/^file:\/\//, "")

  // Recently used names live outside the store so they are never committed
  // with it, and outside the plugin dir so a reinstall keeps them.
  readonly property string recentFile: {
    var state = Quickshell.env("XDG_STATE_HOME")
    if (!state) state = Quickshell.env("HOME") + "/.local/state"
    return state + "/omarchy-passwordstore/recent"
  }

  readonly property string keyGlyph: String.fromCodePoint(0xF0306)     // nf-md-key
  readonly property string clockGlyph: String.fromCodePoint(0xF0954)   // nf-md-history

  // --- look: the menu's tokens ------------------------------------------

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color selectedBorder: Color.menu.selectedBorder
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property real rowReservedBorderLeft: Border.left(selectedBorderSpec)
  readonly property real rowReservedBorderRight: Border.right(selectedBorderSpec)
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int rowSpacing: Style.space(2)
  property int rowHeight: Math.max(Style.space(50), Style.font.heading + Style.spacing.rowPaddingX * 2)
  // The legend wraps in the menu-width card; its height feeds the card's.
  readonly property int footerHeight: footerLabel.implicitHeight
  property int maxVisibleRows: 10

  property int cardWidth: Math.min(Style.space(420), panel.width - Style.gapsOut * 2)
  readonly property int visibleRowsHeight: {
    var n = Math.min(rows.length, maxVisibleRows)
    if (n === 0) return rowHeight * 2   // room for the "no matches" message
    return n * rowHeight + (n - 1) * rowSpacing
  }
  readonly property int cardHeight: Math.min(
    contentMargin * 2 + headerHeight + contentSpacing + visibleRowsHeight + contentSpacing + footerHeight,
    panel.height - Style.gapsOut * 2)

  // --- open / close (the shell's overlay contract) ----------------------

  function open(payloadJson) {
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.opened = true
    // The store is re-read on every open: a `find` over a few hundred files
    // is cheap, and it is the only way a `pass insert` from a terminal shows
    // up without a restart.
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // No IpcHandler here on purpose: the shell already exposes
  // `omarchy-shell shell toggle|summon|hide hegjon.passwordstore` for every
  // overlay, and an IpcHandler inside a hot-reloaded plugin has crashed
  // Quickshell when a reload raced a shell restart.

  // --- filtering --------------------------------------------------------

  // Every whitespace-separated token must match; a token matches as a
  // substring first and as an in-order subsequence second, so "ghb" still
  // finds "web/github.com" while plain substrings rank above it. Ties are
  // broken by how early the match begins, then by the store's own order.
  function scoreEntry(name, tokens) {
    var lower = name.toLowerCase()
    var base = lower.slice(lower.lastIndexOf("/") + 1)
    var score = 0
    for (var t = 0; t < tokens.length; t++) {
      var token = tokens[t]
      var at = lower.indexOf(token)
      if (at >= 0) {
        score += 1000 - at
        if (base.indexOf(token) === 0) score += 500       // basename starts with it
        else if (base.indexOf(token) >= 0) score += 200   // somewhere in basename
        continue
      }
      var pos = 0
      for (var c = 0; c < token.length; c++) {
        pos = lower.indexOf(token[c], pos)
        if (pos < 0) return -1
        pos++
      }
      score += 100
    }
    return score
  }

  function splitName(name) {
    var slash = name.lastIndexOf("/")
    return {
      name: name,
      leaf: slash >= 0 ? name.slice(slash + 1) : name,
      folder: slash >= 0 ? name.slice(0, slash) : ""
    }
  }

  // The card's rows. Without a filter the recent entries come first, then the
  // whole store; with one, the ranked matches.
  readonly property var rows: {
    var tokens = filterText.toLowerCase().split(/\s+/).filter(function(t) { return t !== "" })
    var i, row
    if (tokens.length === 0) {
      var out = []
      var seen = {}
      for (i = 0; i < recent.length; i++) {
        row = splitName(recent[i]); row.recent = true
        out.push(row)
        seen[recent[i]] = true
      }
      for (i = 0; i < entries.length; i++) {
        if (seen[entries[i]]) continue
        row = splitName(entries[i]); row.recent = false
        out.push(row)
      }
      return out
    }
    var scored = []
    for (i = 0; i < entries.length; i++) {
      var s = scoreEntry(entries[i], tokens)
      if (s < 0) continue
      row = splitName(entries[i])
      row.recent = recent.indexOf(entries[i]) >= 0
      row.score = s
      row.order = i
      scored.push(row)
    }
    scored.sort(function(a, b) { return b.score - a.score || a.order - b.order })
    return scored
  }

  onRowsChanged: {
    if (rows.length === 0) selectedIndex = 0
    else if (selectedIndex >= rows.length) selectedIndex = rows.length - 1
    Qt.callLater(function() {
      if (root.rows.length > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function setFilter(text) {
    if (text === filterText) return
    filterText = text
    selectedIndex = 0
    cursorActive = true
  }

  function select(delta) {
    if (rows.length === 0) return
    cursorActive = true
    selectedIndex = Math.max(0, Math.min(rows.length - 1, selectedIndex + delta))
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function selectAbsolute(index) {
    if (rows.length === 0) return
    cursorActive = true
    selectedIndex = Math.max(0, Math.min(rows.length - 1, index))
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  readonly property var selectedEntry: rows.length > 0 && selectedIndex >= 0 && selectedIndex < rows.length
    ? rows[selectedIndex] : null

  // --- listing ----------------------------------------------------------

  property bool refreshPending: false

  function refresh() {
    if (listProcess.running) { refreshPending = true; return }
    refreshPending = false
    var command = [listPath, "--recent", recentFile]
    if (storeDir !== "") command.push("--store", storeDir)
    listProcess.command = command
    listProcess.running = true
  }

  function applyListing(text) {
    initialized = true
    var parsed
    try {
      parsed = JSON.parse(String(text || ""))
    } catch (error) {
      lastError = "The password store helper returned something unreadable"
      return
    }
    if (parsed && parsed.store) storePath = String(parsed.store)
    if (parsed && parsed.error) {
      lastError = String(parsed.error)
      entries = []
      recent = []
      console.warn("passwordstore: listing failed:", lastError)
      return
    }
    lastError = ""
    entries = (parsed && parsed.entries) ? parsed.entries : []
    recent = (parsed && parsed.recent) ? parsed.recent : []
    otpAvailable = !!(parsed && parsed.otp)
  }

  Process {
    id: listProcess
    running: false
    command: []

    stdout: StdioCollector { id: listStdout; waitForEnd: true }
    stderr: StdioCollector { id: listStderr; waitForEnd: true }

    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.applyListing(listStdout.text)
      } else {
        root.initialized = true
        var detail = String(listStderr.text || "").replace(/\s+/g, " ").trim()
        root.lastError = detail !== "" ? detail : "The password store helper exited with code " + exitCode
      }
      if (root.refreshPending) Qt.callLater(root.refresh)
    }
  }

  // --- actions ----------------------------------------------------------

  // One action at a time: a second Enter while gpg-agent is still asking for
  // the passphrase would only queue a second prompt.
  function runAction(action, entry) {
    if (!entry || actionProcess.running) return
    if ((action === "type-password" || action === "type-username") && !allowTyping) return
    if (action === "copy-otp" && !otpAvailable) return

    var command = [actionPath, action, entry.name,
                   "--recent", recentFile,
                   "--clip-time", String(clipTimeSec),
                   "--username-keys", usernameKeys]
    if (storeDir !== "") command.push("--store", storeDir)
    if (!notifyOnCopy) command.push("--quiet")

    // Close before acting so a typed password lands in the window the user
    // came from, and so a pinentry dialog is not fighting the card for focus.
    dismiss()
    actionProcess.command = command
    actionProcess.running = true
  }

  function activateSelected(action) { runAction(action, selectedEntry) }

  Process {
    id: actionProcess
    running: false
    command: []

    stderr: StdioCollector { id: actionStderr; waitForEnd: true }

    onExited: function(exitCode) {
      var detail = String(actionStderr.text || "").replace(/\s+/g, " ").trim()
      if (exitCode !== 0) console.warn("passwordstore: action failed:", detail || ("exit " + exitCode))
    }
  }

  // --- the card ---------------------------------------------------------

  readonly property string hintText: {
    var hints = ["Enter copy password", "Alt+U username"]
    if (otpAvailable) hints.push("Alt+O OTP")
    if (allowTyping) hints.push("Ctrl+Enter type")
    hints.push("Alt+E edit")
    return hints.join("  ·  ")
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-passwordstore"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      // Type-to-filter, as the menu does: there is no text field to focus,
      // every printable key extends the query. That rules out single-letter
      // shortcuts, so actions are Enter and modifier combinations.
      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var ctrl = event.modifiers & Qt.ControlModifier
          var alt = event.modifiers & Qt.AltModifier
          var shift = event.modifiers & Qt.ShiftModifier

          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Down || (ctrl && (event.key === Qt.Key_N || event.key === Qt.Key_J))) {
            root.select(1); event.accepted = true
          } else if (event.key === Qt.Key_Up || (ctrl && (event.key === Qt.Key_P || event.key === Qt.Key_K))) {
            root.select(-1); event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.select(root.maxVisibleRows); event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-root.maxVisibleRows); event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.selectAbsolute(0); event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.selectAbsolute(root.rows.length - 1); event.accepted = true
          } else if (event.key === Qt.Key_F5) {
            root.refresh(); event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (ctrl && shift) root.activateSelected("type-username")
            else if (ctrl) root.activateSelected("type-password")
            else if (alt) root.activateSelected("copy-username")
            else root.activateSelected("copy-password")
            event.accepted = true
          } else if (alt && event.key === Qt.Key_U) {
            root.activateSelected("copy-username"); event.accepted = true
          } else if (alt && event.key === Qt.Key_O) {
            root.activateSelected("copy-otp"); event.accepted = true
          } else if (alt && event.key === Qt.Key_E) {
            root.activateSelected("edit"); event.accepted = true
          } else if (!ctrl && !alt && event.text && event.text.length === 1
                     && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // The query line, in the menu's heading style.
        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            anchors.left: parent.left
            anchors.right: countText.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Password…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideLeft
          }

          Text {
            id: countText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.initialized && root.lastError === ""
            text: root.filterText ? root.rows.length + " / " + root.entries.length : String(root.entries.length)
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Item {
          width: parent.width
          height: root.visibleRowsHeight

          ListView {
            id: resultList
            anchors.fill: parent
            model: root.rows
            clip: true
            spacing: root.rowSpacing
            boundsBehavior: Flickable.StopAtBounds
            currentIndex: root.selectedIndex

            delegate: BorderSurface {
              id: row

              required property var modelData
              required property int index

              readonly property bool hasCursor: root.cursorActive && row.index === root.selectedIndex

              width: ListView.view.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: row.hasCursor ? root.selectedBackground : "transparent"
              borderSpec: row.hasCursor ? root.selectedBorderSpec : Border.none()

              Text {
                id: iconText
                text: root.keyGlyph
                color: row.hasCursor ? root.selectedText : root.foreground
                opacity: row.hasCursor ? 1 : 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.iconLarge
                width: Style.space(36)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                anchors.left: parent.left
                anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                id: contentColumn
                anchors.left: iconText.right
                anchors.leftMargin: Style.space(6)
                anchors.right: trail.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  width: parent.width
                  text: row.modelData.leaf
                  color: row.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.weight: Font.Medium
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  visible: row.modelData.folder !== ""
                  text: row.modelData.folder
                  color: row.hasCursor ? root.selectedText : root.foreground
                  opacity: 0.52
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideLeft
                }
              }

              Text {
                id: trail
                anchors.right: parent.right
                anchors.rightMargin: root.rowReservedBorderRight + Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.recent ? root.clockGlyph : ""
                width: row.modelData.recent ? implicitWidth : 0
                color: row.hasCursor ? root.selectedText : root.foreground
                opacity: 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  root.selectedIndex = row.index
                }
                onClicked: function(mouse) {
                  root.selectedIndex = row.index
                  if (mouse.button === Qt.RightButton) root.runAction("copy-username", row.modelData)
                  else if (mouse.button === Qt.MiddleButton) root.runAction("copy-otp", row.modelData)
                  else root.runAction("copy-password", row.modelData)
                }
              }
            }
          }

          // Empty states: an error from the helper, an empty store, or a
          // query nothing matches.
          Column {
            anchors.centerIn: parent
            width: parent.width - Style.space(24)
            spacing: Style.space(8)
            visible: root.rows.length === 0

            Text {
              width: parent.width
              text: root.lastError !== "" ? String.fromCodePoint(0xF0306) : "󰈉"
              color: root.lastError !== "" ? Color.urgent : root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
              text: root.lastError !== ""
                ? root.lastError
                : (!root.initialized
                   ? "Reading the store…"
                   : (root.entries.length === 0
                      ? "The store is empty. Add one with: pass insert <name>"
                      : "No matches for “" + root.filterText + "”"))
              color: root.lastError !== "" ? Color.urgent : root.foreground
              opacity: root.lastError !== "" ? 1 : 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        // Key legend, limited to the actions this configuration offers so a
        // store without pass-otp never advertises Alt+O.
        Text {
          id: footerLabel
          width: parent.width
          text: root.hintText
          wrapMode: Text.WordWrap
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
