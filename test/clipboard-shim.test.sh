#!/usr/bin/env bash
# Unit tests for overlay/bin/wl-paste, the VM half of the clipboard bridge
# (docs/superpowers/specs/2026-09-07-clipboard-bridge-design.md). A python fake
# stands in for the mac's launchd responder on a free loopback port, so this
# needs no ssh session and no mac. Run directly or via test/run.sh.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$REPO/overlay/bin/wl-paste"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/clipboard-shim.XXXXXX")"
srv_pid=
cleanup() { [ -n "$srv_pid" ] && kill "$srv_pid" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; failc=0
check() { if "$@"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; failc=$((failc+1)); fi; }

# A 64x64 red PNG built from the spec, so no binary fixture lives in git.
python3 - "$TMP/fixture.png" <<'EOF'
import struct, sys, zlib
w = h = 64
raw = b''.join(b'\x00' + bytes([200, 40, 40]) * w for _ in range(h))
def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))
open(sys.argv[1], 'wb').write(png)
EOF

# Fake responder speaking the bridge protocol: one request line in, bytes out,
# close. While $TMP/no-image exists it behaves like a text-only mac clipboard.
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
PORT="$(free_port)"
CLOSED_PORT="$(free_port)"
python3 - "$PORT" "$TMP/fixture.png" "$TMP/no-image" >"$TMP/server.log" 2>&1 <<'EOF' &
import os, socket, sys
port, fixture, flag = int(sys.argv[1]), open(sys.argv[2], 'rb').read(), sys.argv[3]
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', port))
srv.listen(8)
print('READY', flush=True)
while True:
    conn, _ = srv.accept()
    verb = conn.makefile('rb').readline().strip()
    has_image = not os.path.exists(flag)
    if verb == b'types' and has_image:
        conn.sendall(b'image/png\n')
    elif verb == b'png' and has_image:
        conn.sendall(fixture)
    conn.close()
EOF
srv_pid=$!
for _ in $(seq 1 50); do grep -q READY "$TMP/server.log" 2>/dev/null && break; sleep 0.1; done
grep -q READY "$TMP/server.log" || { echo "fake responder did not start" >&2; exit 1; }

shim() { CLIPBOARD_BRIDGE_PORT="$PORT" "$SHIM" "$@"; }

test_shim_is_executable() { [ -x "$SHIM" ]; }

test_lists_image_png_when_mac_has_image() {
  [ "$(shim -l)" = "image/png" ] && [ "$(shim --list-types)" = "image/png" ]
}

test_lists_nothing_when_mac_has_no_image() {
  : > "$TMP/no-image"
  local out rc
  out="$(shim -l)"; rc=$?
  rm -f "$TMP/no-image"
  [ -z "$out" ] && [ "$rc" -eq 0 ]
}

test_streams_png_bytes() {
  shim --type image/png > "$TMP/got.png" && cmp -s "$TMP/got.png" "$TMP/fixture.png" \
    && shim -t image/png | cmp -s - "$TMP/fixture.png"
}

test_text_read_falls_through() {
  # Claude Code tries `wl-paste --no-newline` for text; the shim must decline so
  # the next backend runs: non-zero exit, nothing on stdout.
  local out rc
  out="$(shim --no-newline)"; rc=$?
  [ -z "$out" ] && [ "$rc" -ne 0 ]
}

test_no_forward_is_a_quiet_no_op() {
  # No ssh session means nothing listens on the port: fail silently so
  # Claude Code's ctrl+v is a no-op rather than an error.
  local out rc
  out="$(CLIPBOARD_BRIDGE_PORT="$CLOSED_PORT" "$SHIM" -l 2>"$TMP/err")"; rc=$?
  [ -z "$out" ] && [ "$rc" -ne 0 ] && [ ! -s "$TMP/err" ]
}

check test_shim_is_executable
check test_lists_image_png_when_mac_has_image
check test_lists_nothing_when_mac_has_no_image
check test_streams_png_bytes
check test_text_read_falls_through
check test_no_forward_is_a_quiet_no_op
echo "----"
echo "$pass passed, $failc failed"
[ "$failc" -eq 0 ]
