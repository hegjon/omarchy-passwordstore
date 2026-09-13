pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

// Centered type-to-search overlay for pass, the standard unix password
// manager, styled like the Omarchy menu: same surface tokens, same card, same
// rows. Summoned with `omarchy-shell shell toggle hegjon.passwordstore '{}'`
// from a keybinding or the bar button. Without the payload the toggle is a no-op.
//
// The search card never sees a secret. passwordstore-list walks the store
// for the names of the *.gpg files, and passwordstore-action hands a chosen
// entry to pass itself (or wtype, for typing) once the card has closed.
// gpg-agent prompts through pinentry as it would from a terminal.
//
// The editor (Alt+N, Alt+E) is the one place a password is held here: a
// masked field, like the lock screen's, that accepts a paste, can reveal the
// value with each character class in its own colour, and can generate one.
// The value reaches pass over the helper's stdin, never argv, and the field
// is wiped the moment the card leaves the editor. Entries are stored as
// name/username so the list can show both without decrypting anything.
Item {
  id: root

  readonly property string pluginId: "hegjon.passwordstore"

  // Injected by the shell's panel loader.
  property var shell: null
  property var manifest: null

  property bool opened: false

  // "search" is the card as it always was; "edit" the entry form.
  property string mode: "search"
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

  function manifestDefault(key, fallback) {
    var defaults = manifest && manifest.barWidget ? manifest.barWidget.defaults : null
    if (defaults && defaults[key] !== undefined && defaults[key] !== null) return defaults[key]
    return fallback
  }

  function setting(key, fallback) {
    var value = widgetSettings ? widgetSettings[key] : undefined
    if (value === undefined || value === null || value === "") return manifestDefault(key, fallback)
    return value
  }

  // `omarchy bar set` stores booleans as strings unless given --json, so a
  // boolean setting has to be coerced rather than read straight through.
  function asBool(value, fallback) {
    if (value === undefined || value === null || value === "") return fallback
    if (typeof value === "string") return value !== "false" && value !== "0"
    return value !== false
  }

  function boolSetting(key, fallback) { return asBool(setting(key, fallback), fallback) }

  function intSetting(key, fallback, min, max) {
    var value = parseInt(setting(key, fallback), 10)
    if (!isFinite(value)) return fallback
    return Math.max(min, Math.min(max, value))
  }

  readonly property int clipTimeSec: intSetting("clipTimeSec", 60, 5, 600)
  readonly property string usernameKeys: String(setting("usernameKeys", "login,user,username,email")).trim()
  readonly property bool allowTyping: boolSetting("allowTyping", true)
  readonly property bool notifyOnCopy: boolSetting("notifyOnCopy", true)
  // name/username paths (github.com/jack), or pass's classic folder/entry
  // layout where the last segment is the entry and the username lives
  // inside the file.
  readonly property bool usernameInPath: boolSetting("usernameInPath", true)

  readonly property string storeDir: String(setting("storeDir", "")).trim()

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
  readonly property string eyeGlyph: String.fromCodePoint(0xF0208)     // nf-md-eye
  readonly property string eyeOffGlyph: String.fromCodePoint(0xF0209)  // nf-md-eye_off

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

  // Search stays menu-width; the editor has fields and buttons side by side
  // that do not fit in 420.
  property int cardWidth: Math.min(mode !== "search" ? Style.space(560) : Style.space(420),
                                   panel.width - Style.gapsOut * 2)
  readonly property int visibleRowsHeight: {
    var n = Math.min(rows.length, maxVisibleRows)
    if (n === 0) return rowHeight * 2   // room for the "no matches" message
    return n * rowHeight + (n - 1) * rowSpacing
  }
  readonly property int searchCardHeight:
    contentMargin * 2 + headerHeight + contentSpacing + visibleRowsHeight + contentSpacing + footerHeight
  readonly property int editCardHeight:
    contentMargin * 2 + editColumn.implicitHeight
  readonly property int cardHeight: Math.min(
    mode === "edit" ? editCardHeight : searchCardHeight,
    panel.height - Style.gapsOut * 2)

  // --- open / close (the shell's overlay contract) ----------------------

  function open(payloadJson) {
    if (root.mode === "edit") root.resetEditor()
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
    if (root.mode === "edit") root.resetEditor()
  }

  function dismiss() {
    root.opened = false
    if (root.mode === "edit") root.resetEditor()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // No IpcHandler here on purpose: the shell already exposes
  // `omarchy-shell shell toggle|summon|hide hegjon.passwordstore`
  // for every overlay, and an IpcHandler inside a hot-reloaded plugin has
  // crashed Quickshell when a reload raced a shell restart.

  // --- filtering --------------------------------------------------------

  // Every whitespace-separated token must match; a token matches as a
  // substring first and as an in-order subsequence second, so "ghb" still
  // finds "web/github.com" while plain substrings rank above it. Ties are
  // broken by how early the match begins, then by the store's own order.
  function scoreEntry(name, tokens) {
    var lower = name.toLowerCase()
    var parts = splitName(lower)
    var score = 0
    for (var t = 0; t < tokens.length; t++) {
      var token = tokens[t]
      var at = lower.indexOf(token)
      if (at >= 0) {
        score += 1000 - at
        if (parts.title.indexOf(token) === 0) score += 500          // name starts with it
        else if (parts.username.indexOf(token) === 0) score += 300  // username starts with it
        else if (parts.title.indexOf(token) >= 0) score += 200      // somewhere in the name
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

  // With usernameInPath an entry is stored as name/username
  // (github.com/jack): the last path segment is the username, whatever is
  // before it the application, website or account name. Without it the
  // last segment is the entry (pass's classic web/github.com) and the row
  // shows the folder under it; the username is only inside the file.
  function splitName(name) {
    var slash = name.lastIndexOf("/")
    if (usernameInPath) {
      var user = slash >= 0 ? name.slice(slash + 1) : ""
      return { name: name, title: slash >= 0 ? name.slice(0, slash) : name, username: user, subtitle: user }
    }
    return { name: name, title: slash >= 0 ? name.slice(slash + 1) : name, username: "", subtitle: slash >= 0 ? name.slice(0, slash) : "" }
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

  // Quickshell has no clipboard API; a hidden TextInput's paste() reads the
  // Qt clipboard for us. One line of it, whitespace collapsed, joins the
  // query.
  function pasteIntoFilter() {
    clipboardProbe.text = ""
    clipboardProbe.paste()
    var pasted = clipboardProbe.text.replace(/\s+/g, " ").trim()
    clipboardProbe.text = ""
    if (pasted !== "") setFilter(filterText + pasted)
  }

  TextInput { id: clipboardProbe; visible: false; width: 0; height: 0 }

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
    if (actionProcess.running) return
    var name = entry ? String(entry.name) : ""
    // The card's own editor for new entries and edits; `pass edit` in a
    // terminal stays available (Alt+Shift+E) for an entry in some other format.
    if (action === "edit") { if (name) openEditor(entry); return }
    if (action === "insert") { openEditor(null, name); return }
    if (action === "edit-terminal") action = "edit"
    if (!name) return
    if ((action === "type-password" || action === "type-username") && !allowTyping) return
    if (action === "copy-otp" && !otpAvailable) return

    var command = [actionPath, action, name,
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

  // Alt+N: the query, if any, becomes the new entry's name.
  function insertNew(action) {
    var typed = filterText.trim()
    runAction(action, typed !== "" ? ({ name: typed }) : null)
  }

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

  // --- the editor ---------------------------------------------------------

  // The entry being edited ("" for a new one) and the parts of it that are
  // not in a field: timestamps and the key: value lines the editor does not
  // know (a url:, an otpauth:// line), which are written back as they were.
  property string editEntry: ""
  property string editCreated: ""
  property string editModified: ""
  property var editExtra: []
  property bool editRevealed: false
  property bool editReading: false     // decrypting: the card hides so pinentry can have the keyboard
  // The name and username as read, so an unchanged entry is saved under
  // its own path even when that path is not name/username.
  property string editOrigTitle: ""
  property string editOrigUser: ""
  property string editError: ""
  property string readBuffer: ""
  property string savePayload: ""

  // Generator options; the defaults make a 20-character password from all
  // four classes, which is what pass generate would do as well.
  property int genLength: 20
  property bool genLower: true
  property bool genUpper: true
  property bool genDigits: true
  property bool genSymbols: true

  // One colour per character class when the password is revealed: letters
  // in the text colour, capitals blue, digits orange, symbols pink, in
  // shades that read on the theme's light or dark surface. The generator's
  // class buttons wear the same colours, which makes them the legend.
  readonly property bool darkSurface: background.hslLightness < 0.5
  readonly property color upperColor: darkSurface ? "#8fc7ff" : "#1a5fb4"
  readonly property color digitColor: darkSurface ? "#ffb86c" : "#a85400"
  readonly property color symbolColor: darkSurface ? "#ff8fa3" : "#b3123f"

  function classColor(ch) {
    if (ch >= "a" && ch <= "z") return foreground
    if (ch >= "A" && ch <= "Z") return upperColor
    if (ch >= "0" && ch <= "9") return digitColor
    return symbolColor
  }

  // Rich text for the revealed password: every character wrapped in its
  // class colour, the few characters HTML cares about escaped, spaces kept.
  function colorize(text) {
    var out = ""
    for (var i = 0; i < text.length; i++) {
      var ch = text[i]
      var shown = ch === "&" ? "&amp;" : ch === "<" ? "&lt;" : ch === ">" ? "&gt;" : ch === " " ? "&nbsp;" : ch
      out += "<font color=\"" + String(classColor(ch)).slice(0, 7) + "\">" + shown + "</font>"
    }
    return out
  }

  function formatStamp(stamp) {
    var s = String(stamp || "")
    return s.length >= 16 ? s.slice(0, 16).replace("T", " ") : s
  }

  property bool deleteConfirm: false

  readonly property string editTitle: editEntry === "" ? "New entry" : "Edit entry"
  readonly property bool editCanSave: !editReading && !genProcess.running && !saveProcess.running
    && nameField.text.trim() !== "" && passwordField.text !== ""

  // Open the editor: blank for a new entry (the query as the name, if any),
  // or decrypting an existing one first.
  function openEditor(entry, presetName) {
    if (editReading) return
    mode = "edit"
    editEntry = entry ? String(entry.name) : ""
    editCreated = ""
    editModified = ""
    editExtra = []
    editRevealed = false
    editError = ""
    deleteConfirm = false
    editOrigTitle = ""
    editOrigUser = ""
    if (entry) {
      var parts = splitName(String(entry.name))
      // Classic layout: the whole path is the name, the file has the username.
      nameField.text = usernameInPath ? parts.title : String(entry.name)
      usernameField.text = parts.username
      editOrigTitle = nameField.text
      editOrigUser = parts.username
    } else {
      var preset = String(presetName || "")
      var slash = usernameInPath ? preset.lastIndexOf("/") : -1
      nameField.text = slash > 0 ? preset.slice(0, slash) : preset
      usernameField.text = slash > 0 ? preset.slice(slash + 1) : ""
    }
    passwordField.text = ""
    notesArea.text = ""
    if (entry) {
      editReading = true
      readBuffer = ""
      var command = [actionPath, "read", String(entry.name), "--username-keys", usernameKeys]
      if (storeDir !== "") command.push("--store", storeDir)
      readProcess.command = command
      readProcess.running = true
    } else {
      Qt.callLater(function() { nameField.forceActiveFocus() })
    }
  }

  // Everything typed into the editor goes, the password first. savePayload
  // is not touched: saveEntry dismisses the card before the process has
  // started, and onStarted still has to write it.
  function resetEditor() {
    passwordField.text = ""
    notesArea.text = ""
    nameField.text = ""
    usernameField.text = ""
    readBuffer = ""
    editExtra = []
    editEntry = ""
    editRevealed = false
    editError = ""
    deleteConfirm = false
    mode = "search"
  }

  // Delete asks first: Alt+D (or the button) turns the legend into the
  // question and the primary button into "Yes, delete"; Esc keeps the entry.
  function askDelete() {
    if (editEntry === "" || editReading) return
    deleteConfirm = true
    editError = ""
  }

  function deleteEntry() {
    if (!deleteConfirm || editEntry === "") return
    var command = [actionPath, "delete", editEntry]
    if (storeDir !== "") command.push("--store", storeDir)
    if (!notifyOnCopy) command.push("--quiet")
    deleteProcess.command = command
    dismiss()
    deleteProcess.running = true
  }

  Process {
    id: deleteProcess
    running: false
    command: []
    stderr: StdioCollector { id: deleteStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("passwordstore: delete failed:", String(deleteStderr.text || "").replace(/\s+/g, " ").trim() || ("exit " + exitCode))
      else root.refresh()
    }
  }

  function leaveEditor() {
    if (editReading) return
    resetEditor()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function applyRead(text) {
    var parsed
    try { parsed = JSON.parse(String(text || "")) } catch (error) { parsed = null }
    if (!parsed || typeof parsed !== "object") { editError = "The helper returned something unreadable"; return }
    passwordField.text = String(parsed.password || "")
    // The decrypted username is the truth. When it disagrees with the last
    // path segment (a classic web/github.com with a login: line inside), the
    // whole path is the name and the segment is not a username; saving
    // without edits then keeps that path, and any edit moves the entry to
    // name/username.
    var inside = String(parsed.username || "")
    if (inside !== "" && inside !== usernameField.text) {
      nameField.text = editEntry
      usernameField.text = inside
      editOrigTitle = editEntry
      editOrigUser = inside
    } else if (usernameField.text === "" && inside !== "") {
      usernameField.text = inside
      editOrigUser = inside
    }
    notesArea.text = String(parsed.notes || "")
    editCreated = String(parsed.created || "")
    editModified = String(parsed.modified || "")
    editExtra = Array.isArray(parsed.extra) ? parsed.extra.map(function(l) { return String(l) }) : []
  }

  Process {
    id: readProcess
    running: false
    command: []
    // Chunks are gathered in readBuffer and cleared after parsing; a
    // StdioCollector would keep the decrypted JSON around until the next run.
    stdout: SplitParser { splitMarker: ""; onRead: function(data) { root.readBuffer += data } }
    stderr: StdioCollector { id: readStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var text = root.readBuffer
      root.readBuffer = ""
      root.editReading = false
      if (root.mode !== "edit" || !root.opened) return
      if (exitCode === 0) root.applyRead(text)
      else root.editError = String(readStderr.text || "").replace(/\s+/g, " ").trim() || ("Could not read " + root.editEntry)
      Qt.callLater(function() { passwordField.forceActiveFocus() })
    }
  }

  function generatePassword() {
    if (genProcess.running || editReading) return
    var classes = []
    if (genLower) classes.push("lower")
    if (genUpper) classes.push("upper")
    if (genDigits) classes.push("digit")
    if (genSymbols) classes.push("symbol")
    if (classes.length === 0) { editError = "Pick at least one character class"; return }
    editError = ""
    genProcess.command = [actionPath, "generate-password", "", "--length", String(genLength), "--classes", classes.join(",")]
    genProcess.running = true
  }

  Process {
    id: genProcess
    running: false
    command: []
    stdout: SplitParser { onRead: function(data) { if (root.mode === "edit") passwordField.text = String(data) } }
    stderr: StdioCollector { id: genStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.editError = String(genStderr.text || "").replace(/\s+/g, " ").trim() || "Could not generate a password"
    }
  }

  function validEntryName(name) {
    return name !== "" && name[0] !== "-" && name[0] !== "/" && name[name.length - 1] !== "/"
      && name.indexOf("..") < 0 && name.indexOf("//") < 0
  }

  // Save: the entry's name is name/username, the content goes to the
  // helper's stdin as JSON, and the card closes like it does for every other
  // action; the helper notifies when it is done (or not).
  function saveEntry() {
    if (!editCanSave) return
    var title = nameField.text.trim().replace(/^\/+|\/+$/g, "")
    var user = usernameField.text.trim()
    if (user.indexOf("/") >= 0) { editError = "A username cannot contain a slash"; return }
    var unchanged = editEntry !== "" && title === editOrigTitle && user === editOrigUser
    var name = unchanged || !usernameInPath ? (editEntry !== "" ? editEntry : title)
      : (user !== "" ? title + "/" + user : title)
    // Classic layout: a renamed entry keeps its username inside the file.
    if (!usernameInPath && editEntry !== "" && title !== editOrigTitle) name = title
    if (!validEntryName(name)) { editError = "That name will not do as a pass entry"; return }
    if (name !== editEntry && entries.indexOf(name) >= 0) { editError = "There is already an entry named " + name; return }
    var payload = {
      password: passwordField.text,
      username: user,
      notes: notesArea.text,
      extra: editExtra,
      created: editCreated
    }
    var command = [actionPath, "save", name, "--recent", recentFile, "--username-keys", usernameKeys]
    if (storeDir !== "") command.push("--store", storeDir)
    if (editEntry !== "" && editEntry !== name) command.push("--from", editEntry)
    // A new name must be new on disk as well; the listing could be stale.
    if (name !== editEntry) command.push("--no-overwrite")
    if (!notifyOnCopy) command.push("--quiet")
    savePayload = JSON.stringify(payload)
    payload = null
    saveProcess.command = command
    dismiss()
    saveProcess.stdinEnabled = true
    saveProcess.running = true
  }

  Process {
    id: saveProcess
    running: false
    command: []
    stdinEnabled: true
    stderr: StdioCollector { id: saveStderr; waitForEnd: true }
    // The payload is written once the process is up, then stdin is closed
    // so pass sees the end of the entry; the copy held here goes with it.
    onStarted: {
      saveProcess.write(root.savePayload + "\n")
      root.savePayload = ""
      saveProcess.stdinEnabled = false
    }
    // A process that never starts still exits (with -1), so the payload is
    // cleared on either path; nothing else holds the entry once the fields
    // are wiped.
    onExited: function(exitCode) {
      root.savePayload = ""
      if (exitCode !== 0) console.warn("passwordstore: save failed:", String(saveStderr.text || "").replace(/\s+/g, " ").trim() || ("exit " + exitCode))
      else root.refresh()
    }
  }

  // Keys the editor answers to after the focused field has had its turn.
  function editKey(event) {
    var ctrl = event.modifiers & Qt.ControlModifier
    var alt = event.modifiers & Qt.AltModifier
    if (event.key === Qt.Key_Escape) {
      if (deleteConfirm) deleteConfirm = false
      else leaveEditor()
      return true
    }
    if (editReading) return false
    if (deleteConfirm && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { deleteEntry(); return true }
    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && ctrl) { saveEntry(); return true }
    if (ctrl && event.key === Qt.Key_S) { saveEntry(); return true }
    if (alt && event.key === Qt.Key_D) { askDelete(); return true }
    if (alt && event.key === Qt.Key_R) { editRevealed = !editRevealed; return true }
    if (alt && event.key === Qt.Key_G) { generatePassword(); return true }
    return false
  }

  // --- the card ---------------------------------------------------------

  // Every Text that can show an entry name, the query or helper output is
  // PlainText. Qt's default AutoText sniffs for HTML, and a store entry named
  // like <img src="…"> (a synced store is not necessarily one's own doing)
  // would otherwise be rendered as rich text and fetch what it points at.

  readonly property string hintText: {
    var hints = ["Enter copy password", "Alt+U username"]
    if (otpAvailable) hints.push("Alt+O OTP")
    if (allowTyping) hints.push("Ctrl+Enter type")
    hints.push("Alt+E edit", "Alt+N new")
    return hints.join("  ·  ")
  }

  component CardField: TextField {
    width: parent ? parent.width : implicitWidth
    foreground: root.foreground
    accent: root.selectedBackground
    font.family: root.fontFamily
  }

  component CardButton: Button {
    foreground: root.foreground
    accent: root.selectedBackground
    fontFamily: root.fontFamily
    bordered: true
  }

  component EditLabel: Text {
    width: parent ? parent.width : implicitWidth
    textFormat: Text.PlainText
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    topPadding: Style.space(2)
  }

  // A field of the editor: the editor's keys (Esc, Ctrl+Enter, Alt+R,
  // Alt+G) are answered before the field sees them, everything else is
  // typed into it.
  component EditField: CardField {
    Keys.onPressed: function(event) { if (root.editKey(event)) event.accepted = true }
  }

  PanelWindow {
    id: panel
    // Hidden, and the exclusive grab dropped, while an entry is being
    // decrypted for the editor: pinentry needs the keyboard then.
    visible: root.opened && !root.editReading
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-passwordstore"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: (root.opened && !root.editReading)
      ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
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

      // Editor keys arrive here after the focused text field, if any, has
      // had its turn; keyCatcher below lets them through in edit mode.
      Keys.onPressed: function(event) {
        if (root.mode === "edit" && root.editKey(event)) event.accepted = true
      }

      // Type-to-filter, as the menu does: there is no text field to focus,
      // every printable key extends the query. That rules out single-letter
      // shortcuts, so actions are Enter and modifier combinations.
      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.mode !== "search") return
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
          } else if (event.matches(StandardKey.Paste) || (shift && event.key === Qt.Key_Insert)) {
            // Ctrl+V, or the Shift+Insert Omarchy's clipboard picker types
            // after Super+V: the search line has no text field to take it.
            root.pasteIntoFilter(); event.accepted = true
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
            root.activateSelected(shift ? "edit-terminal" : "edit"); event.accepted = true
          } else if (alt && event.key === Qt.Key_N) {
            root.insertNew("insert"); event.accepted = true
          } else if (alt && event.key === Qt.Key_G) {
            // A new entry with a password already generated.
            root.insertNew("insert"); root.generatePassword(); event.accepted = true
          } else if (!ctrl && !alt && event.text && event.text.length === 1
                     && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      // ---------------------------------------------------------- search

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing
        visible: root.mode === "search"

        // The query line, in the menu's heading style; the count at the right.
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
            textFormat: Text.PlainText
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
            textFormat: Text.PlainText
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
                  text: row.modelData.title
                  textFormat: Text.PlainText
                  color: row.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.weight: Font.Medium
                  elide: Text.ElideLeft
                }

                Text {
                  width: parent.width
                  visible: row.modelData.subtitle !== ""
                  text: row.modelData.subtitle
                  textFormat: Text.PlainText
                  color: row.hasCursor ? root.selectedText : root.foreground
                  opacity: 0.52
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: root.usernameInPath ? Text.ElideRight : Text.ElideLeft
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
              textFormat: Text.PlainText
              text: root.lastError !== ""
                ? root.lastError
                : (!root.initialized
                   ? "Reading the store…"
                   : (root.entries.length === 0
                      ? "The store is empty. Alt+N adds an entry."
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
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ---------------------------------------------------------- editor

      Column {
        id: editColumn
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.space(6)
        visible: root.mode === "edit"

        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.editTitle + (root.editEntry !== "" ? "  ·  " + root.editEntry : "")
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideLeft
          }
        }

        EditLabel { text: "Application, website or account" }
        EditField {
          id: nameField
          placeholderText: "github.com"
          KeyNavigation.tab: usernameField
          KeyNavigation.backtab: notesArea
          onAccepted: usernameField.forceActiveFocus()
        }

        EditLabel { text: "Username" }
        EditField {
          id: usernameField
          placeholderText: "jack@example.com"
          KeyNavigation.tab: passwordField
          KeyNavigation.backtab: nameField
          onAccepted: passwordField.forceActiveFocus()
        }

        EditLabel { text: "Password" }
        Item {
          width: parent.width
          height: Math.max(passwordField.implicitHeight, revealButton.implicitHeight)

          // Masked like the lock screen's field; revealed, the field's own
          // text turns transparent and the coloured copy is drawn over it,
          // in the same monospace font so the two line up glyph for glyph.
          EditField {
            id: passwordField
            anchors.left: parent.left
            anchors.right: revealButton.left
            anchors.rightMargin: Style.spacing.controlGap
            anchors.verticalCenter: parent.verticalCenter
            password: !root.editRevealed
            passwordCharacter: "\u2022"
            font.family: Style.font.family
            color: root.editRevealed ? "transparent" : root.foreground
            selectedTextColor: root.editRevealed ? "transparent" : root.foreground
            placeholderText: root.editReading ? "Decrypting…" : "Type or paste, or generate one"
            cursorDelegate: Rectangle {
              width: Math.max(1, Style.space(1))
              color: root.foreground
              visible: passwordField.cursorVisible
            }
            // Tab skips the generator controls (they are mouse and Alt+G
            // territory) and lands in the notes.
            KeyNavigation.tab: notesArea
            KeyNavigation.backtab: usernameField
            onAccepted: notesArea.forceActiveFocus()
          }
          Text {
            visible: root.editRevealed
            x: passwordField.x + passwordField.leftPadding
            anchors.verticalCenter: passwordField.verticalCenter
            width: Math.max(0, passwordField.width - passwordField.leftPadding - passwordField.rightPadding)
            clip: true
            text: root.colorize(passwordField.text)
            textFormat: Text.RichText
            font.family: passwordField.font.family
            font.pixelSize: passwordField.font.pixelSize
          }
          CardButton {
            id: revealButton
            anchors.right: generateButton.left
            anchors.rightMargin: Style.spacing.controlGap
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.editRevealed ? root.eyeOffGlyph : root.eyeGlyph
            tooltipText: root.editRevealed ? "Hide (Alt+R)" : "Reveal (Alt+R)"
            selected: root.editRevealed
            onClicked: root.editRevealed = !root.editRevealed
          }
          CardButton {
            id: generateButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Generate"
            tooltipText: "Alt+G"
            onClicked: root.generatePassword()
          }
        }

        // Generator options; the class buttons double as the colour legend.
        Row {
          width: parent.width
          spacing: Style.spacing.controlGap

          NumberField {
            anchors.verticalCenter: parent.verticalCenter
            label: "Length"
            from: 4
            to: 128
            value: root.genLength
            foreground: root.foreground
            accent: root.selectedBackground
            fontFamily: root.fontFamily
            onModified: function(value) { root.genLength = value }
            Component.onCompleted: field.activeFocusOnTab = false
          }
          CardButton {
            anchors.verticalCenter: parent.verticalCenter
            text: "a-z"
            selected: root.genLower
            opacity: root.genLower ? 1 : 0.5
            onClicked: root.genLower = !root.genLower
          }
          CardButton {
            anchors.verticalCenter: parent.verticalCenter
            text: "A-Z"
            foreground: root.upperColor
            selected: root.genUpper
            opacity: root.genUpper ? 1 : 0.5
            onClicked: root.genUpper = !root.genUpper
          }
          CardButton {
            anchors.verticalCenter: parent.verticalCenter
            text: "0-9"
            foreground: root.digitColor
            selected: root.genDigits
            opacity: root.genDigits ? 1 : 0.5
            onClicked: root.genDigits = !root.genDigits
          }
          CardButton {
            anchors.verticalCenter: parent.verticalCenter
            text: "#!?"
            foreground: root.symbolColor
            selected: root.genSymbols
            opacity: root.genSymbols ? 1 : 0.5
            onClicked: root.genSymbols = !root.genSymbols
          }
        }

        EditLabel { text: "Notes" }
        BorderSurface {
          id: notesSurface
          width: parent.width
          height: Style.space(88)
          radius: Style.cornerRadius
          color: Style.controlFill(notesArea.activeFocus, notesArea.hovered, root.foreground, root.selectedBackground)
          borderSpec: Border.controlSpec(notesArea.activeFocus ? "focus" : (notesArea.hovered ? "hover-cursor" : "normal"), root.foreground, root.selectedBackground)

          Flickable {
            id: notesFlick
            anchors.fill: parent
            anchors.margins: Math.max(1, Style.space(2))
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            QQC.TextArea.flickable: QQC.TextArea {
              id: notesArea
              wrapMode: TextEdit.Wrap
              textFormat: TextEdit.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              color: root.foreground
              selectionColor: root.selectedBackground
              selectedTextColor: root.foreground
              placeholderText: "Notes, recovery codes, anything else"
              placeholderTextColor: Qt.darker(root.foreground, 1.6)
              leftPadding: Style.spacing.controlPaddingX
              rightPadding: Style.spacing.controlPaddingX
              topPadding: Style.spacing.inputPaddingY
              bottomPadding: Style.spacing.inputPaddingY
              background: null
              // Tab is a field hop here, not a character.
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Tab) { nameField.forceActiveFocus(); event.accepted = true }
                else if (event.key === Qt.Key_Backtab) { passwordField.forceActiveFocus(); event.accepted = true }
                else if (root.editKey(event)) event.accepted = true
              }
            }
            QQC.ScrollBar.vertical: QQC.ScrollBar {}
          }
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: {
            var bits = []
            if (root.editCreated !== "") bits.push("Created " + root.formatStamp(root.editCreated))
            if (root.editModified !== "") bits.push("Modified " + root.formatStamp(root.editModified))
            if (root.editExtra.length > 0) {
              var keys = root.editExtra.map(function(l) { return l.split(":")[0] })
              bits.push("Kept as is: " + keys.join(", "))
            }
            return bits.join("  ·  ")
          }
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          visible: root.editError !== "" || root.deleteConfirm
          text: root.deleteConfirm
            ? "Delete " + root.editEntry + "? It is removed from the store; pass keeps no copy."
            : root.editError
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // Legend full width, then Cancel / Save.
        Column {
          width: parent.width
          spacing: Style.space(8)
          topPadding: Style.space(4)

          Text {
            id: editHint
            width: parent.width
            text: root.deleteConfirm
              ? "Enter delete  ·  Esc keep"
              : "Tab fields  ·  Ctrl+Enter save  ·  Alt+R reveal  ·  Alt+G generate" + (root.editEntry !== "" ? "  ·  Alt+D delete" : "") + "  ·  Esc back"
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Item {
            width: parent.width
            height: editButtons.implicitHeight

            CardButton {
              anchors.left: parent.left
              visible: root.editEntry !== "" && !root.deleteConfirm
              text: "Delete"
              foreground: Color.urgent
              onClicked: root.askDelete()
            }
            Row {
              id: editButtons
              anchors.right: parent.right
              spacing: Style.spacing.controlGap

              CardButton {
                text: root.deleteConfirm ? "Keep" : "Cancel"
                onClicked: root.deleteConfirm ? (root.deleteConfirm = false) : root.leaveEditor()
              }
              CardButton {
                visible: root.deleteConfirm
                text: "Yes, delete"
                foreground: Color.urgent
                selected: true
                onClicked: root.deleteEntry()
              }
              CardButton {
                visible: !root.deleteConfirm
                text: root.editEntry !== "" ? "Save" : "Add"
                selected: root.editCanSave
                opacity: root.editCanSave ? 1 : 0.5
                onClicked: root.saveEntry()
              }
            }
          }
        }
      }

    }
  }
}
