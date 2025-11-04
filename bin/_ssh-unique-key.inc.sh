#!/bin/bash

# --- Script Execution Guard ---
# Check if the script is being sourced or executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This is an include file and should not be executed directly." >&2
    exit 1
fi
# --- End Guard ---

# --- Constants ---
VALID_KEY_TYPES=("ed25519" "ecdsa" "rsa")
KEYSCAN_TIMEOUT=10
LOG_FILE="${HOME}/.ssh/unique_keys/ssh-unique-key.log"
HISTORY_FILE="${HOME}/.ssh_history"
HISTORY_FORMAT_VERSION="1.0"

# --- Enhanced Logging System ---

# Format and write an entry to the SSH history file
write_history() {
    local action="$1"
    shift
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local entry="{\"timestamp\":\"$timestamp\",\"user\":\"$USER\",\"action\":\"$action\",\"data\":$*}"
    echo "$entry" >> "$HISTORY_FILE"
    chmod 600 "$HISTORY_FILE"
}

# Log key installation
log_key_install() {
    local key_type="$1"
    local user_host="$2"
    local key_path="$3"
    local template="$4"
    local json="{\"key_type\":\"$key_type\",\"user_host\":\"$user_host\",\"key_path\":\"$key_path\",\"template\":\"$template\"}"
    write_history "key_install" "$json"
}

# Log key removal
log_key_remove() {
    local user_host="$1"
    local key_path="$2"
    local json="{\"user_host\":\"$user_host\",\"key_path\":\"$key_path\"}"
    write_history "key_remove" "$json"
}

# Log template operations
log_template_operation() {
    local operation="$1"
    local template="$2"
    local details="$3"
    local json="{\"operation\":\"$operation\",\"template\":\"$template\",\"details\":\"$details\"}"
    write_history "template_operation" "$json"
}

# Log host key changes
log_host_key_change() {
    local host="$1"
    local old_uuid="$2"
    local new_uuid="$3"
    local json="{\"host\":\"$host\",\"old_uuid\":\"$old_uuid\",\"new_uuid\":\"$new_uuid\"}"
    write_history "host_key_change" "$json"
}

# Log backup/restore operations
log_backup_operation() {
    local operation="$1"
    local path="$2"
    local json="{\"operation\":\"$operation\",\"path\":\"$path\"}"
    write_history "backup_operation" "$json"
}

# Standard logging function
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG_FILE"
}

err() {
    local msg="$*"
    log "ERROR" "$msg"
    echo "Error: $msg" >&2
    exit 1
}

warn() {
    local msg="$*"
    log "WARN" "$msg"
    echo "Warning: $msg" >&2
}

# --- Configuration Variables ---
BASE_DIR="${HOME}/.ssh/unique_keys"
UUID_DIR="${BASE_DIR}/host-uuid"
KEY_DIR="${BASE_DIR}/by-key"
TEMPLATE_DIR="${BASE_DIR}/templates"
CONFIG_DIR="${BASE_DIR}/conf.d"
BACKUP_DIR="${BASE_DIR}/backups"

