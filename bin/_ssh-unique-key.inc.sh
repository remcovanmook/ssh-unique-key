#!/bin/bash

# --- Script Execution Guard ---
# Check if the script is being sourced or executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This is an include file and should not be executed directly." >&2
    exit 1
fi
# --- End Guard ---

# --- Configuration Variables ---
BASE_DIR="${HOME}/.ssh/unique_keys"
UUID_DIR="${BASE_DIR}/host-uuid"
KEY_DIR="${BASE_DIR}/by-key"
HOST_DIR="${BASE_DIR}/by-host"
TEMPLATE_DIR="${BASE_DIR}/templates"

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
    mkdir -p -m 700 "$HOST_DIR"
    mkdir -p -m 700 "$TEMPLATE_DIR"
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

# Finds the canonical host-uuid path from the by-host symlink
get_uuid_path_from_host() {
    local HOST_NAME="$1"
    local LINK_PATH="$HOST_DIR/$HOST_NAME"
    [ ! -L "$LINK_PATH" ] && return 1 # Not found
    
    local REAL_UUID_PATH
    REAL_UUID_PATH=$(cd "$HOST_DIR" && readlink -f "$LINK_PATH")
    
    [ ! -d "$REAL_UUID_PATH" ] && err "Host symlink for '$HOST_NAME' is broken."
    echo "$REAL_UUID_PATH"
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
        # Scan all lines and store the key data for each type found
        /ssh-ed25519/ {
            key_ed25519=$3
        }
        /ecdsa/ {
            key_ecdsa=$3
        }
        /ssh-rsa/ {
            key_rsa=$3
        }
        
        # After checking all lines, print the best one found
        END {
            if (key_ed25519) {
                print key_ed25519
            } else if (key_ecdsa) {
                print key_ecdsa
            } else if (key_rsa) {
                print key_rsa
            }
        }
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
        # Scan all lines and set a flag for each key type found
        /ssh-ed25519/ {
            found_ed25519=1
        }
        /ecdsa/ {
            found_ecdsa=1
        }
        /ssh-rsa/ {
            found_rsa=1
        }
        
        # After checking all lines, decide the winner
        END {
            if (found_ed25519) {
                print "ed25519"
            } else if (found_ecdsa) {
                print "ecdsa"
            } else if (found_rsa) {
                print "rsa"
            } else {
                # Default fallback if scan data contained no usable keys
                print "rsa"
            }
        }
    ')
    echo "$KEY_TYPE"
}