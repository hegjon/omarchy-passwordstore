# Working notes for agents

Omarchy overlay + bar-widget plugin. This checkout *is* the installed plugin
(`~/.config/omarchy/plugins/hegjon.passwordstore`), so edits are live.

## Verifying changes

- `test/lint` (qmllint), `test/test-manifest`, `test/test-list`,
  `test/test-action`, `test/test-setup`, `test/test-pinentry`,
  `omarchy-plugin-validate .` and
  `shellcheck --severity=warning passwordstore-* test/test-*` (no shellcheck
  on this box: `npx -y shellcheck`).
- `test/test-setup` uses real git against a bare repo in a temp dir and
  stand-ins for `pass`, `gpg`, `rclone`, `omarchy`, `notify-send`; the
  terminal is replaced through `PASSWORDSTORE_TERMINAL` (a command that runs
  `bash -c SCRIPT` synchronously). Both helpers honour that hook.
- The shell hot-reloads on file change, but a QML *type* error (a bad
  component file) is cached until `omarchy-restart-shell`. Wait ~8 s after a
  restart, then `journalctl --user --since "30 sec ago" | grep -i passwordstore`.
- IPC: `omarchy-shell shell toggle|summon|hide hegjon.passwordstore`
  (the shell's generic overlay routing; the plugin registers no IpcHandler).
- The overlay is `keepLoaded`, so a hot reload does not always replace the
  live instance; `omarchy-restart-shell` before trusting a screenshot.
- UI testing without touching a real store: make a directory of empty
  `*.gpg` files plus a `.gpg-id`, point a vault at it
  (`omarchy bar set hegjon.passwordstore vaults '[{"id":"t","name":"T","storeDir":"<dir>"}]' --json`),
  open the overlay, drive it with `wtype "git"` / `wtype -k Down` / `wtype -k F2`,
  screenshot with `grim -o HDMI-A-1` and `magick -crop`. The card is centered;
  on the 3840×2160 monitor `1400x800+1220+680` frames it, on rig2's
  3440×1440 one a seven-row store's card is exactly `428x492+1506+474`
  (preview.png is that crop, so nothing behind the card is in it). Switch to an empty
  workspace first (`hyprctl dispatch 'hl.dsp.focus({ workspace = "9" })'`) so
  only the wallpaper is behind the card. Restore the settings afterwards.
  `preview.png` is that crop.
- Settings are read by the overlay from `shell.shellConfig.bar.layout` (the
  widget's bar entry) with `manifest.barWidget.defaults` as fallback, and
  written with `shell.pluginRegistry.setBarWidget(id, key, value, {})`, the
  same path as `omarchy bar set`. The widget must be on the bar for a save to
  succeed; the wizard says so otherwise.
- `passwordstore-setup` reads the same entry from `shell.json` itself
  (`$XDG_CONFIG_HOME/omarchy/shell.json`), picks the vault by `--vault` /
  `activeVaultId` / first, and falls back to the entry's own keys when
  `vaults` is empty (the pre-vault single store, which the card calls
  `personal`). Options given on the command line win.
- The recent lists are `~/.local/state/omarchy-passwordstore/recent` (vault
  `personal`) and `recent-<id>`; the tests above leave fake names in them,
  so reset them after UI experiments.
- A real end-to-end copy: `./passwordstore-action copy-password <entry>
  --clip-time 5`. It decrypts, so gpg-agent may raise pinentry; run it under
  `timeout` when nobody is at the screen.

- `pinentry-omarchy` can be tried without touching the real agent: a
  throwaway `GNUPGHOME` with `pinentry-program <path>` in its
  `gpg-agent.conf`, a key made with `--pinentry-mode loopback --passphrase`,
  then `gpg --decrypt` of something encrypted to it raises the card
  (`omarchy-pinentry` layer). `test/test-pinentry` drives the protocol with a
  stand-in prompt (`PINENTRY_OMARCHY_PROMPT`).
- The prompt's Quickshell config root is staged under
  `$XDG_RUNTIME_DIR/pinentry-omarchy/` with symlinks to the shell's
  `Commons`/`Ui`, because a plugin folder may not contain symlinks
  (`omarchy-plugin-validate` refuses them) and `qs.*` imports resolve from
  the config root.

- The lockout is three pieces: `pinentry-omarchy` keeps the count and the
  policy under `$XDG_RUNTIME_DIR/pinentry-omarchy/` (`--lockout-status`,
  `--unlock-failed`, `--unlock-ok`, `--set-policy`), `passwordstore-action`
  reports every decrypt's outcome and refuses while locked,
  `passwordstore-setup lockout-policy` copies the settings over and `status`
  carries `lockout`. The card ticks the remaining time itself and re-asks
  status when it reaches zero.

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
- The editor is the one place a password is in QML (the masked field, like
  the lock screen's). It reaches `passwordstore-action save` over the
  Process's stdin, written from `onStarted` and closed by setting
  `stdinEnabled = false`; `read` output is gathered through a `SplitParser`
  with an empty marker and the buffer cleared after parsing, because a
  `StdioCollector` keeps its text until the next run. `resetEditor()` wipes
  every field whenever the card leaves the editor, including on dismiss.
- Entries are `name/username` paths; `splitName` takes the last segment as
  the username. The file format `save` writes and `read` parses is in the
  helper's header comment; unknown `key: value` lines and `otpauth://` lines
  round-trip through `extra`. A classic `web/github.com` with a `login:`
  inside is handled on read: the decrypted username wins, the whole path
  becomes the name, and saving without edits keeps the path (an edit moves
  it to name/username). `--no-overwrite` guards a new name against an
  existing entry, since `pass insert -f` / `pass mv -f` would clobber it.
- The clipboard sleeper is named (`exec -a "passwordstore clip sleep"` around
  `sleep & wait`, because bash execs a lone command and loses the name) so
  the next copy can `pkill` it and restart the timer, as pass does.
- The search card is type-to-filter with no TextField (the menu's pattern),
  so single letters are never shortcuts there; actions are Enter plus
  modifiers, and `Tab` switches vaults. `Util.editsFilter` claims Ctrl+U
  (clear) and Backspace. The wizard pages *do* have single-letter keys and
  TextFields, and the editor has fields and `Ctrl`/`Alt` keys: `keyCatcher`
  ignores keys outside search mode so they bubble to the card's
  `Keys.onPressed`, after the focused field has had its turn (`EditField`
  and the notes area also run `editKey` first, so Esc and Ctrl+Enter work
  from inside a field).
- `--quiet` only suppresses the success notifications; failures always notify,
  because the popup is gone by the time the script runs.
- A helper that asks a question (rclone's "upload N entries?", init's
  "re-encrypt?") must `exit` after printing it. The first rclone version
  printed the question and then uploaded anyway; `test/test-setup` now checks
  that nothing ran.
- Terminal work is waited on through a status file the wrapper writes, not
  the terminal's exit: `setsid`/`uwsm-app` detach, and a shell restart must
  not kill a half-finished `gpg --full-generate-key`.

## Style

- Comments explain *why*. Secrets never go through argv, `console.log`,
  notifications or files outside the store; the only QML that holds one is
  the editor's password field, wiped on leave. Keep it that way. Entry names
  (which include usernames) and remote URLs are not secrets; custom sync
  commands are stored in `shell.json`, which is why the docs say not to put
  a secret in one.
- Version lives in `manifest.json`.
