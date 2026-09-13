import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The passphrase card for pinentry-omarchy: the polkit prompt's shape (a
// glyph, one big masked field, the reason in a pill above), drawn with the
// shell's tokens so it looks like the rest of Omarchy. What was asked for
// arrives in PINENTRY_OMARCHY_REQUEST (no secrets in it); the answer goes
// back over the unix socket in PINENTRY_OMARCHY_SOCKET as one JSON object,
// then the process quits. Commons and Ui are symlinks to the shell's.
ShellRoot {
  id: root

  readonly property var request: {
    try { return JSON.parse(Quickshell.env("PINENTRY_OMARCHY_REQUEST") || "{}") } catch (e) { return ({}) }
  }
  readonly property string mode: String(request.mode || "getpin")
  readonly property string description: String(request.description || "")
  readonly property string errorText: String(request.error || "")
  readonly property string promptText: String(request.prompt || "Passphrase:").replace(/:\s*$/, "")
  readonly property string repeatText: String(request.repeat || "")
  readonly property string okLabel: String(request.ok || "OK")
  readonly property string cancelLabel: String(request.cancel || "Cancel")
  readonly property string notokLabel: String(request.notok || "")
  readonly property bool oneButton: !!request.oneButton
  readonly property bool wantsPin: mode === "getpin"

  property string fontFamily: Style.font.menuFamily
  property color accent: Color.polkit.accent
  property color background: Color.polkit.background
  property color foreground: Color.polkit.text
  property color border: Color.polkit.border
  property color scrim: Color.polkit.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int fieldHeight: Math.max(Style.space(42), Style.spacing.controlHeight)
  property bool revealed: false
  property bool mismatch: false
  property bool done: false

  // Wider when gpg has something to say ("Bad Passphrase (try 2 of 3)").
  readonly property int cardWidth: Math.min(Style.space(errorText !== "" || mismatch ? 460 : 360), Math.max(Style.space(260), panel.width - Style.gapsOut * 2))
  readonly property int cardHeight: {
    var h = contentMargin * 2
    if (wantsPin) h += fieldHeight + (repeatText !== "" ? fieldHeight + Style.space(6) : 0)
    else h += buttonRow.implicitHeight
    return h
  }

  function finish(result) {
    if (done) return
    done = true
    resultSocket.pending = JSON.stringify(result)
    resultSocket.connected = true
  }

  function submit() {
    if (!wantsPin) { finish({ ok: true }); return }
    if (repeatText !== "" && repeatInput.text !== pinInput.text) {
      mismatch = true
      repeatInput.text = ""
      repeatInput.forceActiveFocus()
      return
    }
    finish({ ok: true, pin: pinInput.text })
    pinInput.text = ""
    repeatInput.text = ""
  }

  function cancel() { finish({ ok: false }) }

  Socket {
    id: resultSocket
    property string pending: ""
    path: Quickshell.env("PINENTRY_OMARCHY_SOCKET")
    connected: false
    onConnectedChanged: {
      if (!connected) return
      write(pending)
      pending = ""
      flush()
      quitTimer.start()
    }
    onError: quitTimer.start()
  }

  Timer {
    id: quitTimer
    interval: 150
    onTriggered: Qt.quit()
  }

  // No socket to answer on: nothing to do but leave.
  Component.onCompleted: {
    if (!Quickshell.env("PINENTRY_OMARCHY_SOCKET")) Qt.quit()
  }

  PanelWindow {
    id: panel
    visible: !root.done
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-pinentry"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: if (root.wantsPin) pinInput.forceActiveFocus()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.surfaceSpec("polkit", root.mismatch || root.errorText !== "" ? "border-error" : "border",
        root.mismatch || root.errorText !== "" ? Color.polkit.borderError : root.border, Math.max(1, Style.space(2)), "border-alpha")
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: if (root.wantsPin) pinInput.forceActiveFocus() }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: !root.wantsPin

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.cancel(); event.accepted = true }
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.submit(); event.accepted = true }
          else if ((event.modifiers & Qt.AltModifier) && event.key === Qt.Key_R && root.wantsPin) { root.revealed = !root.revealed; event.accepted = true }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.space(6)

        // The passphrase, masked like the lock screen's; Alt+R shows it.
        Row {
          width: parent.width
          height: root.fieldHeight
          visible: root.wantsPin
          spacing: Style.space(14)

          Text {
            text: String.fromCodePoint(0xF0306)   // nf-md-key
            color: root.mismatch || root.errorText !== "" ? Color.polkit.textError : root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            width: Style.space(26)
            height: root.fieldHeight
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
          }

          Item {
            width: parent.width - Style.space(40)
            height: root.fieldHeight

            TextInput {
              id: pinInput
              anchors.fill: parent
              verticalAlignment: TextInput.AlignVCenter
              activeFocusOnPress: true
              focus: root.wantsPin
              clip: true
              selectionColor: Util.alpha(root.accent, 0.45)
              selectedTextColor: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
              echoMode: root.revealed ? TextInput.Normal : TextInput.Password
              passwordCharacter: "•"
              color: root.foreground
              cursorVisible: activeFocus
              onAccepted: root.repeatText !== "" ? repeatInput.forceActiveFocus() : root.submit()
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) { root.cancel(); event.accepted = true }
                else if ((event.modifiers & Qt.AltModifier) && event.key === Qt.Key_R) { root.revealed = !root.revealed; event.accepted = true }
                else if (event.key === Qt.Key_Tab && root.repeatText !== "") { repeatInput.forceActiveFocus(); event.accepted = true }
              }
            }

            Text {
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.errorText !== "" ? root.errorText : root.promptText
              color: root.errorText !== "" ? Color.polkit.textError : root.foreground
              opacity: root.errorText !== "" ? 1 : 0.36
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
              elide: Text.ElideRight
              visible: pinInput.text.length === 0
            }

            Rectangle {
              width: Math.max(1, Style.space(2))
              height: Style.space(24)
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              color: root.foreground
              visible: pinInput.activeFocus && pinInput.text.length === 0
            }
          }
        }

        // A second field when gpg wants the new passphrase twice.
        Row {
          width: parent.width
          height: root.fieldHeight
          visible: root.wantsPin && root.repeatText !== ""
          spacing: Style.space(14)

          Text {
            text: String.fromCodePoint(0xF0306)
            color: root.mismatch ? Color.polkit.textError : root.accent
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            width: Style.space(26)
            height: root.fieldHeight
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
          }

          Item {
            width: parent.width - Style.space(40)
            height: root.fieldHeight

            TextInput {
              id: repeatInput
              anchors.fill: parent
              verticalAlignment: TextInput.AlignVCenter
              activeFocusOnPress: true
              clip: true
              selectionColor: Util.alpha(root.accent, 0.45)
              selectedTextColor: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
              echoMode: root.revealed ? TextInput.Normal : TextInput.Password
              passwordCharacter: "•"
              color: root.mismatch ? Color.polkit.textError : root.foreground
              cursorVisible: activeFocus
              onAccepted: root.submit()
              onTextChanged: root.mismatch = false
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) { root.cancel(); event.accepted = true }
                else if ((event.modifiers & Qt.AltModifier) && event.key === Qt.Key_R) { root.revealed = !root.revealed; event.accepted = true }
                else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Tab) { pinInput.forceActiveFocus(); event.accepted = true }
              }
            }

            Text {
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.mismatch ? String(root.request.repeatError || "Passphrases do not match") : root.repeatText.replace(/:\s*$/, "")
              color: root.mismatch ? Color.polkit.textError : root.foreground
              opacity: root.mismatch ? 1 : 0.36
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
              elide: Text.ElideRight
              visible: repeatInput.text.length === 0
            }
          }
        }

        // Confirmations and messages: the buttons are the whole card.
        Row {
          id: buttonRow
          anchors.right: parent.right
          visible: !root.wantsPin
          spacing: Style.spacing.controlGap

          Button {
            visible: !root.oneButton
            text: root.cancelLabel
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.cancel()
          }
          Button {
            visible: !root.oneButton && root.notokLabel !== ""
            text: root.notokLabel
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.finish({ ok: false, notok: true })
          }
          Button {
            text: root.okLabel
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            bordered: true
            selected: true
            onClicked: root.submit()
          }
        }
      }
    }

    // What this is about (the key, the reason), in the polkit prompt's pill.
    Rectangle {
      visible: root.description !== "" || root.request.title
      width: Math.min(descriptionText.implicitWidth + Style.space(24), Style.space(640), panel.width - Style.gapsOut * 2)
      height: descriptionText.implicitHeight + Style.space(14)
      anchors.horizontalCenter: card.horizontalCenter
      anchors.bottom: card.top
      anchors.bottomMargin: Style.space(10)
      radius: root.cornerRadius
      color: root.background

      Text {
        id: descriptionText
        textFormat: Text.PlainText
        anchors.fill: parent
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(12)
        width: parent.width - Style.space(24)
        text: (root.request.title && root.request.title !== "Passphrase" ? String(root.request.title) + "\n" : "") + root.description
        wrapMode: Text.Wrap
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }

    // A hint under the card, as the legend under the search card.
    Text {
      visible: root.wantsPin
      anchors.horizontalCenter: card.horizontalCenter
      anchors.top: card.bottom
      anchors.topMargin: Style.space(8)
      text: "Enter " + root.okLabel.toLowerCase() + "  ·  Esc " + root.cancelLabel.toLowerCase() + "  ·  Alt+R " + (root.revealed ? "hide" : "show")
      textFormat: Text.PlainText
      color: root.foreground
      opacity: 0.45
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
