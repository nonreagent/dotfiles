# Clipboard bridge: kitty + exe.dev + tmux

**Status:** approved design, awaiting spec review\
**Date:** 2026-09-07\
**Repos:** `nonrational/dotfiles` (mac side), `nonreagent/dotfiles` (VM side)

## Goal

Two clipboard flows between a mac running kitty and an exe.dev VM running tmux:

1. **VM to mac, text.** Highlight text in tmux copy-mode on the VM; paste it into Sublime (or anything) on the mac with cmd+v.
2. **Mac to VM, image.** Take a screenshot (or copy any image) on the mac; press ctrl+v in Claude Code running inside tmux on the VM; the image attaches.

Flow 1 already works. Flow 2 needs new plumbing. The design keeps flow 1 as it is, removes one dead binding, and adds the minimum for flow 2.

## Non-goals

- Text paste from mac to VM. kitty's cmd+v already delivers the mac clipboard to the remote pane through bracketed paste.
- Continuous clipboard mirroring, clipboard history, or multi-host mesh sync. See [Alternatives](#alternatives-considered) for why clipfan was evaluated and not adopted.
- Writing to the mac clipboard from the VM by any path other than the terminal's own OSC 52 handling.
- Serving mac clipboard **text** to the VM. Only image data crosses the bridge.

## Findings that shaped the design

Established 2026-09-05 and 2026-09-06 against the live setup (kitty 0.48.2, tmux 3.4 on the VM, Claude Code 2.1.263, exe.dev VM `agent-base`).

- **Flow 1 already works end to end.** tmux's default `set-clipboard external` emits OSC 52 to the outer terminal on every copy-mode copy, including mouse-drag release, and kitty accepts OSC 52 writes by default. Verified from the mac: `tmux set-buffer -w 'osc52 probe'` on the VM pasted into Sublime.
- **The `y` binding pipes to `pbcopy`, which does not exist on Linux.** The pipe fails silently; the buffer is still created and OSC 52 still fires. Cosmetic, but a failing `sh -c pbcopy` per copy is noise worth removing.
- **`TERM=xterm-color` on the VM comes from `.bashrc.Darwin`**, not from kitty or the exe.dev gateway. tmux still detects the client as `kitty(0.48.2)` and advertises the `clipboard` feature. No change needed.
- **exe.dev terminates SSH at its gateway** (single `exe.dev` host key; the VM sees `SSH_CLIENT=127.0.0.1`). The VM's own `/exe.dev/bin/sshd` allows TCP and stream-local forwarding with `PermitListen any`. Whether the gateway relays reverse forwards was the open question. Verified from the mac: `ssh -R 127.0.0.1:2224:127.0.0.1:2224 agent-base.exe.xyz 'ss -tln | grep -q 2224'` printed `REMOTE_FORWARD_OK`.
- **Claude Code on Linux shells out for image paste.** On ctrl+v it runs, in order: `xclip -selection clipboard -t TARGETS -o`, then `wl-paste -l`, then `xclip -selection clipboard -t image/png -o`, then `wl-paste --type image/png`. The real `xclip` is installed on the VM but fails without a display; `wl-paste` is not installed. A shim named `wl-paste` that answers `-l` with `image/png` and `--type image/png` with PNG bytes produced `[Image #1]` in the composer. Verified 2026-09-07 with a throwaway shim in a detached tmux window; the four calls completed in about 30 ms. There is no `DISPLAY` or `WAYLAND_DISPLAY` gate on this path.
- **In-band terminal protocols cannot carry the image.** kitty's clipboard kitten (OSC 5522) and OSC 52 reads are request/response, and tmux does not route terminal responses back to the pane. The image has to travel out of band.
- **`~/bin` precedes `/bin` in the VM's PATH**, and `home/bin` in `nonreagent/dotfiles` is built from upstream `home/bin.Linux` plus `overlay/bin/*` (`build.sh` line 192), so a shim placed in `overlay/bin/` lands at `~/bin/wl-paste`.

## Architecture

```
mac                                          exe.dev VM
────────────────────────────────             ──────────────────────────────────────
NSPasteboard                                 Claude Code (inside tmux)
   ▲                                              │ ctrl+v
   │ osascript                                    ▼ sh -c "xclip … || wl-paste -l …"
clipboard-bridge (bash, per connection)      ~/bin/wl-paste (shim)
   ▲ stdin/stdout = socket                        │ /dev/tcp/127.0.0.1/2224
launchd socket 127.0.0.1:2224  ◀── ssh -R ──  127.0.0.1:2224 (sshd listener)
   (inetd-style, idle = no process)          via the exe.dev gateway

VM to mac text: tmux copy-mode ─OSC 52─▶ kitty ─▶ NSPasteboard   (unchanged)
```

Pull model: nothing moves until Claude Code asks. Between pastes there is no daemon, no state on the VM, and no mac clipboard content on the VM.

## Components

### Mac side (PR to `nonrational/dotfiles`)

**1. `home/bin.Darwin/clipboard-bridge`** — bash, invoked by launchd once per connection with the socket on stdin/stdout. Reads one line (with `read -t 5` so a stray connection cannot pin a process) and answers:

| request | response |
|---|---|
| `types` | `image/png` followed by newline when the pasteboard holds image data (`«class PNGf»` or `«class TIFF»` in `osascript -e 'clipboard info'`); otherwise nothing. Exit 0. |
| `png` | Raw PNG bytes, then close. If there is no image, nothing and exit 1. |
| anything else | Nothing, exit 1. |

The PNG path is the one Claude Code itself uses on macOS: `osascript` coerces `the clipboard as «class PNGf»` and writes it to a `mktemp` file, which the script cats and removes. If PNGf coercion fails but TIFF is present, coerce `«class TIFF»` and convert with `sips -s format png`. The script never accepts data, so it cannot write the mac clipboard. Errors go to `logger -t clipboard-bridge`, and a failed pasteboard read (a permission denial, say) is logged as such rather than reported as "no image", so the troubleshooting steps can tell the two apart.

**2. `home/Library/LaunchAgents/org.nonrational.clipboard-bridge.plist`** — socket-activated, inetd-compatible:

- `Label` `org.nonrational.clipboard-bridge`
- `ProgramArguments` `/bin/sh -c 'exec "$HOME/bin/clipboard-bridge"'` (plists cannot expand `~`, and hardcoding a username does not belong in a public repo; launchd user agents receive `HOME`)
- `Sockets` → `Listener` with `SockNodeName 127.0.0.1`, `SockServiceName 2224`, `SockType stream`, `SockFamily IPv4`
- `inetdCompatibility` → `Wait false`
- No `RunAtLoad`. The agent spawns only when something connects.

Manifest row: `home/Library/LaunchAgents/org.nonrational.clipboard-bridge.plist  ~/Library/LaunchAgents/org.nonrational.clipboard-bridge.plist  os=Darwin`. `deploy.sh` creates parent directories (line 122), so the row needs nothing else.

One-time activation, as a Makefile target `clipboard-bridge` alongside the existing `link-karabiner` / `link-sublime` one-offs: `launchctl bootout gui/$(id -u)/org.nonrational.clipboard-bridge` (ignore failure), then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.nonrational.clipboard-bridge.plist`. Re-running it reloads after edits.

**3. `home/.ssh/config.d/exe.conf`** — the forward plus connection sharing:

```
Host *.exe.xyz
  RemoteForward 127.0.0.1:2224 127.0.0.1:2224
  ExitOnForwardFailure no
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 4h
  ServerAliveInterval 30
  ServerAliveCountMax 3
```

Why each line: `RemoteForward` is the bridge. `ExitOnForwardFailure no` keeps a session usable if the port is somehow taken. `ControlMaster` + `ControlPersist` make every kitty window share one connection, so the forward is requested once and no second window prints "remote port forwarding failed"; new windows also open instantly. `ServerAlive*` lets the master notice a dead VM within about 90 seconds, so the next `ssh` builds a fresh master with a fresh forward instead of hanging on a stale one.

Manifest row: `home/.ssh/config.d/exe.conf  ~/.ssh/config.d/exe.conf  os=Darwin`. One-time: add `Include config.d/*.conf` as the **first** line of `~/.ssh/config` (ssh resolves relative `Include` paths against `~/.ssh`; an `Include` placed inside a `Host` block is scoped to that block). `~/.ssh/config` itself stays unmanaged. The FAQ stanza exe.dev recommends for `IdentityFile` coexists: ssh merges matching `Host` blocks, first value per option wins, and no option overlaps.

**4. `home/.tmux.conf` line 47** — make the pbcopy pipe macOS-only:

```
if-shell 'command -v pbcopy' 'bind -T copy-mode-vi "y" send -X copy-pipe-and-cancel "pbcopy"'
```

On Linux the earlier `y` binding (`copy-selection-and-cancel`, line 38) stands, and tmux's `set-clipboard` emits OSC 52 as it does today. Adjust the comment above it (lines 43–44) to say the pbcopy pipe is the macOS path and the terminal's OSC 52 handling covers everywhere else. `nonreagent/dotfiles` picks this up on its next `./build.sh`.

### VM side (PR to `nonreagent/dotfiles`)

**5. `overlay/bin/wl-paste`** — bash shim, vendored to `home/bin/wl-paste`, deployed to `~/bin/wl-paste`. Handles exactly the two calls Claude Code makes and refuses everything else so text reads keep falling through to Claude Code's remaining backends:

```bash
#!/usr/bin/env bash
# No Wayland exists on this VM, so nothing real is shadowed. Claude Code reaches
# wl-paste only after xclip fails without a display; answering these two calls
# from the mac over the reverse-forwarded port is what makes ctrl+v image paste
# work inside tmux. Port must match the RemoteForward in the mac's ssh config.
set -u
port=${CLIPBOARD_BRIDGE_PORT:-2224}
request() {
  { exec 3<>"/dev/tcp/127.0.0.1/$port"; } 2>/dev/null || return 1
  printf '%s\n' "$1" >&3
  # A listener whose ssh session died (mac asleep) accepts and then hangs
  # while sshd fails to open the channel; cap that so ctrl+v stays a no-op.
  timeout 10 cat <&3
}
case " $* " in
  *" -l "*|*" --list-types "*)                 request types ;;
  *" --type image/png "*|*" -t image/png "*)  request png ;;
  *)                                          exit 1 ;;
esac
```

`/dev/tcp` needs bash built with network redirections; Debian's is. `CLIPBOARD_BRIDGE_PORT` exists so the test below can run against a fake server on another port; production uses the default.

**6. `test/clipboard-shim.test.sh`**, wired into `test/run.sh` — starts a python fake responder on a free loopback port (no extra dependency) answering `types` with `image/png` and `png` with a fixture PNG, then asserts:

- `wl-paste -l` prints exactly `image/png`.
- `wl-paste --type image/png` reproduces the fixture byte for byte.
- `wl-paste --no-newline` (a text read) exits non-zero with no output.
- With no server listening, `wl-paste -l` exits non-zero with no output on stdout.

**7. README** — a short "Clipboard bridge" note under Install in `nonreagent/dotfiles` (what the shim does, that the mac half lives upstream, link to this spec), and a matching note with the two one-time steps in `nonrational/dotfiles`.

## Data flow for one ctrl+v

1. Claude Code runs its check command. `xclip` fails (no display). `wl-paste -l` connects to `127.0.0.1:2224` on the VM.
2. sshd hands the connection to the mac's ssh client over the existing session; the client connects to `127.0.0.1:2224` on the mac.
3. launchd accepts, spawns `clipboard-bridge` with the socket as stdin/stdout. It reads `types`, runs `clipboard info`, prints `image/png`, exits.
4. Claude Code's grep matches. It runs its save command. `xclip` fails again. `wl-paste --type image/png` sends `png`.
5. A fresh `clipboard-bridge` writes the PNG to a temp file via `osascript`, cats it, removes it, exits. Bytes stream back into Claude Code's temp file. The composer shows `[Image #1]`.

Two round trips per paste. Each is a few hundred milliseconds, dominated by `osascript`.

## Error handling

| situation | behaviour |
|---|---|
| No ssh session from the mac, so no forward | `/dev/tcp` connect is refused; shim exits 1; ctrl+v does nothing. |
| Session up, launchd agent not loaded | ssh cannot connect on the mac side; the channel closes with no data; `-l` prints nothing; ctrl+v does nothing. |
| Mac clipboard holds text only | `types` prints nothing; ctrl+v does nothing; text still arrives via cmd+v as today. |
| Second kitty window | Shares the ControlMaster connection; no second forward, no warning. |
| VM restarts | Master dies within ~90 s via `ServerAlive*`; next `ssh` recreates master and forward. |
| Mac sleeps; the VM-side listener outlives its ssh session | The stale listener accepts but no channel opens; the shim's 10-second read timeout turns that into a no-op paste. The VM's sshd drops the dead connection within about three minutes (client-alive probes every 60 s, three misses); until then a new session's forward request fails with a harmless warning and the port stays stale. Afterwards `ssh -O exit <vm>.exe.xyz` on the mac plus a fresh window brings the forward back. |
| Claude Code opened from the exe.dev web terminal instead of kitty | No forward exists; ctrl+v does nothing. |

Every failure is a silent no-op paste. Nothing is left behind on either machine.

## Security

- **What the VM can see.** While a session from the mac is connected, and for up to four hours after the last window closes (`ControlPersist 4h` keeps the master and its forward alive; `ssh -O exit <vm>.exe.xyz` ends it early, and shortening `ControlPersist` shrinks the tail), any process on the VM, agents included, can connect to `127.0.0.1:2224` and read the mac clipboard **image**. Text is never served. The mac-side script has no write path, so the VM cannot alter the mac clipboard through the bridge. The VM-to-mac direction remains OSC 52 through kitty, which kitty gates with its own `clipboard_control` setting.
- **Listener scope.** The mac agent binds `127.0.0.1` only. On the VM the forward is requested on `127.0.0.1` explicitly, and the exe.dev sshd has `GatewayPorts no`.
- **Process scope.** Both ends run as the user. The handler touches one `mktemp` file per PNG request and removes it.
- **Failure mode.** If exe.dev ever stops relaying reverse forwards, the bridge fails closed: ctrl+v becomes a no-op.

## Testing and verification

- **Automated (VM repo):** `test/clipboard-shim.test.sh` as above, run by `test/run.sh`.
- **Manual (mac):** after `make deploy` and `make clipboard-bridge`, with an image on the clipboard: `printf 'types\n' | nc 127.0.0.1 2224` prints `image/png`; `printf 'png\n' | nc 127.0.0.1 2224 | file -` reports PNG image data.
- **End to end:** open a kitty window to the VM, take a screenshot, run Claude Code inside tmux, press ctrl+v, see `[Image #1]`. The detached-tmux-window probe used for the finding above doubles as a scripted version.

## Rollout

1. Merge the `nonrational/dotfiles` PR. On the mac: `git pull`, `make deploy`, `make clipboard-bridge`, add the `Include` line to `~/.ssh/config`.
2. Merge the `nonreagent/dotfiles` PR. On the VM: `git pull`, `./install.sh` (a new file needs linking).
3. Rebuild `nonreagent/dotfiles` from upstream (`./build.sh`) so the tmux change flows in; commit as the usual "latest from upstream".
4. Open a fresh kitty window to the VM (so the forward exists), screenshot, ctrl+v in Claude Code.

Existing tmux sessions and running Claude Code instances need no restart: `~/bin` is already on their PATH, so the shim is found as soon as the symlink exists.

## Risks and open items

- **macOS pasteboard privacy.** Sequoia can prompt when a background process reads the pasteboard. Claude Code and clipfan use the same `osascript` primitives under the same conditions without reported prompts; verify on first run and allow once if asked.
- **launchd and a symlinked plist.** `deploy.sh` symlinks the plist into `~/Library/LaunchAgents`. `launchctl bootstrap` on a symlink is expected to work; if it refuses, the `clipboard-bridge` Makefile target copies instead of relying on the link.
- **`kitten ssh`.** Not in use today. If adopted later, its own multiplexing settings may conflict with `ControlMaster`; revisit then.
- **Port 2224** is a constant in three places (plist, ssh include, shim default). Chosen arbitrarily; change all three together.

## Alternatives considered

- **clipfan** (`prime-radiant-inc/clipfan`, obra). The closest prior art and the source of the shim interface. Not adopted as software: its license grants nothing (all rights reserved), so nothing can be vendored; its transport shells out to `ssh -F /dev/null` with its own key and `ProxyCommand=none`, straight to host:22, and its mesh-heal learns the mac's address from `SSH_CONNECTION` on the remote, which through the exe.dev gateway is `127.0.0.1`; fresh-host enrollment is broken in the current release (issue #8); and it mirrors the whole mac clipboard plus history onto the VM, which is more trust than an autonomous-agent VM should hold. Borrowed: the `xclip`/`wl-paste` shim interface and the conclusion that OSC 52 is the right VM-to-mac channel. Its image-as-path-on-text trick (write the PNG to a state dir, offer the path for tools whose ctrl+v needs X11) was considered and deferred: only Claude Code is in scope, and it is one `tee` line if a second tool ever needs it.
- **Push from a kitty keybinding.** A mac script dumps the clipboard PNG, uploads it, and pastes the remote path. No forward and no exposure, but a second keystroke, and the script must know which VM the window is talking to. Kept as fallback if the gateway ever stops relaying forwards.
- **kitty remote control over the ssh kitten.** Its `run` command would let VM processes execute arbitrary commands on the mac. Rejected.
- **OSC 5522 / OSC 52 read.** Request/response; tmux swallows the reply. Rejected.
- **X11 forwarding with XQuartz.** Would make the real `xclip` work, but XQuartz syncs text with the pasteboard, not images. Rejected.
