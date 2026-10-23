#!/usr/bin/env bash
# The olcrtc binary is the openlibrecommunity YAML build: it takes exactly one
# config path and knows jitsi, telemost and wbstream. Tachyon must write that
# strict schema, run its own init script, and keep the feed's flag init and the
# standalone TUN service out of the way.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

RUNTIME="$TACHYON_LIB/providers/olcrtc/runtime.uc"
KEY="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

[ "${#KEY}" -eq 64 ] || fail "test key must be 64 characters"

cat >"$WORK_DIR/olcrtc.init" <<'SH'
#!/bin/sh
echo "$1" >>"$OLCRTC_INIT_LOG"
exit 0
SH
chmod +x "$WORK_DIR/olcrtc.init"

cat >"$WORK_DIR/olcrtc-legacy.init" <<'SH'
#!/bin/sh
echo "$1" >>"$OLCRTC_LEGACY_INIT_LOG"
exit 0
SH
chmod +x "$WORK_DIR/olcrtc-legacy.init"

cat >"$WORK_DIR/olcrtc-tun.init" <<'SH'
#!/bin/sh
echo "$1" >>"$OLCRTC_TUN_INIT_LOG"
exit 0
SH
chmod +x "$WORK_DIR/olcrtc-tun.init"

run_runtime() {
  local state="$1" log="$2"
  OLCRTC_INIT_LOG="$log" \
  OLCRTC_LEGACY_INIT_LOG="$WORK_DIR/legacy-init.log" \
  OLCRTC_TUN_INIT_LOG="$WORK_DIR/tun-init.log" \
  TACHYON_UCI_STATE_FILE="$state" \
  TACHYON_UCI_LOG_FILE="$WORK_DIR/uci.log" \
  TACHYON_OLCRTC_BIN=/bin/true \
  TACHYON_OLCRTC_SERVICE_INIT="$WORK_DIR/olcrtc.init" \
  TACHYON_OLCRTC_LEGACY_SERVICE_INIT="$WORK_DIR/olcrtc-legacy.init" \
  TACHYON_OLCRTC_TUN_INIT="$WORK_DIR/olcrtc-tun.init" \
  TACHYON_OLCRTC_CONFIG="$WORK_DIR/client.yaml" \
    ucode -L "$TACHYON_LIB" "$RUNTIME" start-runtime
}

assert_line() {
  grep -qxF "$1" "$2" || fail "expected '$1' in $2"
}

assert_absent() {
  if grep -qF "$1" "$2"; then
    fail "unexpected '$1' in $2"
  fi
}

# The generator only emits an outbound for the active providers (a section
# with routing matchers or match_all), and numbers their ports in that order.
# Pick the same section here, otherwise the service is configured from one
# section while sing-box dials the port computed for another.
cat >"$WORK_DIR/state" <<EOF
tachyon.olcidle=section
tachyon.olcidle.enabled=1
tachyon.olcidle.action=olcrtc
tachyon.olcidle.provider=telemost
tachyon.olcidle.transport=datachannel
tachyon.olcidle.room_id=idle-room
tachyon.olcidle.crypto_key=$KEY
tachyon.olcidle.socks_port=1099
tachyon.olcactive=section
tachyon.olcactive.enabled=1
tachyon.olcactive.action=olcrtc
tachyon.olcactive.match_all=1
tachyon.olcactive.provider=wbstream
tachyon.olcactive.transport=datachannel
tachyon.olcactive.room_id=active-room
tachyon.olcactive.crypto_key=$KEY
tachyon.olcactive.dns_server=1.1.1.1:53
tachyon.olcactive.socks_port=1099
EOF

rm -f "$WORK_DIR/client.yaml" "$WORK_DIR/init.log" "$WORK_DIR/legacy-init.log" \
  "$WORK_DIR/tun-init.log" "$WORK_DIR/uci.log"
: >"$WORK_DIR/uci.log"
run_runtime "$WORK_DIR/state" "$WORK_DIR/init.log" >"$WORK_DIR/out" 2>&1

assert_line "mode: cnc" "$WORK_DIR/client.yaml"
assert_line "  provider: 'wbstream'" "$WORK_DIR/client.yaml"
assert_line "  id: 'active-room'" "$WORK_DIR/client.yaml"
assert_line "  key: '$KEY'" "$WORK_DIR/client.yaml"
assert_line "  transport: 'datachannel'" "$WORK_DIR/client.yaml"
assert_line "  dns: '1.1.1.1:53'" "$WORK_DIR/client.yaml"
assert_line "  host: '127.0.0.1'" "$WORK_DIR/client.yaml"
assert_line "  port: 1099" "$WORK_DIR/client.yaml"
assert_absent "idle-room" "$WORK_DIR/client.yaml"
assert_absent "client_id" "$WORK_DIR/client.yaml"
assert_absent "olcrtc.main" "$WORK_DIR/state"
assert_absent "commit" "$WORK_DIR/uci.log"
assert_line "stop" "$WORK_DIR/legacy-init.log"
assert_line "disable" "$WORK_DIR/legacy-init.log"
assert_line "stop" "$WORK_DIR/tun-init.log"
assert_line "disable" "$WORK_DIR/tun-init.log"
assert_line "restart" "$WORK_DIR/init.log"
assert_line "status" "$WORK_DIR/init.log"
[ "$(stat -c '%a' "$WORK_DIR/client.yaml")" = "600" ] ||
  fail "YAML config must be mode 0600"

