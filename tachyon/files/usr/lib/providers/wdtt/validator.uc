let common = require("core.common");
let fs = require("fs");

let as_string = common.as_string;
let object_or_empty = common.object_or_empty;
let option_or_legacy = common.option_or_legacy;
let list_option_or_legacy = common.list_option_or_legacy;

function array_contains(arr, val) {
    if (type(arr) != "array")
        return false;
    for (let item in arr)
        if (item == val)
            return true;
    return false;
}

const WDTT_MODES = [ "selective", "lan-all", "full" ];
const WDTT_COMMUNITY_LISTS = [
    "russia-inside", "russia-outside", "ukraine", "telegram", "meta",
    "youtube", "discord", "tiktok", "twitter", "hdrezka", "roblox",
    "cloudflare", "cloudfront", "google_ai", "google_meet", "google_play",
    "hetzner", "ovh", "digitalocean", "anime", "news", "geoblock",
    "block", "porn", "hodca"
];

function url_decode(value) {
    let result = "";
    let len = length(value);
    let i = 0;
    while (i < len) {
        let ch = substr(value, i, 1);
        if (ch == '%' && i + 2 < len) {
            let pair = substr(value, i + 1, 2);
            let code = hex(pair);
            if (code != null)
                result += chr(code);
            else
                result += '%';
            i += 3;
        }
        else if (ch == '+') {
            result += ' ';
            i += 1;
        }
        else {
            result += ch;
            i += 1;
        }
    }
    return result;
}

function parse_query_string(query) {
    let params = {};
    if (query == "" || query == null)
        return params;
    let pairs = split(query, "&");
    for (let pair in pairs) {
        let kv = split(pair, "=", 2);
        if (length(kv) == 2)
            params[kv[0]] = url_decode(kv[1]);
        else if (length(kv) == 1)
            params[kv[0]] = "";
    }
    return params;
}

function valid_peer(value) {
    value = trim(as_string(value));
    if (value == "" || value == null)
        return true;
    return match(value, /^[^ \t\r\n:]+:[0-9]{1,5}$/) != null;
}

function is_wdtt_uri(value) {
    value = trim(as_string(value));
    return substr(value, 0, 8) == "qwdtt://" || substr(value, 0, 7) == "wdtt://";
}

function parse_wdtt_uri(value) {
    value = trim(as_string(value));
    if (!is_wdtt_uri(value))
        return { valid: false, reason: "URI must start with qwdtt:// or wdtt://" };

    let rest = substr(value, 0, 8) == "qwdtt://" ? substr(value, 8) : substr(value, 7);
    let hash_idx = index(rest, "#");
    let label = "";
    if (hash_idx >= 0) {
        label = substr(rest, hash_idx + 1);
        rest = substr(rest, 0, hash_idx);
    }

    let q_idx = index(rest, "?");
    let path = "";
    if (q_idx >= 0) {
        path = substr(rest, 0, q_idx);
        rest = substr(rest, q_idx + 1);
    }
    else if (index(rest, "=") < 0) {
        path = rest;
        rest = "";
    }
    path = trim(path);

    let params = parse_query_string(rest);
    let peer = params.peer || "";
    let hashes = params.hashes || "";
    let pass = params.pass || "";
    let workers = params.workers || "";
    let port = params.port || "";
    let name = params.name || "";

    if (peer == "")
        return { valid: false, reason: "URI must contain peer parameter" };
    if (!valid_peer(peer))
        return { valid: false, reason: "URI peer must be in HOST:PORT format" };

    return {
        valid: true,
        peer: peer,
        hashes: hashes,
        pass: pass,
        workers: workers,
        port: port,
        name: name,
        path: path,
        label: label
    };
}

function valid_device_id(value) {
    value = trim(as_string(value));
    if (value == "")
        return true;
    return length(value) <= 128 && match(value, /^[A-Za-z0-9._:-]+$/) != null;
}

function valid_url(value) {
    value = trim(as_string(value));
    if (value == "" || value == null)
        return true;
    return match(value, /^https?:\/\/[^ \t\r\n]+$/) != null;
}

