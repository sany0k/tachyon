#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let connections = require("config.connections");

let as_string = common.as_string;

const MODE = as_string(getenv("TACHYON_CONFIG_NAME")) || "tachyon";
const LIB_DIR = as_string(getenv("TACHYON_LIB_DIR")) || "/usr/lib/tachyon";
const CONFIG_NAME = MODE;

let cfg = require("providers.olcrtc.common").config({ lib_dir: LIB_DIR });
let olcrtc_validator = require("providers.olcrtc.validator");

function log_message(msg, level) {
    level = level || "info";
    printf("%s\n", msg);
    system("logger -t " + MODE + " -p " + (level == "fatal" ? "user.err" : level == "warn" ? "user.warning" : "user.info") + " '" + msg + "'");
}

let command_success_from_args = common.command_success_from_args;
let option = common.option;
let option_or_legacy = common.option_or_legacy;
let list_option_or_legacy = common.list_option_or_legacy;
let section_name = common.section_name;
let write_json = common.write_json;

function enabled_sections() {
    return connections.olcrtc_sections();
}

// The generator only emits an outbound for the active providers (a section
// with routing matchers or match_all), and numbers their ports in that order.
// Pick the same section here, otherwise the service is configured from one
// section while sing-box dials the port computed for another.
function runtime_sections() {
    let active = connections.active_provider_sections("olcrtc");
    return length(active) > 0 ? active : enabled_sections();
}

function enabled_rule_count() {
    let sections = enabled_sections();
    return length(sections);
}

function provider_available() {
    return fs.stat(cfg.binary) != null;
}

function service_init_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function service_running() {
    return command_success_from_args([ cfg.service_init, "status" ]);
}

function wait_service_running(attempts) {
    for (let attempt = 0; attempt < attempts; attempt++) {
        if (service_running())
            return true;
        if (attempt + 1 < attempts)
            sleep(1000);
    }
    return false;
}

function service_enabled() {
    return command_success_from_args([ cfg.service_init, "enabled" ]);
}

function stop_service(path) {
    if (!service_init_exists(path))
        return false;
    return command_success_from_args([ as_string(path), "stop" ]);
}

// The standalone bundle can also enable olcrtc-tun, which routes traffic
// through its own TUN. Tachyon dials the SOCKS listener instead, so the two
// must not run together (see the upstream sing-box integration doc).
function stop_standalone_tunnel() {
    let init = cfg.tun_service_init;
    if (fs.stat(init) == null)
        return;
    command_success_from_args([ init, "stop" ]);
    command_success_from_args([ init, "disable" ]);
}

// The YAML binary replaces the feed build, but the feed init script and the
// standalone TUN service may still be installed and enabled. Stop and disable
// them so only the YAML init owns /usr/bin/olcrtc.
function stop_legacy_services() {
    let legacy = cfg.legacy_service_init;
    if (service_init_exists(legacy)) {
        command_success_from_args([ legacy, "stop" ]);
        command_success_from_args([ legacy, "disable" ]);
    }
    stop_standalone_tunnel();
}

function stop_all_services() {
    stop_service(cfg.service_init);
    stop_legacy_services();
}

function package_version() {
    let ver = trim(fs.readfile("/etc/olcrtc/.version") || "");
    if (ver != "")
        return ver;
    let pkgs = require("core.packages");
    if (pkgs && pkgs.version) {
        let v = pkgs.version("olcrtc");
        if (v != "")
            return v;
    }
    return "";
}

function fetch_url(url) {
    let tmp = "/tmp/tachyon-olcrtc-sub";
    let attempts = [
        [ "curl", "-fsSL", "-o", tmp, "--connect-timeout", "20", "--max-time", "20", url ],
        [ "wget", "-q", "-O", tmp, "--timeout=20", url ],
        [ "uclient-fetch", "-q", "-O", tmp, "--timeout=20", url ]
    ];
    // The subscription body was left in /tmp (RAM) after every fetch.
    let body = "";
    for (let argv in attempts) {
        if (command_success_from_args(argv)) {
            body = trim(fs.readfile(tmp) || "");
            break;
        }
    }
    fs.unlink(tmp);
    return body;
}

