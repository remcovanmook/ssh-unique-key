#!/bin/bash
set -e
SOURCE_DIR=$(cd "$(dirname "$0")/bin" && pwd)
TARGET_DIR="${HOME}/bin"
CONFIG_FILE="${HOME}/.ssh/config"
KEYS_DIR="${HOME}/.ssh/unique_keys"
INSTALL_LIB="${KEYS_DIR}/bin"

# Defaults
MODE="install"

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  uninstall          Uninstall the tool (removes symlinks and bin dir)."
    echo "  -h, --help         Show this help message."
    echo ""
}

# Parse Args
while [[ $# -gt 0 ]]; do
    case $1 in
        uninstall)
            MODE="uninstall"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

msg() { echo -e "\033[0;32m[+]\033[0m $*"; }
warn() { echo -e "\033[0;33m[!]\033[0m $*"; }
err() { echo -e "\033[0;31m[X]\033[0m $*" >&2; exit 1; }

get_config_block() {
    cat <<BLOCK
# --- SSH-UNIQUE-KEY START ---
Include ${KEYS_DIR}/config-top.d/*
Include ${KEYS_DIR}/by-key/%K/trusted.conf
IdentityFile ${KEYS_DIR}/by-key/%K/%r/identity
Include ${KEYS_DIR}/by-host/%h/config
IdentityFile ${KEYS_DIR}/by-host/%h/%r/identity
Include ${KEYS_DIR}/config-bottom.d/*
# --- SSH-UNIQUE-KEY END ---
BLOCK
}

setup_config() {
    msg "Setting up SSH config..."
    mkdir -p -m 700 "${HOME}/.ssh" && touch "$CONFIG_FILE"
    
    if grep -q "SSH-UNIQUE-KEY START" "$CONFIG_FILE"; then
         msg "Config already appears managed."
    else
         warn "Prepending configuration to $CONFIG_FILE"
         TMP=$(mktemp)
         get_config_block > "$TMP"
         echo "" >> "$TMP"
         cat "$CONFIG_FILE" >> "$TMP"
         mv "$TMP" "$CONFIG_FILE" && chmod 600 "$CONFIG_FILE"
         msg "Config updated."
    fi
    
    msg "Ensuring directory structure..."
    mkdir -p -m 700 "$KEYS_DIR"/{host-uuid,by-key,by-host,templates,config-top.d,config-bottom.d}
}

check_deps() {
    local missing=0
    for cmd in ssh ssh-keygen ssh-copy-id ssh-keyscan awk sed grep diff; do
        command -v "$cmd" &>/dev/null || { warn "Missing: $cmd"; missing=1; }
    done
    if [ "$missing" -eq 1 ]; then
        err "Install missing dependencies first."
    fi
}

do_install() {
    check_deps
    
    msg "Installing scripts to stable location $INSTALL_LIB..."
    mkdir -p -m 700 "$INSTALL_LIB"
    # Copy from repo source to stable lib dir, explicitly excluding directories/pycache
    find "$SOURCE_DIR" -maxdepth 1 -type f -not -name '.*' -exec cp -f {} "$INSTALL_LIB/" \;
    chmod +x "$INSTALL_LIB"/*

    # Copy lib/ assets (ssh-ui.py, requirements-ui.txt, ui/*)
    LIB_SRC_DIR="$(dirname "$SOURCE_DIR")/lib"
    LIB_DEST_DIR="$(dirname "$INSTALL_LIB")/lib"
    msg "Installing lib assets to $LIB_DEST_DIR..."
    mkdir -p "$LIB_DEST_DIR"
    cp -f "$LIB_SRC_DIR/ssh-ui.py" "$LIB_DEST_DIR/"
    cp -f "$LIB_SRC_DIR/requirements-ui.txt" "$LIB_DEST_DIR/"

    UI_SRC_DIR="$LIB_SRC_DIR/ui"
    UI_DEST_DIR="$LIB_DEST_DIR/ui"
    if [ -d "$UI_SRC_DIR" ]; then
        mkdir -p "$UI_DEST_DIR"
        find "$UI_SRC_DIR" -maxdepth 1 -type f -exec cp -f {} "$UI_DEST_DIR/" \;
    fi

    # Vendored web-UI assets (xterm.js). No network fetch: every byte the UI
    # serves is committed to the repo and hash-pinned in lib/ui/vendor/SHA384SUMS.
    VENDOR_SRC_DIR="$UI_SRC_DIR/vendor"
    if [ -d "$VENDOR_SRC_DIR" ]; then
        msg "Installing vendored UI assets..."
        mkdir -p "$UI_DEST_DIR/vendor"
        find "$VENDOR_SRC_DIR" -maxdepth 1 -type f -exec cp -f {} "$UI_DEST_DIR/vendor/" \;
    fi

    msg "Linking scripts to PATH ($TARGET_DIR)..."
    mkdir -p "$TARGET_DIR"
    for f in "$INSTALL_LIB"/*; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        target_link="$TARGET_DIR/$name"
        
        # Remove existing file/link to ensure clean update
        if [ -e "$target_link" ] || [ -L "$target_link" ]; then
            rm -f "$target_link"
        fi
        
        ln -s "$f" "$target_link"
        msg "  Linked $name"
    done
    
    setup_config
    msg "Installation complete."
}

if [ "$MODE" == "uninstall" ]; then
    warn "Removing symlinks..."
    for f in "$SOURCE_DIR"/*; do
        rm -f "$TARGET_DIR/$(basename "$f")"
    done
    
    warn "Removing installed binaries from $INSTALL_LIB..."
    rm -rf "$INSTALL_LIB"
    
    warn "Config and keys were NOT removed."
else
    do_install
fi
