#!/bin/bash
set -e
SOURCE_DIR=$(cd "$(dirname "$0")/bin" && pwd)
TARGET_DIR="${HOME}/bin"
CONFIG_FILE="${HOME}/.ssh/config"
KEYS_DIR="${HOME}/.ssh/unique_keys"
INSTALL_LIB="${KEYS_DIR}/bin"

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
    # Copy from repo source to stable lib dir
    cp -f "$SOURCE_DIR"/* "$INSTALL_LIB/"
    chmod +x "$INSTALL_LIB"/*

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

if [ "$1" == "uninstall" ]; then
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
