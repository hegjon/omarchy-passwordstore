# Password Store for Omarchy

[pass](https://www.passwordstore.org/), the standard unix password manager, in
the [Omarchy](https://omarchy.org/) bar.

![Bar button and popup](preview.png)

- A key on the bar. Click it (or `omarchy-shell shell toggle hegjon.passwordstore`
  from a keybinding) and type to search your store; `ghb` finds
  `github.com/jack`.
- Each row is the site or account name with the username under it, and the
  search matches both.
- `Enter` copies the password, `Alt+U` the username, `Alt+O` a fresh OTP code
  (with [pass-otp](https://github.com/tadfisher/pass-otp)). `Ctrl+Enter` types
  the password into the window you came from, `Ctrl+Shift+Enter` the username.
- `Alt+N` adds an entry and `Alt+E` edits one, on the card: name, username,
  a masked password field that takes a paste, reveals with each character
  class in its own colour and generates one to your length and classes,
  notes, and when the entry was created and last changed.
- Recently used entries float to the top of an empty search.
- Search and copy decrypt nothing in the widget; every action is handed to
  `pass` itself, so gpg-agent prompts as it would from a terminal. What is
  copied carries the password-manager hint, so Omarchy's clipboard history
  never records it, and the clipboard is cleared again after 60 s
  (`clipTimeSec`). The editor is the one place a password is on screen.

## Install

```bash
omarchy plugin add https://github.com/hegjon/omarchy-passwordstore.git --enable
omarchy restart shell
```

If the bar widget is enabled but not visible, place it explicitly:

```bash
omarchy plugin enable hegjon.passwordstore --section right
omarchy restart shell
```

Update or remove:

```bash
omarchy plugin update hegjon.passwordstore --yes
omarchy plugin remove hegjon.passwordstore
```

Removing the plugin leaves your password store untouched (it is only ever read
through `pass`). If you want no trace left, also delete the recently-used list,
`~/.local/state/omarchy-passwordstore/`, and any keybinding you added below.

Needs `pass` (`omarchy pkg add pass`), `wl-clipboard` and `jq` (both part of
Omarchy), and `wtype` for the typing actions. `pass-otp` is optional; the OTP
action only appears when it is installed.

A keybinding is the natural way to reach it. In `~/.config/hypr/bindings.lua`
(`SUPER+P` is Omarchy's pseudo-window toggle by default, hence the unbind):

```lua
hl.unbind("SUPER + P")
o.bind("SUPER + P", "Password store", "omarchy-shell shell toggle hegjon.passwordstore")
```

The bar widget is still needed even if you only ever use the keybinding: its
bar entry is where the settings live.

## Keys

| Key                      | Action                                                   |
|--------------------------|----------------------------------------------------------|
| any printable            | Extend the search. `Backspace`, `Ctrl+Backspace`, `Ctrl+U` edit it; `Ctrl+V` / `Shift+Insert` paste into it |
| `↑` `↓` `Ctrl+J/K/N/P`   | Move the cursor; `PageUp/Down`, `Home`, `End` jump       |
| `Enter`                  | Copy the password; the clipboard clears after `clipTimeSec` and the history never sees it |
| `Alt+U` / `Alt+Enter`    | Copy the username                                        |
| `Alt+O`                  | Copy an OTP code (`pass otp`)                            |
| `Ctrl+Enter`             | Type the password into the focused window                |
| `Ctrl+Shift+Enter`       | Type the username                                        |
| `Alt+E`                  | Edit the entry on the card; `Alt+Shift+E` opens it in a terminal with `pass edit` instead |
| `Alt+N` / `Alt+G`        | Add an entry on the card (`Alt+G`: with a password already generated); the search text, if any, is the new entry's name |
| `F5`                     | Re-read the store (it is also re-read every time it opens) |
| `Esc`                    | Clear the search, then close                             |
| mouse                    | Left click copies the password, right click the username, middle click an OTP |

In the editor:

| Key                      | Action                                                   |
|--------------------------|----------------------------------------------------------|
| `Tab` / `Shift+Tab`      | Next / previous field; `Enter` in a field moves on too   |
| `Alt+R`                  | Reveal or hide the password. Revealed, lower-case letters are in the text colour, capitals blue, digits orange, symbols pink; the generator's class buttons are the legend |
| `Alt+G`                  | Generate a password with the length and classes chosen under the field |
| `Ctrl+Enter` / `Ctrl+S`  | Save (`pass insert -m`, and `pass mv` first if the name changed), then push if the vault syncs |
| `Alt+D`                  | Delete the entry (`pass rm`), after a question: `Enter` confirms, `Esc` keeps it |
| `Esc`                    | Back to the search, the form wiped                       |

`Ctrl+V` and `Shift+Insert` paste into any field, the password one included,
and into the search line; Omarchy's clipboard picker (`Super+V`) works in
both, since it types `Shift+Insert` once you pick an entry.

## Entries

An entry is stored as `<name>/<username>` (`github.com/jack`), which is the
usual pass layout, so the list can show both without decrypting anything and
the search finds `jack` as readily as `github`. An entry with no username is
just `<name>`. Inside, the editor writes:

```
<password>
username: jack
created: 2026-09-06T10:12:00-04:00
modified: 2026-09-06T10:12:00-04:00
url: https://github.com          ← any other key: value line is kept as it was

<notes, free text>
```

Entries made by `pass insert` or another client work as they are: the
password is the first line, the username is the first `login:` / `user:` /
`username:` / `email:` line (`usernameKeys`) or, failing that, the bare
second line, and everything after the first blank line is notes. A classic
`web/github.com` with a `login:` inside shows `github.com` as its username
in the list (the list cannot decrypt), but the editor reads the real one
and keeps the path unless you change the name or username, which moves the
entry to `name/username`. A new name never overwrites an existing entry. A store laid out the classic
way throughout is happier with `usernameInPath` off (Settings): rows show
`folder` under `entry` as before, and nothing is ever read as a username. Lines the
editor does not know (`url:`, an `otpauth://` line for pass-otp) are kept,
and the card says so under the notes. `pass edit` in a terminal
(`Alt+Shift+E`) is there for anything else.


## Settings

Change them from the bar's widget settings, or with `omarchy bar set`:

```bash
omarchy bar set hegjon.passwordstore storeDir ~/.password-store-work
omarchy bar set hegjon.passwordstore clipTimeSec 30
omarchy bar set hegjon.passwordstore allowTyping false --json
```

| Key              | Default                      | Meaning                                                                 |
|------------------|------------------------------|-------------------------------------------------------------------------|
| `storeDir`       | *(empty)*                    | Store location. Empty means `$PASSWORD_STORE_DIR` or `~/.password-store`, as pass does. |
| `clipTimeSec`    | `60`                         | Seconds until a copied password, username or OTP code is cleared from the clipboard. The value is copied with the password-manager hint, so the clipboard history never records it; should an older `wl-copy` have let it in, it is removed from the history file at the same moment. Also `PASSWORD_STORE_CLIP_TIME` for `pass edit`. |
| `usernameKeys`   | `login,user,username,email`  | Field names that hold the username, matched case-insensitively.        |
| `usernameInPath` | `true`                       | Entries are `name/username` (the list shows both, the editor names new entries that way). `false` keeps pass's classic `folder/entry` layout: the row shows the folder under the entry, and the username lives only inside the file. |
| `allowTyping`    | `true`                       | Enable `Ctrl+Enter` / `Ctrl+Shift+Enter` (needs `wtype`).               |
| `notifyOnCopy`   | `true`                       | Notify when something was copied, naming the entry and its username. Failures are always notified.         |

## How it works

The plugin has two parts: an `overlay` (`PasswordstoreOverlay.qml`, the card,
summoned with `omarchy-shell shell toggle hegjon.passwordstore`) and a
`bar-widget` (`PasswordstoreWidget.qml`, the key on the bar, which also holds
the settings). Two small scripts do the work, and both can be run by hand:

- `passwordstore-list [--store DIR] [--recent FILE]` prints the names of the
  `*.gpg` files in the store as JSON. It never decrypts anything.
- `passwordstore-action <action> <entry> [...]` runs one action: `copy-password`,
  `copy-username`, `copy-otp`, `type-password`, `type-username`, `read`
  (the entry as JSON, for the editor), `save` (JSON on stdin, written with
  `pass insert -m`), `delete` (`pass rm -f`), `generate-password` or `edit`
  (in a terminal). Secrets travel over pipes and stdin, never argv, and the
  popup has already closed when it runs, so a typed password lands in the
  window you were in. Copies go
  through `wl-copy --sensitive`; the helper clears the clipboard after
  `clipTimeSec` and scrubs `~/.local/state/omarchy/clipboard-history.json`
  as a fallback.

Recently used names are kept in `$XDG_STATE_HOME/omarchy-passwordstore/recent`
(`~/.local/state/…`), outside the store so they are never committed with it.

## Development

`test/lint` runs qmllint, `test/test-manifest` checks the manifest,
`test/test-list` and `test/test-action` exercise the scripts against a
throwaway store and stand-in `pass`/`wl-copy`/`wtype`, so no gpg key is needed.

## License

MIT