# --- Validation Functions ---
validate_hostname() {
    local hostname="$1"
    # Basic hostname validation (allows IP addresses and hostnames)
    if [[ ! "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-\.]*[a-zA-Z0-9])?$ ]]; then
        err "Invalid hostname: $hostname"
    fi
}

# --- Template Functions ---
validate_template() {
    local template_name="$1"
    local template_path="$TEMPLATE_DIR/$template_name"
    
    if [ ! -d "$template_path" ]; then
        err "Template not found: $template_name"
    fi
}

get_hosts_using_template() {
    local template_name="$1"
    local hosts=()
    
    # Search all config snippets for the template
    while IFS= read -r config_file; do
        if grep -q "templates/$template_name/config" "$config_file" 2>/dev/null; then
            hosts+=("$(basename "$config_file")")
        fi
    done < <(find "$CONFIG_DIR" -type f 2>/dev/null)
    
    echo "${hosts[@]}"
}

get_template_key_types() {
    local template_name="$1"
    local template_path="$TEMPLATE_DIR/$template_name"
    local key_types=()
    
    for type in "${VALID_KEY_TYPES[@]}"; do
        if [ -f "$template_path/id_$type" ]; then
            key_types+=("$type")
        fi
    done
    
    echo "${key_types[@]}"
}
}

validate_key_type() {
    local key_type="$1"
    for valid_type in "${VALID_KEY_TYPES[@]}"; do
        if [[ "$key_type" == "$valid_type" ]]; then
            return 0
        fi
    done
    err "Invalid key type: $key_type. Must be one of: ${VALID_KEY_TYPES[*]}"
}

validate_file_permissions() {
    local file="$1"
    local required_perms="$2"
    local actual_perms
    
    actual_perms=$(stat -f "%Lp" "$file" 2>/dev/null)
    if [[ "$actual_perms" != "$required_perms" ]]; then
        err "Invalid permissions on $file: expected $required_perms, got $actual_perms"
    fi
}
CONFIG_DIR="${BASE_DIR}/conf.d"

# --- Utility Functions ---

# Prints a formatted error message to stderr and exits
err() {
    echo "Error: $@" >&2
    exit 1
}

# Ensures base structure is in place with strict permissions
ensure_base_dirs() {
    mkdir -p -m 700 "$BASE_DIR"
    mkdir -p -m 700 "$UUID_DIR"
    mkdir -p -m 700 "$KEY_DIR"
    mkdir -p -m 700 "$TEMPLATE_DIR"
    mkdir -p -m 700 "$CONFIG_DIR"
}

# Extracts the host from a 'user@host' string
get_host_from_arg() {
    echo "$1" | sed 's/.*@//'
}

# Extracts the user from 'user@host', defaulting to $USER
get_user_from_arg() {
    if [[ "$1" == *"@"* ]]; then
        echo "$1" | sed 's/@.*//'
    else
        echo "$USER"
    fi
}

# Finds the canonical host-uuid path from a config snippet
get_uuid_path_from_host() {
    local HOST_NAME="$1"
    local CONFIG_SNIPPET_FILE="$CONFIG_DIR/$HOST_NAME"
    [ ! -f "$CONFIG_SNIPPET_FILE" ] && return 1 # Not found
    
    local HOST_UUID
    HOST_UUID=$(grep "UUID:" "$CONFIG_SNIPPET_FILE" | awk '{print $3}')
    
    [ -z "$HOST_UUID" ] && err "Could not parse UUID from $CONFIG_SNIPPET_FILE."
    echo "$UUID_DIR/$HOST_UUID"
}

# --- Core Scan Functions ---

# 1. Runs ssh-keyscan and returns the full, raw output (no comments)
get_full_host_scan() {
    local TARGET_HOST="$1"
    [ -z "$TARGET_HOST" ] && err "get_full_host_scan: No host specified."
    
    local SCAN_DATA
    SCAN_DATA=$(ssh-keyscan "$TARGET_HOST" 2>/dev/null | grep -v "^#")
    
    [ -z "$SCAN_DATA" ] && err "Could not retrieve any public keys from $TARGET_HOST. Aborting."
    echo "$SCAN_DATA"
}

# 2. Takes raw scan data (as text), finds the best key, and returns its HASH
get_host_uuid_from_scan_data() {
    local SCAN_DATA="$1"
    local KEY_DATA
    KEY_DATA=$(echo "$SCAN_DATA" | awk '
        /ssh-ed25519/ { print $3; found=1; exit }
        /ecdsa/ { if (!found) { best_key=$3; found=2 } }
        /ssh-rsa/ { if (!found) { best_key=$3; found=3 } }
        END { if (found) { print best_key } }
    ')
    
    [ -z "$KEY_DATA" ] && err "Could not parse key data from scan."
    
    # Hash the key data to create our stable, filesystem-safe UUID
    if command -v shasum >/dev/null; then
        echo -n "$KEY_DATA" | shasum -a 256 | awk '{print $1}'
    else
        echo -n "$KEY_DATA" | sha256sum | awk '{print $1}'
    fi
}

# 3. Takes raw scan data (as text), finds the best key, and returns its TYPE
get_best_key_type_from_scan_data() {
    local SCAN_DATA="$1"
    local KEY_TYPE
    KEY_TYPE=$(echo "$SCAN_DATA" | awk '
        /ssh-ed25519/ { print "ed25519"; found=1; exit }
        /ecdsa/ { if (!found) { best_type="ecdsa"; found=2 } }
        /ssh-rsa/ { if (!found) { best_type="rsa"; found=3 } }
        END { if (found) { print best_type } else { print "rsa" } }
    ')
    echo "$KEY_TYPE"
}