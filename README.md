# ssh-unique-key

Automatically manages unique SSH keypairs per host so you can't be tracked by your public key.

## The Problem

Most people use a single SSH keypair across all their servers. That public key becomes a global identifier — it sits in `authorized_keys` on every host you access. Anyone who compromises one server (or has legitimate access to it) can take your public key and:

- Search other compromised hosts' `authorized_keys` for the same key
- Scan the internet (Shodan, Censys) for SSH servers that accept it
- Correlate your access across unrelated systems

Your SSH public key is effectively a tracking token.

## How ssh-unique-key Solves This

- **One key per host.** Every server gets its own unique keypair, generated automatically. Your public key on Server A exists nowhere else — it can't be used to find Server B.
- **Zero friction.** `ssh-new user@host` handles everything: scanning, key generation, deployment, and config. You keep using `ssh` normally.
- **Host identity by key.** As a side benefit, hosts are identified by their cryptographic public key rather than hostname. Rename a server or change its IP — the tool tracks it correctly.
- **Template support.** Use standard keys, hardware tokens (FIDO2/YubiKey), or OpenPubKey (opkssh with OIDC providers) across hosts.
- **Web UI.** Browser-based management with an integrated terminal for interactive operations (hardware key enrollment, opkssh login flows).

## Installation

```bash
./install.sh
```

This installs commands to `~/bin` (ensure it's in your `$PATH`) and stores key data in `~/.ssh/unique_keys`.

Options:

- `./install.sh --install-xterm` — include xterm.js assets for the web UI terminal
- `./install.sh --skip-xterm` — skip xterm.js assets
- `./install.sh uninstall` — remove all symlinks and installed files

The web UI requires Python 3. Dependencies are installed automatically in a virtual environment on first run of `ssh-ui`.

## Quick Start

### Provision a new host

```bash
ssh-new user@example.com
```

Scans the host, creates a unique identity, generates a keypair, pushes the public key, and logs you in.

### Use a hardware key (YubiKey)

```bash
ssh-template create work-yubikey
ssh-template generate-sk work-yubikey
ssh-new --template work-yubikey user@server.com
```

### Use OpenPubKey (opkssh)

```bash
ssh-template create my-opk
ssh-template generate-opk my-opk   # Supports 'google', 'gitlab', 'microsoft' shortcuts
ssh-new --template my-opk user@server.com
```

### Connect to legacy devices

```bash
ssh-new --legacy user@old-cisco-router
```

Enables deprecated algorithms (DSA, RSA-SHA1, CBC ciphers) only for that specific host, keeping your global SSH config secure.

## Commands

| Command | Description |
| :--- | :--- |
| `ssh-new` | Scan host, create identity, generate keys, deploy, and connect. |
| `ssh-del` | Remove keys for a user. Cleans up the host identity if no users remain. |
| `ssh-conf` | Edit host-specific SSH options (Port, Forwarding, etc.). |
| `ssh-template` | Manage key templates (standard, hardware, or OpenPubKey). |
| `ssh-rotate` | Rotate host keys when a server's host key changes. |
| `ssh-user-rotate` | Rotate a user's keypair for a specific host. |
| `ssh-template-rotate` | Rotate keys within a template (ed25519, ecdsa, or rsa). |
| `ssh-backup` | Create an encrypted archive of the key store. |
| `ssh-restore` | Restore keys from a backup archive. |
| `ssh-history` | View the operations log. |
| `ssh-ui` | Launch the web-based management interface. |

## Web UI

Start the web UI:

```bash
ssh-ui
```

Starts a local web server on a random port (localhost only). A URL with a one-time authentication token is printed on startup. The token is exchanged for an HTTP-only cookie on first visit, then stripped from the URL.

Features:

- **Dashboard** — overview of all host identities, their users, and keys. Connect, rotate, or delete directly from the browser.
- **Templates** — create and manage key templates. Hardware key enrollment and opkssh login run in an embedded terminal (xterm.js over websockets).
- **History** — searchable log of all operations.

The terminal integration handles interactive workflows (YubiKey touch prompts, OIDC browser login for opkssh) that would otherwise require the CLI.

## Architecture

All data lives under `~/.ssh/unique_keys`:

```text
~/.ssh/unique_keys/
  host-uuid/<sha256-hash>/    # One directory per host, named by host key hash
    config                    # Host-specific SSH config
    known_host_keys           # Stored host public keys
    <user>/                   # Per-user keypairs
  by-key/<base64-key> ->      # Symlinks by host public key (for %K token)
  by-host/<hostname>  ->      # Symlinks by hostname (fallback)
  templates/<name>/           # Key templates
  config-top.d/               # User config overrides (loaded first)
  config-bottom.d/            # Global defaults (loaded last)
  history.log                 # Operations log
```

Your `~/.ssh/config` gets these includes:

```text
Include config-top.d/*        # Your overrides
Include by-key/%K             # Cryptographic lookup (preferred)
Include by-host/%h            # Hostname fallback
Include config-bottom.d/*     # Global defaults
```

### Lookup Paths

**`by-key/%K` (primary):** When SSH connects and knows the host's public key, it resolves config via the base64-encoded key. This path is the identity proof itself — if the symlink exists, the host is verified. `StrictHostKeyChecking` is disabled on this path because the directory structure *is* the check.

**`by-host/%h` (fallback):** For first connections (before the key is known) or on systems without `%K` support (stock macOS SSH). Standard `known_hosts` verification applies.

## Security Model

### Anti-Tracking

The core goal. Each host gets a unique keypair, so your public key on one server can never be correlated with your access to any other server. There is no shared identifier across hosts.

### Blast Radius Reduction

A compromised key on Server A gives the attacker access to Server A only. The key exists nowhere else — no other server's `authorized_keys` contains it, and no internet scan (Shodan, Censys) can find your other servers using it.

### MITM Protection

`ssh-new` stores the server's full public key set on first contact. On subsequent runs (adding users, updating aliases), it re-scans and diffs the keys. If they've changed, it aborts with a security warning.

### Legacy Device Isolation

The `--legacy` flag injects deprecated algorithms only into the specific host's config file, not your global SSH configuration. Your security posture for modern hosts is unaffected.

### Hardware Tokens and OpenPubKey

- `generate-sk` creates FIDO2/U2F-backed keys (`ed25519-sk`) requiring physical touch.
- `generate-opk` integrates with OpenPubKey via opkssh. `ssh-new` validates certificates and triggers `opkssh login` (with optional issuer) when sessions expire, verifying the credential was updated before connecting.

## License

See [LICENSE](LICENSE) for details.