function valid_number(value, min, max) {
    value = as_string(value);
    if (value == "" || value == null)
        return true;
    let num = int(value);
    if (num == null)
        return false;
    return num >= min && num <= max;
}

function normalize_mode(value) {
    if (value == "freedom")
        return "selective";
    if (value == "captive")
        return "lan-all";
    if (value == "camou")
        return "full";
    return value;
}

function valid_mode(value) {
    if (value == "" || value == null)
        return true;
    return array_contains(WDTT_MODES, normalize_mode(value));
}

function valid_community_list(value) {
    return array_contains(WDTT_COMMUNITY_LISTS, value);
}

function list_values(value) {
    if (type(value) == "array")
        return value;
    value = trim(as_string(value));
    if (value == "" || value == null)
        return [];
    return split(value, " \t\n\r");
}

function validation_result(valid, message, options) {
    let result = { valid: valid, message: message || "" };
    if (options != null)
        for (let key in options)
            result[key] = options[key];
    return result;
}

function validate_section(section) {
    let errors = [];

    let peer = as_string(section.peer || "");
    if (peer != "" && !valid_peer(peer))
        push(errors, "peer must be in HOST:PORT format");

    let mode = option_or_legacy(section, "mode", "warp_flow_mode", "");
    if (!valid_mode(mode))
        push(errors, "mode must be one of: " + join(", ", WDTT_MODES));

    let device_id = option_or_legacy(section, "device_id", "warp_flow_device_id", "");
    if (!valid_device_id(device_id))
        push(errors, "device_id must be 1-128 characters from A-Z, a-z, 0-9, '.', '_', ':' or '-'");

    let workers = option_or_legacy(section, "workers", "warp_flow_workers", "");
    if (workers != "" && !valid_number(workers, 1, 1024))
        push(errors, "workers must be 1-1024");

    let max_hashes = option_or_legacy(section, "max_hashes", "warp_flow_max_hashes", "");
    if (max_hashes != "" && !valid_number(max_hashes, 1, 64))
        push(errors, "max_hashes must be 1-64");

    let mtu = option_or_legacy(section, "mtu", "warp_flow_mtu", "");
    if (mtu != "" && !valid_number(mtu, 576, 1500))
        push(errors, "mtu must be 576-1500");

    let subscription_links = list_option_or_legacy(section, "subscription_links", "warp_flow_subscription_links");
    let uri = option_or_legacy(section, "uri", "warp_flow_uri", "");
    if (uri != "" && !array_contains(subscription_links, uri))
        push(subscription_links, uri);
    for (let link in subscription_links) {
        link = trim(as_string(link));
        if (link == "")
            continue;
        if (is_wdtt_uri(link)) {
            let parsed = parse_wdtt_uri(link);
            if (!parsed.valid)
                push(errors, "invalid WDTT URI: " + parsed.reason);
        }
        else if (substr(link, 0, 1) == "/") {
            /* local file — ok */
        }
        else if (!valid_url(link))
            push(errors, "subscription link must be HTTP URL, qwdtt:// URI, or local file path: " + link);
    }

    let community_lists = list_option_or_legacy(section, "community_lists", "warp_flow_community_lists");
    for (let cl in community_lists) {
        if (!valid_community_list(cl))
            push(errors, "unknown community list: " + cl);
    }

    return errors;
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function write_json(value) {
    printf("%s\n", sprintf("%J", value));
}

function validate_section_json() {
    let input = read_stdin();
    let data = object_or_empty(json(input));
    let errors = validate_section(data);
    if (length(errors) > 0)
        write_json({ valid: false, message: join("; ", errors) });
    else
        write_json({ valid: true, message: "" });
    return length(errors) == 0;
}

return {
    validate_section,
    validate_section_json,
    is_wdtt_uri,
    parse_wdtt_uri,
    url_decode,
    valid_peer,
    valid_device_id,
    valid_mode,
    valid_url,
    valid_community_list,
    list_values,
    modes: WDTT_MODES,
    community_lists: WDTT_COMMUNITY_LISTS
};
