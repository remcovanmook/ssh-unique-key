#!/bin/bash
set -e

# --- Configuration ---
SCRIPTS_TO_INSTALL=(
    "ssh-new"
    "ssh-del"
    "ssh-conf"
    "ssh-template"
    "_ssh-unique-key.inc.sh"
)
SOURCE_DIR=$(cd "$(dirname "$0")/bin" && pwd)
TARGET_DIR="${HOME}/bin"
CONFIG_FILE="${HOME}/.ssh/config"
KEYS_DIR="${HOME}/.ssh/unique_keys"

# --- SSH Config Lines ---
INCLUDE_LINE_K="Include ${KEYS_DIR}/by-key/%K"
IDENTITY_LINE_K="IdentityFile ${KEYS_DIR}/by-key/%K/%r/identity"
INCLUDE_LINE_H="Include ${KEYS_DIR}/by-host/%h"
IDENTITY_LINE_H="IdentityFile ${KEYS_DIR}/by-host/%h/%r/identity"


# --- Logging Functions ---
msg() {
    echo -e "[+] ${1}"
}
warn() {
    echo -e "[!] ${1}"
}
err() {
    echo -e "[X] ${1}" >&2
    exit 1
}

# --- Functions ---

check_deps() {
    msg "Checking dependencies..."
    local missing_deps=0
    for cmd in ssh ssh-keygen ssh-copy-id ssh-keyscan awk sed grep diff; do
        if ! command -v "$cmd" &> /dev/null; then
            warn "Missing required dependency: '$cmd'."
            missing_deps=1
        fi
    done
    [ "$missing_deps" -eq 1 ] && err "Please install missing dependencies."
    msg "All dependencies satisfied."
}

check_path() {
    msg "Checking for $TARGET_DIR..."
    mkdir -p "$TARGET_DIR"
    if [[ ":$PATH:" != *":$TARGET_DIR:"* ]]; then
        warn "Your PATH does not seem to include $TARGET_DIR."
        warn "Please add the following line to your ~/.bashrc or ~/.zshrc:"
        warn "  export PATH=\"\$PATH:$TARGET_DIR\""
        read -p "Continue installation anyway? (y/N) " confirm_path
        if [[ "$confirm_path" != "y" && "$confirm_path" != "Y" ]]; then
            err "Installation aborted. Please update your PATH."
        fi
    fi
}

check_k_support() {
    msg "Checking for %K token support in your SSH client..."
    if ! ssh -G -o "ExitOnForwardFailure=%K" dummyhost 2>/dev/null; then
        warn "Your SSH client does not support the %K token (common on stock macOS)."
        warn "Falling back to %h (hostname) lookup only."
        echo "false"
    else
        msg "SSH client supports %K."
        echo "true"
    fi
}

setup_config() {
    local HAS_K_SUPPORT
    HAS_K_SUPPORT=$(check_k_support)
    
    msg "Setting up SSH config..."
    mkdir -p -m 700 "${HOME}/.ssh"
    touch "$CONFIG_FILE"
    
    local CONFIG_OK=1
    
    if [ "$HAS_K_SUPPORT" == "true" ]; then
        # Check for all four lines
        if ! grep -qF "$INCLUDE_LINE_K" "$CONFIG_FILE"; then CONFIG_OK=0; fi
        if ! grep -qF "$IDENTITY_LINE_K" "$CONFIG_FILE"; then CONFIG_OK=0; fi
        if ! grep -qF "$INCLUDE_LINE_H" "$CONFIG_FILE"; then CONFIG_OK=0; fi
        if ! grep -qF "$IDENTITY_LINE_H" "$CONFIG_FILE"; then CONFIG_OK=0; fi
    else
        # Check for only the host lines
        if ! grep -qF "$INCLUDE_LINE_H" "$CONFIG_FILE"; then CONFIG_OK=0; fi
        if ! grep -qF "$IDENTITY_LINE_H" "$CONFIG_FILE"; then CONFIG_OK=0; fi
        # Also check that the %K lines aren't present
        if grep -qF "$INCLUDE_LINE_K" "$CONFIG_FILE"; then
            warn "Your config contains the %K lookup, but your SSH client doesn't support it."
        fi
    fi
    
    if [ "$CONFIG_OK" -eq 1 ]; then
        msg "SSH config is already set up. Skipping."
    else
        warn "Your $CONFIG_FILE needs to be updated."
        read -p "May I prepend the required Include line(s) to it? (y/N) " confirm_config
        if [[ "$confirm_config" == "y" || "$confirm_config" == "Y" ]]; then
            TMP_FILE=$(mktemp)
            
            if [ "$HAS_K_SUPPORT" == "true" ]; then
                echo "$INCLUDE_LINE_K" >> "$TMP_FILE"
                echo "$IDENTITY_LINE_K" >> "$TMP_FILE"
            fi
            echo "$INCLUDE_LINE_H" >> "$TMP_FILE"
            echo "$IDENTITY_LINE_H" >> "$TMP_FILE"
            
            echo "" >> "$TMP_FILE"
            cat "$CONFIG_FILE" >> "$TMP_FILE"
            mv "$TMP_FILE" "$CONFIG_FILE"
            chmod 600 "$CONFIG_FILE"
            msg "Successfully updated $CONFIG_FILE."
        else
            warn "Please add the following line(s) to the *top* of your $CONFIG_FILE manually:"
            if [ "$HAS_K_SUPPORT" == "true" ]; then
                warn "  $INCLUDE_LINE_K"
                warn "  $IDENTITY_LINE_K"
            fi
            warn "  $INCLUDE_LINE_H"
            warn "  $IDENTITY_LINE_H"
        fi
    fi
    
    # Ensure the keys directory structure exists
    msg "Ensuring base directory $KEYS_DIR exists..."
    mkdir -p -m 700 "$KEYS_DIR/host-uuid"
    mkdir -p -m 700 "$KEYS_DIR/by-key"
    mkdir -p -m 700 "$KEYS_DIR/by-host"
    mkdir -p -m 700 "$KEYS_DIR/templates"
}

do_install() {
    msg "Installing ssh-unique-key to $TARGET_DIR..."
    check_deps
    check_path
    
    msg "Setting executable permissions..."
    chmod +x "$SOURCE_DIR"/*
    
    msg "Linking scripts to $TARGET_DIR..."
    for script in "${SCRIPTS_TO_INSTALL[@]}"; do
        SOURCE_FILE="$SOURCE_DIR/$script"
        TARGET_FILE="$TARGET_DIR/$script"
        
        [ ! -f "$SOURCE_FILE" ] && err "Source file not found: $SOURCE_FILE."
        [ -f "$TARGET_FILE" ] && [ ! -L "$TARGET_FILE" ] && err "File exists at $TARGET_FILE. Please remove it."
        
        ln -sf "$SOURCE_FILE" "$TARGET_FILE"
    done
    
    setup_config
    
    msg "Installation complete."
    warn "If $TARGET_DIR was not in your PATH, you may need to restart your shell."
}

do_uninstall() {
    warn "Uninstalling ssh-unique-key..."
    
    for script in "${SCRIPTS_TO_INSTALL[@]}"; do
        TARGET_FILE="$TARGET_DIR/$script"
        if [ -L "$TARGET_FILE" ]; then
            msg "Removing $TARGET_FILE..."
            rm "$TARGET_FILE"
        fi
    done
    
    warn "Note: This does not remove your ~/.ssh/unique_keys directory or your ~/.ssh/config entries."
    msg "Uninstallation complete."
}

# --- Main Logic ---

if [ "$1" == "uninstall" ]; then
    do_uninstall
else
    do_install
fi