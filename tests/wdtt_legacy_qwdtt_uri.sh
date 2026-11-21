#!/usr/bin/env bash
# Regression: qwdtt/wdtt sections written by the old provider UI keep the URI
# in the generic `uri` option. Upgrading to native tachyon-core must keep them
# enabled, move the URI to the native csqtt_* keys and generate a wdtt outbound.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GEN="$TACHYON_LIB/tachyon_core/generator.uc"
MIGRATION="$TACHYON_LIB/config/migration.uc"
QWDTT_URI='qwdtt://config?v=1&ip=qwdtt.example.com&dtls=46000&vpn=wg&hashes=aabbcc,ddeeff&pass=pw#legacy'
QWDTT_JSON_B64="$(node -e 'process.stdout.write(Buffer.from(JSON.stringify({ name: "json-profile", peer: "qwdtt-json.example.com:46300", hashes: "h1,h2", workers: 18, port: 9000, password: "jsonpw" })).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""))')"
QWDTT_JSON_URI="qwdtt://${QWDTT_JSON_B64}#json-profile"

cat >"$WORK_DIR/fixture.json" <<EOF
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "engine": "tachyon-core",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "LEGACY_QWDTT",
      ".type": "section",
      "enabled": "1",
      "action": "wdtt",
      "uri": "$QWDTT_URI",
      "device_id": "dev-1",
      "workers": "4",
      "mtu": "1350",
      "domain_suffix": [ "example.com" ]
    },
    {
      ".name": "LEGACY_PEER_QWDTT",
      ".type": "section",
      "enabled": "1",
      "action": "wdtt",
      "uri": "qwdtt://config?name=%D0%94%D0%BE%D0%BC&peer=qwdtt-peer.example.com:46100&hashes=aabbcc&workers=18&port=9000&pass=pw2#legacy-peer",
      "domain_suffix": [ "example.org" ]
    },
    {
      ".name": "LEGACY_WDTT_PEER",
      ".type": "section",
      "enabled": "1",
      "action": "wdtt",
      "uri": "wdtt://?peer=wdtt-peer.example.com:46200&hashes=aabbcc&pass=pw3#legacy-wdtt",
      "domain_suffix": [ "example.net" ]
    },
    {
      ".name": "LEGACY_QWDTT_JSON",
      ".type": "section",
      "enabled": "1",
      "action": "wdtt",
      "uri": "$QWDTT_JSON_URI",
      "domain_suffix": [ "example.edu" ]
    }
  ]
}
EOF

config="$WORK_DIR/config.json"
mkdir -p "$config.section-cache" "$config.rulesets"
ucode -L "$TACHYON_LIB" "$GEN" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$config" "127.0.0.1" "0" "1" >/dev/null ||
  fail "generate-config-fixture failed for a legacy qwdtt URI"

ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let cfg = json(fs.readfile("'"$config"'"));
function outbound(tag) {
    for (let ob in (cfg.outbounds || []))
        if (ob.tag == tag) return ob;
    return null;
}
let found = outbound("LEGACY_QWDTT-out");
if (found == null) {
    warn("LEGACY_QWDTT-out missing: " + sprintf("%J", cfg.outbounds || []) + "\n");
    exit(1);
}
if (found.type != "wdtt" || found.server != "qwdtt.example.com" ||
    found.server_port != 46000 || found.password != "pw") {
    warn("qwdtt outbound mismatch: " + sprintf("%J", found) + "\n");
    exit(2);
}
if (found.device_id != "dev-1" || found.workers != 4 || found.mtu != 1350) {
    warn("qwdtt override mismatch: " + sprintf("%J", found) + "\n");
    exit(3);
}
let peer = outbound("LEGACY_PEER_QWDTT-out");
if (peer == null || peer.type != "wdtt" || peer.server != "qwdtt-peer.example.com" ||
    peer.server_port != 46100 || peer.password != "pw2" || peer.workers != 18) {
    warn("legacy qwdtt peer outbound mismatch: " + sprintf("%J", peer) + "\n");
    exit(4);
}
let wdtt_peer = outbound("LEGACY_WDTT_PEER-out");
if (wdtt_peer == null || wdtt_peer.type != "wdtt" ||
    wdtt_peer.server != "wdtt-peer.example.com" ||
    wdtt_peer.server_port != 46200 || wdtt_peer.password != "pw3") {
    warn("legacy wdtt peer outbound mismatch: " + sprintf("%J", wdtt_peer) + "\n");
    exit(5);
}
let json_profile = outbound("LEGACY_QWDTT_JSON-out");
if (json_profile == null || json_profile.type != "wdtt" ||
    json_profile.server != "qwdtt-json.example.com" ||
    json_profile.server_port != 46300 || json_profile.password != "jsonpw" ||
    json_profile.workers != 18) {
    warn("qwdtt JSON profile outbound mismatch: " + sprintf("%J", json_profile) + "\n");
    exit(6);
}
' || fail "legacy qwdtt URI did not produce a native wdtt outbound"

