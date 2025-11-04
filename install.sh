#!/bin/bash
set -e

# --- Configuration ---

# Add the include file to the list of files to link
SCRIPTS_TO_INSTALL=(
    "ssh-new"
    "ssh-del"
    "ssh-conf"
    "ssh-template"
    "_ssh-unique-key.inc.sh"
)

# Source and target directories
SOURCE_DIR=$(cd "$(dirname "$0")/bin" && pwd)
TARGET_DIR="${HOME}/bin" # Install to user's bin

# ... (rest of install.sh is the same) ...
# ... (logging functions, check_deps, check_path, setup_config) ...

do_install() {
    msg "Installing ssh-unique-key to $TARGET_DIR..."
    check_deps
    check_path
    
    msg "Setting executable permissions..."
    # Set +x on all scripts, though it's not needed for .inc
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
    
    warn "Note: This does not remove your ~/.ssh/unique_keys directory or your ~/.ssh/config entry."
    msg "Uninstallation complete."
}

# --- Main Logic ---

if [ "$1" == "uninstall" ]; then
    do_uninstall
else
    do_install
fi