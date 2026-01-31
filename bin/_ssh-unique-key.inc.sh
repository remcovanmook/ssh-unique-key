#!/bin/bash

# --- Script Execution Guard ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This is an include file and should not be executed directly." >&2
    exit 1
fi

# --- Version ---
SSHK_VERSION="260108-01"

# --- Configuration Variables ---
BASE_DIR="${HOME}/.ssh/unique_keys"
UUID_DIR="${BASE_DIR}/host-uuid"
KEY_DIR="${BASE_DIR}/by-key"
HOST_DIR="${BASE_DIR}/by-host"
TEMPLATE_DIR="${BASE_DIR}/templates"
CONF_TOP_DIR="${BASE_DIR}/config-top.d"
CONF_BOT_DIR="${BASE_DIR}/config-bottom.d"
LOG_FILE="${BASE_DIR}/history.log"

# Default Verbosity
VERBOSE=0

# --- Utility Functions ---
err() {
    echo -e "\033[0;31m[ERROR]\033[0m $*" >&2
    exit 1
}

warn() {
    echo -e "\033[0;33m[WARN]\033[0m $*" >&2
}

info() {
    echo -e "\033[0;32m[INFO]\033[0m $*" >&2
}

debug() {
    if [ "$VERBOSE" -eq 1 ]; then
        echo -e "\033[0;36m[DEBUG]\033[0m $*" >&2
    fi
}

show_version() {
    echo "ssh-unique-key version $SSHK_VERSION"
    exit 0
}

log_event() {
    local ACTION="$1"
    local TARGET="$2"
    local DETAILS="$3"
    local TS
    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
    fi
    echo "$TS|$USER|$ACTION|$TARGET|$DETAILS" >> "$LOG_FILE"
    debug "Logged event: $ACTION $TARGET"
}

ensure_base_dirs() {
    mkdir -p -m 700 "$BASE_DIR" "$UUID_DIR" "$KEY_DIR" "$HOST_DIR" "$TEMPLATE_DIR" "$CONF_TOP_DIR" "$CONF_BOT_DIR"
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
    fi
}

get_host_from_arg() { echo "$1" | sed 's/.*@//'; }
get_user_from_arg() { if [[ "$1" == *"@"* ]]; then echo "$1" | sed 's/@.*//'; else echo "$USER"; fi; }

get_uuid_path_from_host() {
    local LINK_PATH="$HOST_DIR/$1"
    if [ ! -L "$LINK_PATH" ]; then return 1; fi
    local REAL_PATH
    REAL_PATH=$(cd "$HOST_DIR" && readlink -f "$LINK_PATH")
    if [ ! -d "$REAL_PATH" ]; then err "Symlink broken for '$1'."; fi
    echo "$REAL_PATH"
}

# --- Scan & Auth Functions ---
get_full_host_scan() {
    local DATA
    debug "Running ssh-keyscan on $1..."
    DATA=$(ssh-keyscan "$1" 2>/dev/null | grep -v "^#")
    if [ -z "$DATA" ]; then return 1; fi
    echo "$DATA"
}

get_host_uuid_from_scan_data() {
    local DATA="$1"
    local BEST_KEY
    BEST_KEY=$(echo "$DATA" | awk '/ssh-ed25519/{k=$3} /ecdsa/{if(!k)k=$3} /ssh-rsa/{if(!k)k=$3} END{print k}')
    if [ -z "$BEST_KEY" ]; then err "No usable key found in scan data."; fi
    
    local HASH
    if command -v shasum >/dev/null; then
        HASH=$(echo -n "$BEST_KEY" | shasum -a 256 | awk '{print $1}')
    else
        HASH=$(echo -n "$BEST_KEY" | sha256sum | awk '{print $1}')
    fi
    debug "Derived Host UUID: $HASH"
    echo "$HASH"
}

get_key_hash() {
    local KEY_DATA="$1"
    local HASH
    if command -v shasum >/dev/null; then
        HASH=$(echo -n "$KEY_DATA" | shasum -a 256 | awk '{print $1}')
    else
        HASH=$(echo -n "$KEY_DATA" | sha256sum | awk '{print $1}')
    fi
    echo "$HASH"
}

get_best_key_type_from_scan_data() {
    local TYPE
    TYPE=$(echo "$1" | awk '/ssh-ed25519/{e=1} /ecdsa/{c=1} /ssh-rsa/{r=1} END{if(e)print "ed25519"; else if(c)print "ecdsa"; else if(r)print "rsa"; else print "rsa"}')
    debug "Best key type selected: $TYPE"
    echo "$TYPE"
}

check_key_auth_support() {
    local HOST="$1"
    debug "Checking publickey auth support for $HOST..."
    local OUTPUT
    OUTPUT=$(ssh -o PreferredAuthentications=none -o ConnectTimeout=5 "$HOST" 2>&1 || true)
    if echo "$OUTPUT" | grep -q "publickey"; then
        debug "Host supports publickey auth."
        return 0
    else
        debug "Host does NOT support publickey auth. Output: $OUTPUT"
        return 1
    fi
}

get_legacy_options() {
    echo "KexAlgorithms +diffie-hellman-group1-sha1,diffie-hellman-group14-sha1"
    echo "HostKeyAlgorithms +ssh-rsa,ssh-dss"
    echo "Ciphers +aes128-cbc,3des-cbc,aes256-cbc"
    echo "PubkeyAcceptedAlgorithms +ssh-rsa"
}

check_cert_validity() {
    local CERT_FILE="$1"
    if [ ! -f "$CERT_FILE" ]; then return 1; fi
    local VALIDITY_LINE
    VALIDITY_LINE=$(ssh-keygen -L -f "$CERT_FILE" | grep "Valid:")
    if [ -z "$VALIDITY_LINE" ]; then return 1; fi
    
    local EXPIRY_STR
    EXPIRY_STR=$(echo "$VALIDITY_LINE" | sed 's/.*to //')
    local EXPIRY_EPOCH
    local CURRENT_EPOCH
    CURRENT_EPOCH=$(date +%s)

    if date -d "2024-01-01" >/dev/null 2>&1; then
        EXPIRY_EPOCH=$(date -d "$EXPIRY_STR" +%s 2>/dev/null)
    else
        EXPIRY_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$EXPIRY_STR" +%s 2>/dev/null)
    fi

    if [ -z "$EXPIRY_EPOCH" ]; then return 1; fi
    if [ "$CURRENT_EPOCH" -ge "$((EXPIRY_EPOCH - 60))" ]; then
        debug "Certificate expired. Current: $CURRENT_EPOCH, Expiry: $EXPIRY_EPOCH"
        return 1 
    fi
    return 0
}