# The same URI is what the provider migration writes into a csqtt outbound
# source; make sure the native source path keeps the native overrides too.
cat >"$WORK_DIR/source_fixture.json" <<EOF
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "engine": "tachyon-core",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "outbound_source": [
    {
      ".name": "src_qwdtt",
      ".type": "outbound_source",
      "enabled": "1",
      "name": "QWDTT",
      "source_type": "csqtt",
      "csqtt_uri": "$QWDTT_URI",
      "csqtt_workers": "4",
      "csqtt_mtu": "1350",
      "csqtt_device_id": "dev-1"
    }
  ],
  "section": [
    {
      ".name": "QWDTT_SEC",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "src_qwdtt" ],
      "domain_suffix": [ "example.com" ]
    }
  ]
}
EOF

source_config="$WORK_DIR/source-config.json"
mkdir -p "$source_config.section-cache" "$source_config.rulesets"
ucode -L "$TACHYON_LIB" "$GEN" generate-config-fixture \
  "$WORK_DIR/source_fixture.json" "$source_config" "127.0.0.1" "0" "1" >/dev/null ||
  fail "generate-config-fixture failed for a qwdtt outbound source"

ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let cfg = json(fs.readfile("'"$source_config"'"));
let found = null;
for (let ob in (cfg.outbounds || []))
    if (ob.type == "wdtt") { found = ob; break; }
if (found == null) {
    warn("no native wdtt outbound for the qwdtt source: " + sprintf("%J", cfg.outbounds || []) + "\n");
    exit(1);
}
if (found.server != "qwdtt.example.com" || found.server_port != 46000 || found.password != "pw") {
    warn("qwdtt source outbound mismatch: " + sprintf("%J", found) + "\n");
    exit(2);
}
if (found.device_id != "dev-1" || found.workers != 4 || found.mtu != 1350) {
    warn("qwdtt source override mismatch: " + sprintf("%J", found) + "\n");
    exit(3);
}
' || fail "qwdtt outbound source did not produce a native wdtt outbound"

cat >"$WORK_DIR/state" <<EOF
tachyon.settings=settings
tachyon.settings.engine=sing-box
tachyon.settings.config_version=1.5.17
tachyon.sec_qwdtt=section
tachyon.sec_qwdtt.enabled=1
tachyon.sec_qwdtt.action=wdtt
tachyon.sec_qwdtt.uri=$QWDTT_URI
tachyon.sec_qwdtt.device_id=dev-1
tachyon.sec_qwdtt.workers=4
tachyon.sec_qwdtt.mtu=1350
tachyon.sec_qwdtt.domain_suffix=example.com
EOF

mkdir -p "$WORK_DIR/mig/runtime" "$WORK_DIR/mig/tmp-subscriptions" "$WORK_DIR/mig/persistent-cache"
TACHYON_UCI_STATE_FILE="$WORK_DIR/state" \
TACHYON_UCI_LOG_FILE="$WORK_DIR/mig/uci.log" \
TACHYON_CONFIG_NAME="tachyon" \
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/mig/tmp-subscriptions" \
TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/mig/runtime" \
TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/mig/persistent-cache" \
TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/mig/internal-config-change" \
  ucode -L "$TACHYON_LIB" "$MIGRATION" migrate ||
  fail "config migration failed for a legacy qwdtt section"

TACHYON_UCI_STATE_FILE="$WORK_DIR/state" ucode -L "$TACHYON_LIB" - <<'UCODE' ||
let uci = require("core.uci");
function get(s, o) { return uci.get("tachyon", s, o); }
function must(cond, msg) {
    if (!cond) {
        warn("FAIL: " + msg + "\n");
        exit(1);
    }
}
must(get("sec_qwdtt", "enabled") == "1", "legacy qwdtt section must stay enabled");
let action = get("sec_qwdtt", "action");
must(action == "connection" || action == "csqtt",
    "legacy qwdtt action must become connection/csqtt, got " + action);
let refs = get("sec_qwdtt", "outbound_source_refs");
must(index(refs || "", "src_csqtt_sec_qwdtt") >= 0,
    "legacy qwdtt section must reference the extracted csqtt source, got " + refs);
must(get("src_csqtt_sec_qwdtt", "source_type") == "csqtt",
    "extracted source must be csqtt");
must(index(get("src_csqtt_sec_qwdtt", "csqtt_uri") || "", "qwdtt://") == 0,
    "extracted source must carry the qwdtt URI");
must(get("src_csqtt_sec_qwdtt", "csqtt_workers") == "4", "workers must migrate");
must(get("src_csqtt_sec_qwdtt", "csqtt_mtu") == "1350", "mtu must migrate");
must(get("src_csqtt_sec_qwdtt", "csqtt_device_id") == "dev-1",
    "device id must migrate");
UCODE
  fail "migrated legacy qwdtt state failed assertions"

printf 'legacy qwdtt URI compatibility checks passed\n'
