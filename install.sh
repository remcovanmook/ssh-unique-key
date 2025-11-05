#!/bin/bash
set -e

# --- Configuration ---

# List of all files to link into the user's bin
# This now includes the include file, so it's co-located.
SCRIPTS_TO_INSTALL=(
    "ssh-new"
    "ssh-del"
    "ssh-conf"
    "ssh-template"
    "_ssh-unique-key.inc.sh"
)

# Source directory (where this repo's scripts are)
SOURCE_DIR=$(cd "$(dirname "$0")/bin" && pwd)
# Target directory (user-local installation)
TARGET_DIR="${HOME}/bin"

CONFIG_FILE="${HOME}/.ssh/config"
KEYS_DIR="${HOME}/.ssh/unique_keys"
INCLUDE_LINE="Include ${KEYS_DIR}/conf.d/*"

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
    
    if [ "$missing_deps" -eq 1 ]; then
        err "Please install missing dependencies and re-run."
    fi
    msg "All dependencies satisfied."
}

check_path() {
    msg "Checking for $TARGET_DIR..."
    mkdir -p "$TARGET_DIR"
    
    # Check if $TARGET_DIR is in the PATH
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

setup_config() {
    msg "Setting up SSH config..."
    mkdir -p -m 700 "${HOME}/.ssh"
    touch "$CONFIG_FILE"
    
    if grep -qF "$INCLUDE_LINE" "$CONFIG_FILE"; then
        msg "SSH config already contains Include line. Skipping."
    else
        warn "Your $CONFIG_FILE needs to be updated."
        read -p "May I prepend '$INCLUDE_LINE' to it? (y/N) " confirm_config
        if [[ "$confirm_config" == "y" || "$confirm_config" == "Y" ]]; then
            TMP_FILE=$(mktemp)
            echo "$INCLUDE_LINE" > "$TMP_FILE"
            cat "$CONFIG_FILE" >> "$TMP_FILE"
            mv "$TMP_FILE" "$CONFIG_FILE"
            chmod 600 "$CONFIG_FILE"
            msg "Successfully updated $CONFIG_FILE."
        else
            warn "Please add the following line to the *top* of your $CONFIG_FILE manually:"
            warn "  $INCLUDE_LINE"
        fi
    fi
    
    # Ensure the keys directory structure exists
    msg "Ensuring base directory $KEYS_DIR exists..."
    mkdir -p -m 700 "$KEYS_DIR/conf.d"
    mkdir -p -m 700 "$KEYS_DIR/host-uuid"
    mkdir -p -m 700 "$KEYS_DIR/by-key"
    mkdir -p -m 700 "$KEYS_DIR/templates"
}

do_install() {
    msg "Installing ssh-unique-key to $TARGET_DIR..."
    check_deps
    check_path
    
    # Ensure scripts are executable
    msg "Setting executable permissions..."
    chmod +x "$SOURCE_DIR"/*
    
    msg "Linking scripts to $TARGET_DIR..."
    
    for script in "${SCRIPTS_TO_INSTALL[@]}"; do
        SOURCE_FILE="$SOURCE_DIR/$script"
        TARGET_FILE="$TARGET_DIR/$script"
        
        if [ ! -f "$SOURCE_FILE" ]; then
            err "Source file not found: $SOURCE_FILE. Aborting."
        fi
        
        if [ -f "$TARGET_FILE" ] && [ ! -L "$TARGET_FILE" ]; then
            err "A file already exists at $TARGET_FILE (and it's not a symlink). Please remove it."
        fi
        
        msg "Linking $SOURCE_FILE to $TARGET_FILE..."
        # Use -sf to force overwrite of existing symlinks
        ln -sf "$SOURCE_FILE" "$TARGET_FILE"
    done
    
    # Set up user's config file
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
    
    warn "Note: This does not remove your ~/.ssh/unique_keys directory or your ~/.ssh/config entry."
    msg "Uninstallation complete."
}

# --- Main Logic ---

if [ "$1" == "uninstall" ]; then
    do_uninstall
else
    do_install
fi