function first_uri_from_subscription(data) {
    let lines = split(data, "\n\r");
    for (let line in lines) {
        line = trim(line);
        if (substr(line, 0, 9) == "olcrtc://")
            return line;
    }
    return "";
}

function resolve_connection(section) {
    let links = list_option_or_legacy(section, "subscription_links", "olcrtc_subscription_links");
    let resolved = null;
    let used_link = "";
    let subscription_name = "";
    let subscription_refresh = "";
    let provider = option_or_legacy(section, "provider", "olcrtc_provider", "");
    let transport = option_or_legacy(section, "transport", "olcrtc_transport", "");
    let room_id = option_or_legacy(section, "room_id", "olcrtc_room_id", "");
    let crypto_key = option_or_legacy(section, "crypto_key", "olcrtc_crypto_key", "");

    for (let link in links) {
        link = trim(as_string(link));
        if (link == "")
            continue;

        if (substr(link, 0, 9) == "olcrtc://") {
            let parsed = olcrtc_validator.parse_uri(link);
            if (parsed.valid) {
                resolved = parsed;
                used_link = link;
                break;
            }
            log_message("Invalid olcrtc:// URI: " + parsed.reason, "warn");
            continue;
        }

        if (substr(link, 0, 8) == "https://" || substr(link, 0, 7) == "http://") {
            let data = fetch_url(link);
            if (data == "") {
                log_message("Failed to fetch subscription: " + link, "warn");
                continue;
            }
            let uri = first_uri_from_subscription(data);
            if (uri == "") {
                log_message("No olcrtc:// URI found in subscription: " + link, "warn");
                continue;
            }
            let parsed = olcrtc_validator.parse_uri(uri);
            if (parsed.valid) {
                resolved = parsed;
                used_link = link;
                let lines = split(data, "\n\r");
                for (let line in lines) {
                    line = trim(line);
                    if (substr(line, 0, 6) == "#name:")
                        subscription_name = trim(substr(line, 6));
                    else if (substr(line, 0, 8) == "#refresh:")
                        subscription_refresh = trim(substr(line, 8));
                }
                break;
            }
            log_message("Invalid olcrtc URI in subscription: " + parsed.reason, "warn");
        }
    }

    if (resolved == null) {
        if (room_id == "" || provider == "" || transport == "")
            return { valid: false, reason: "No valid connection found: set an olcrtc:// link or provider, transport and room_id" };
        if (index(olcrtc_validator.providers, provider) < 0)
            return { valid: false, reason: "provider must be one of: " + join(", ", olcrtc_validator.providers) };
        if (index(olcrtc_validator.transports, transport) < 0)
            return { valid: false, reason: "transport must be one of: " + join(", ", olcrtc_validator.transports) };
        if (!olcrtc_validator.valid_hex_key(crypto_key))
            return { valid: false, reason: "crypto_key must be 64 hex characters" };
        resolved = {
            provider: provider,
            transport: transport,
            room_id: room_id,
            crypto_key: crypto_key,
            payload: ""
        };
    }
    else {
        provider = resolved.provider;
        transport = resolved.transport;
        room_id = resolved.room_id;
        crypto_key = resolved.crypto_key;
    }

    return {
        valid: true,
        provider: provider,
        transport: transport,
        room_id: room_id,
        crypto_key: crypto_key,
        payload: resolved.payload,
        used_link: used_link,
        subscription_name: subscription_name,
        subscription_refresh: subscription_refresh
    };
}

function payload_option_mapping() {
    return {
        "vp8-fps": "vp8_fps",
        "vp8-batch": "vp8_batch",
        "fps": "sei_fps",
        "batch": "sei_batch",
        "frag": "sei_frag",
        "ack-ms": "sei_ack_ms",
        "video-w": "video_w",
        "video-h": "video_h",
        "video-fps": "video_fps",
        "video-bitrate": "video_bitrate",
        "video-hw": "video_hw",
        "video-codec": "video_codec",
        "video-qr-size": "video_qr_size",
        "video-qr-recovery": "video_qr_recovery",
        "video-tile-module": "video_tile_module",
        "video-tile-rs": "video_tile_rs"
    };
}

