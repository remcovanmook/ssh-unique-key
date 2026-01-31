#!/bin/bash
set -e
SOURCE_DIR=$(cd "$(dirname "$0")/bin" && pwd)
TARGET_DIR="${HOME}/bin"
CONFIG_FILE="${HOME}/.ssh/config"
KEYS_DIR="${HOME}/.ssh/unique_keys"
INSTALL_LIB="${KEYS_DIR}/bin"

# Defaults
INSTALL_XTERM="ask"
MODE="install"

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --install-xterm    Force installation of xterm.js assets."
    echo "  --skip-xterm       Skip installation of xterm.js assets."
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
        --install-xterm)
            INSTALL_XTERM="yes"
            shift
            ;;
        --skip-xterm)
            INSTALL_XTERM="no"
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

    # Xterm Asset Logic
    if [ "$INSTALL_XTERM" == "ask" ]; then
        # Check if tty
        if [ -t 0 ]; then
            exec < /dev/tty
            read -p "Install xterm.js features (web terminal)? [Y/n] " response
            case "$response" in
                [yY]|[yY][eE][sS]|"") INSTALL_XTERM="yes" ;;
                *) INSTALL_XTERM="no" ;;
            esac
        else
            # Default to yes if non-interactive but not explicitly skipped?
            # Or default to no for safety?
            # User said "default is interactive", implying manual run. 
            # If scripts run this, they should use flags.
            # Let's default to yes if not specified in non-interactive for backward compat
            INSTALL_XTERM="yes"
            warn "Non-interactive mode detected. Defaulting to installing xterm.js."
        fi
    fi

    if [ "$INSTALL_XTERM" == "yes" ]; then
        # Download xterm assets
        # Using unpkg @latest and socket.io major version for updates
        UI_LIB_DIR="$(dirname "$SOURCE_DIR")/lib/ui/xterm"
        
        msg "Setting up xterm assets in $UI_LIB_DIR..."
        mkdir -p "$UI_LIB_DIR"
        
        # Download helper
        download_latest() {
            local url="$1"
            local dest="$2"
            
            msg "Downloading $(basename "$dest")..."
            if command -v curl &>/dev/null; then
                curl -L -s -o "$dest" "$url"
            elif command -v wget &>/dev/null; then
                wget -q -O "$dest" "$url"
            else
                warn "Could not download $(basename "$dest"): No curl or wget found."
            fi
        }

        download_latest "https://unpkg.com/xterm@latest/lib/xterm.js" "$UI_LIB_DIR/xterm.js"
        download_latest "https://unpkg.com/xterm@latest/css/xterm.css" "$UI_LIB_DIR/xterm.css"
        download_latest "https://unpkg.com/xterm-addon-fit@latest/lib/xterm-addon-fit.js" "$UI_LIB_DIR/xterm-addon-fit.js"
        # Using socket.io-client@4 from unpkg for dynamic 4.x updates
        download_latest "https://unpkg.com/socket.io-client@4/dist/socket.io.js" "$UI_LIB_DIR/socket.io.js"
    else
        msg "Skipping xterm.js assets."
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