# A link without #key parses, but the binary refuses to start. Fail before
# touching the config instead of reporting a successful restart.
cat >"$WORK_DIR/keyless" <<EOF
tachyon.olc=section
tachyon.olc.enabled=1
tachyon.olc.action=olcrtc
tachyon.olc.match_all=1
tachyon.olc.subscription_links=olcrtc://wbstream?datachannel@keyless-room
EOF

rm -f "$WORK_DIR/client.yaml"
: >"$WORK_DIR/keyless-init.log"
run_runtime "$WORK_DIR/keyless" "$WORK_DIR/keyless-init.log" >"$WORK_DIR/keyless-out" 2>&1

[ ! -e "$WORK_DIR/client.yaml" ] || fail "keyless config must not write YAML"
assert_absent "restart" "$WORK_DIR/keyless-init.log"

# jitsi rooms are full URLs. The client id after '%' is a feed-build detail and
# must not leak into the YAML schema, which has no client_id field.
cat >"$WORK_DIR/jitsi" <<EOF
tachyon.olc=section
tachyon.olc.enabled=1
tachyon.olc.action=olcrtc
tachyon.olc.match_all=1
tachyon.olc.subscription_links=olcrtc://jitsi?seichannel<fps=60&batch=64&frag=900&ack-ms=2000>@https://meet.example.org/tachyon-room#$KEY%android-01
EOF

rm -f "$WORK_DIR/client.yaml"
: >"$WORK_DIR/jitsi-init.log"
run_runtime "$WORK_DIR/jitsi" "$WORK_DIR/jitsi-init.log" >"$WORK_DIR/jitsi-out" 2>&1

assert_line "  provider: 'jitsi'" "$WORK_DIR/client.yaml"
assert_line "  id: 'https://meet.example.org/tachyon-room'" "$WORK_DIR/client.yaml"
assert_line "  transport: 'seichannel'" "$WORK_DIR/client.yaml"
assert_line "  fps: 60" "$WORK_DIR/client.yaml"
assert_line "  batch_size: 64" "$WORK_DIR/client.yaml"
assert_line "  fragment_size: 900" "$WORK_DIR/client.yaml"
assert_line "  ack_timeout_ms: 2000" "$WORK_DIR/client.yaml"
assert_absent "android-01" "$WORK_DIR/client.yaml"
assert_absent "client_id" "$WORK_DIR/client.yaml"
assert_line "restart" "$WORK_DIR/jitsi-init.log"

# jazz only exists in the old flag build; the YAML binary would reject it
# after Tachyon already reported a successful start.
cat >"$WORK_DIR/jazz" <<EOF
tachyon.olc=section
tachyon.olc.enabled=1
tachyon.olc.action=olcrtc
tachyon.olc.match_all=1
tachyon.olc.subscription_links=olcrtc://jazz?datachannel@jazz-room#$KEY
EOF

rm -f "$WORK_DIR/client.yaml"
: >"$WORK_DIR/jazz-init.log"
run_runtime "$WORK_DIR/jazz" "$WORK_DIR/jazz-init.log" >"$WORK_DIR/jazz-out" 2>&1

[ ! -e "$WORK_DIR/client.yaml" ] || fail "unsupported provider must not write YAML"
assert_absent "restart" "$WORK_DIR/jazz-init.log"
grep -q "provider must be one of: jitsi, telemost, wbstream" "$WORK_DIR/jazz-out" ||
  fail "jazz must report a clear provider mismatch"

# With no enabled section the runtime must stop its own init and make sure the
# feed init and standalone tunnel cannot keep running.
cat >"$WORK_DIR/empty" <<EOF
tachyon.other=section
tachyon.other.enabled=1
tachyon.other.action=byedpi
EOF

rm -f "$WORK_DIR/client.yaml" "$WORK_DIR/empty-init.log" \
  "$WORK_DIR/legacy-init.log" "$WORK_DIR/tun-init.log"
run_runtime "$WORK_DIR/empty" "$WORK_DIR/empty-init.log" >"$WORK_DIR/empty-out" 2>&1

[ ! -e "$WORK_DIR/client.yaml" ] || fail "disabled olcrtc must not write YAML"
assert_line "stop" "$WORK_DIR/empty-init.log"
assert_line "stop" "$WORK_DIR/legacy-init.log"
assert_line "disable" "$WORK_DIR/legacy-init.log"
assert_line "stop" "$WORK_DIR/tun-init.log"
assert_line "disable" "$WORK_DIR/tun-init.log"

echo "olcrtc runtime: ok"