function payload_options(payload) {
    let options = {};
    if (payload == "" || payload == null)
        return options;
    let mapping = payload_option_mapping();
    for (let pair in split(payload, "&")) {
        let kv = split(pair, "=", 2);
        if (length(kv) == 2 && mapping[kv[0]] != null)
            options[mapping[kv[0]]] = kv[1];
    }
    return options;
}

// The YAML build uses a strict schema: unknown keys are fatal, so every field
// below is one the loader actually knows. Strings are always quoted to keep
// room IDs such as "yes" from being parsed as booleans; numeric fields stay
// unquoted because yaml.v3 does not coerce quoted strings into ints.
function yaml_string(value) {
    return "'" + replace(as_string(value), /'/g, "''") + "'";
}

function yaml_number(value) {
    value = trim(as_string(value));
    if (match(value, /^[0-9]+$/) == null)
        return null;
    return value;
}

function push_yaml_string(lines, key, value) {
    if (as_string(value) != "")
        push(lines, "  " + key + ": " + yaml_string(value));
}

function push_yaml_number(lines, key, value) {
    let number = yaml_number(value);
    if (number != null)
        push(lines, "  " + key + ": " + number);
}

function yaml_payload_blocks(payload) {
    let options = payload_options(payload);
    let blocks = [];

    let video = [];
    push_yaml_number(video, "width", options.video_w);
    push_yaml_number(video, "height", options.video_h);
    push_yaml_number(video, "fps", options.video_fps);
    push_yaml_string(video, "codec", options.video_codec);
    push_yaml_number(video, "qr_size", options.video_qr_size);
    push_yaml_string(video, "qr_recovery", options.video_qr_recovery);
    push_yaml_number(video, "tile_module", options.video_tile_module);
    push_yaml_number(video, "tile_rs", options.video_tile_rs);
    if (length(video) > 0) {
        push(blocks, "video:");
        for (let line in video)
            push(blocks, line);
    }

    let vp8 = [];
    push_yaml_number(vp8, "fps", options.vp8_fps);
    push_yaml_number(vp8, "batch_size", options.vp8_batch);
    if (length(vp8) > 0) {
        push(blocks, "vp8:");
        for (let line in vp8)
            push(blocks, line);
    }

    let sei = [];
    push_yaml_number(sei, "fps", options.sei_fps);
    push_yaml_number(sei, "batch_size", options.sei_batch);
    push_yaml_number(sei, "fragment_size", options.sei_frag);
    push_yaml_number(sei, "ack_timeout_ms", options.sei_ack_ms);
    if (length(sei) > 0) {
        push(blocks, "sei:");
        for (let line in sei)
            push(blocks, line);
    }

    return blocks;
}

function yaml_config_text(section, connection) {
    let socks_port = yaml_number(option_or_legacy(section, "socks_port", "olcrtc_socks_port", cfg.default_socks_port));
    if (socks_port == null)
        socks_port = yaml_number(cfg.default_socks_port);

    let lines = [
        "mode: cnc",
        "auth:",
        "  provider: " + yaml_string(connection.provider),
        "room:",
        "  id: " + yaml_string(connection.room_id),
        "crypto:",
        "  key: " + yaml_string(connection.crypto_key),
        "net:",
        "  transport: " + yaml_string(connection.transport),
        "  dns: " + yaml_string(option_or_legacy(section, "dns_server", "olcrtc_dns_server", cfg.default_dns)),
        "socks:",
        "  host: " + yaml_string(option_or_legacy(section, "socks_host", "olcrtc_socks_host", cfg.default_socks_host)),
        "  port: " + socks_port
    ];

    let socks_user = option(section, "socks_user", "");
    if (socks_user != "") {
        push(lines, "  user: " + yaml_string(socks_user));
        push(lines, "  pass: " + yaml_string(option(section, "socks_pass", "")));
    }

    for (let line in yaml_payload_blocks(connection.payload))
        push(lines, line);

    return join("\n", lines) + "\n";
}

function write_olcrtc_yaml_config(section, connection) {
    let path = cfg.config_path;
    let slash = rindex(path, "/");
    if (slash > 0)
        common.ensure_dir(substr(path, 0, slash));

    let tmp = path + ".tmp";
    if (fs.writefile(tmp, yaml_config_text(section, connection)) == null)
        return false;
    fs.chmod(tmp, 0600);
    if (!fs.rename(tmp, path)) {
        fs.unlink(tmp);
        return false;
    }
    fs.chmod(path, 0600);
    return true;
}

function start_runtime() {
    let sections = runtime_sections();
    if (length(sections) == 0) {
        stop_all_services();
        return true;
    }

    if (!provider_available()) {
        log_message("OlcRTC provider not available (binary not found: " + cfg.binary + ")", "fatal");
        return false;
    }

    if (length(sections) > 1)
        log_message("Multiple OlcRTC sections found, using first: " + section_name(sections[0]), "warn");

    let section = sections[0];
    let connection = resolve_connection(section);
    if (!connection.valid) {
        log_message("OlcRTC rule " + section_name(section) + ": " + connection.reason, "fatal");
        return false;
    }

    // The binary refuses to start without a key, so a keyless connection
    // would otherwise look "started" while no tunnel exists.
    if (as_string(connection.crypto_key) == "") {
        log_message("OlcRTC rule " + section_name(section) + ": crypto_key is required by the olcrtc service", "fatal");
        return false;
    }

    if (!service_init_exists(cfg.service_init)) {
        log_message("OlcRTC service init script not found: " + cfg.service_init, "fatal");
        return false;
    }

    if (!write_olcrtc_yaml_config(section, connection)) {
        log_message("Failed to write OlcRTC YAML config: " + cfg.config_path, "fatal");
        return false;
    }

    stop_legacy_services();

    if (!command_success_from_args([ cfg.service_init, "restart" ])) {
        log_message("Failed to restart OlcRTC service", "fatal");
        return false;
    }

    if (!wait_service_running(5)) {
        log_message("OlcRTC service reported no running instance after restart; check " + cfg.config_path + " and logread -e olcrtc", "fatal");
        return false;
    }

    log_message("OlcRTC provider started successfully (provider=" + connection.provider + ", transport=" + connection.transport + ")");
    return true;
}

function stop_runtime() {
    stop_all_services();
    log_message("OlcRTC provider stopped");
    return true;
}

function status_json() {
    let installed = provider_available();
    let running = installed ? service_running() : false;
    let enabled = installed ? service_enabled() : false;
    let rule_count = enabled_rule_count();
    let version = package_version();

    write_json({
        installed: installed,
        configured: rule_count > 0,
        enabled_rule_count: rule_count,
        service_enabled: enabled,
        service_running: running,
        config_path: cfg.config_path,
        binary: cfg.binary,
        service_init: cfg.service_init,
        ready: installed && running && rule_count > 0,
        status_message: running ? "olcrtc provider status is normal" : (installed ? "olcrtc service is not running" : "olcrtc is not installed")
    });
    return true;
}

function check_json() {
    write_json({
        olcrtc_installed: provider_available(),
        olcrtc_config_path: cfg.config_path
    });
    return true;
}

let mode = as_string(ARGV[0]);
if (mode == "start-runtime")
    start_runtime();
else if (mode == "stop-runtime")
    stop_runtime();
else if (mode == "status")
    status_json();
else if (mode == "check")
    check_json();
else if (mode == "installed" || mode == "provider-available")
    exit(provider_available() ? 0 : 1);
else if (mode == "package-version")
    printf("%s\n", package_version());
else if (mode == "enabled-rule-count")
    printf("%d\n", enabled_rule_count());
else {
    warn("Usage: olcrtc/runtime.uc <operation>\n");
    exit(1);
}
