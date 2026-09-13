# Working notes for agents

Omarchy overlay + bar-widget plugin. This checkout *is* the installed plugin
(`~/.config/omarchy/plugins/hegjon.passwordstore`), so edits are live.

## Verifying changes

- `test/lint` (qmllint), `test/test-manifest`, `test/test-list`,
  `test/test-action`, `omarchy-plugin-validate .` and
  `shellcheck --severity=warning passwordstore-* test/test-*`.
- The shell hot-reloads on file change, but a QML *type* error (a bad
  component file) is cached until `omarchy-restart-shell`. Wait ~8 s after a
  restart, then `journalctl --user --since "30 sec ago" | grep -i passwordstore`.
- IPC: `omarchy-shell shell toggle|summon|hide hegjon.passwordstore` (the
  shell's generic overlay routing; the plugin registers no IpcHandler).
- The overlay is `keepLoaded`, so a hot reload does not always replace the
  live instance; `omarchy-restart-shell` before trusting a screenshot.
- UI testing without touching the real store: make a directory of empty
  `*.gpg` files, `omarchy bar set hegjon.passwordstore storeDir <dir>`, open
  the overlay, drive it with `wtype "git"` / `wtype -k Down`, screenshot with
  `grim -o HDMI-A-1` and `magick -crop`. The card is centered; on the
  3840×2160 monitor `1400x800+1220+680` frames it. Switch to an empty
  workspace first (`hyprctl dispatch 'hl.dsp.focus({ workspace = "9" })'`) so only
  the wallpaper is behind the card. Restore `storeDir ""`
  afterwards. `preview.png` is that crop.
- Settings are read by the overlay from `shell.shellConfig.bar.layout`
  (the widget's bar entry), with `manifest.barWidget.defaults` as fallback.
- The recent list is `~/.local/state/omarchy-passwordstore/recent`; the tests
  above leave fake names in it, so reset it after UI experiments.
- A real end-to-end copy: `./passwordstore-action copy-password <entry>
  --clip-time 5`. It decrypts, so gpg-agent may raise pinentry; run it under
  `timeout` when nobody is at the screen.

## Things that bit before

- `escape` is a reserved word in QML; a `function escape()` in a component
  makes the whole type unavailable ("Illegal method name").
- An `IpcHandler` in the overlay segfaulted Quickshell
  (`IpcHandler::updateRegistration` during `onPostReload`) when a plugin
  hot-reload raced an `omarchy-restart-shell`. No first-party overlay has one;
  neither does this plugin now. Save files, *then* wait, *then* restart.
- `pass -c` copies with a plain `wl-copy`, which Omarchy's clipboard history
  records. Every copy is therefore done by the helper: `wl-copy --sensitive`
  (the x-kde-passwordManagerHint type, which
  `/usr/share/omarchy/shell/plugins/clipboard/capture.sh` refuses), a
  sleeper that clears the clipboard after `clipTimeSec`, and a purge of
  `~/.local/state/omarchy/clipboard-history.json` (the shell watches that
  file) in case an older wl-copy let the value in. `pass show -cN` would
  also have copied the whole `login: alice` line.
- The clipboard sleeper is named (`exec -a "passwordstore clip sleep"` around
  `sleep & wait`, because bash execs a lone command and loses the name) so
  the next copy can `pkill` it and restart the timer, as pass does.
- The card is type-to-filter with no TextField (the menu's pattern), so
  single letters are never shortcuts; actions are Enter plus modifiers. `Util.editsFilter` claims Ctrl+U (clear) and Backspace.
- `--quiet` only suppresses the success notifications; failures always notify,
  because the popup is gone by the time the script runs.

## Style

- Comments explain *why*. Secrets never go through argv, `console.log`, or a
  QML property; keep it that way.
- Version lives in `manifest.json`.
