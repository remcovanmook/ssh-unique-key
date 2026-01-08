# ssh-unique-key

A production-ready toolkit to manage SSH identities based on **cryptographic host identity** rather than just hostnames.

## Why this exists

Traditional SSH key management relies on `~/.ssh/known_hosts` and assumes that if a hostname (`db-prod`) points to a new IP, it's the same server. In cloud environments, `db-prod` might be rebuilt daily with a new identity.

**ssh-unique-key** changes the paradigm:
1.  **One Key Per Host:** Every host gets its own unique key pair (or a specific template key).
2.  **Identity First:** Hosts are recognized by their public key. If you move a server to a new domain name, this tool knows it's the *same* server and uses the correct credentials.
3.  **Scanning Mitigation:** Since your public key is unique to that specific host, attackers cannot scan the internet to find other servers you have access to.

## 🚀 Quick Start

```bash
./install.sh
```
Ensure `~/bin` is in your `$PATH`.

### Provision a new host
```bash
ssh-new user@example.com
```
This scans the host, creates a unique identity, pushes the key, and logs you in.

### Use a Template (e.g., for hardware keys)
```bash
ssh-template create work-yubikey
ssh-template generate-sk work-yubikey  # Generates hardware-backed key
ssh-new --template work-yubikey --comment "Touch YubiKey" user@server.com
```

### Use OpenPubKey (opkssh)
```bash
ssh-template create my-opk
# Follow prompts to login (supports 'google', 'gitlab', 'microsoft' shortcuts) and import
ssh-template generate-opk my-opk 
ssh-new --template my-opk user@server.com
```

## 🏗️ Architecture

The system uses a central storage in `~/.ssh/unique_keys`:

1.  **`host-uuid/` (Source of Truth):**
    * Named by the SHA256 hash of the host's public key.
    * Contains `config` (host options), `known_host_keys`, and user keys.
2.  **`by-key/` (Secure Lookup):**
    * Symlinks based on the base64 host key (e.g., `%K`).
    * Used by SSH clients that support the `%K` token (OpenSSH).
    * **Trusts the lookup:** Disables `StrictHostKeyChecking` because reaching this path proves the host identity is verified.
3.  **`by-host/` (Fallback Lookup):**
    * Symlinks based on hostname (`%h`).
    * Used for new hosts (before key is known) or on systems lacking `%K` support (stock macOS).

## 🔒 Security Considerations

### 1. The Trust Model
This tool separates trust into two layers:
* **Cryptographic Path Trust (`by-key`):** When SSH resolves a config via `%K`, we **disable** `StrictHostKeyChecking`. Why? Because the directory path *is* the check. We only create that symlink if the host's key hash matches our stored `host-uuid`. This eliminates annoying "Host key changed" errors for valid renames while maintaining cryptographic integrity.
* **Standard Trust (`by-host`):** When falling back to hostname lookup, standard `known_hosts` verification is active.

### 2. MITM Protection
`ssh-new` permanently stores the server's full public key set. Every time you run `ssh-new` (e.g., to add a user or update an alias), it re-scans and `diff`s the keys. If they have changed, it aborts with a **SECURITY WARNING**.

### 3. Blast Radius Reduction
By default, `ssh-new` generates a unique keypair for every single host.
* **Scenario:** You access 100 servers.
* **Compromise:** Server A is hacked and your private key *for that server* is stolen.
* **Impact:** The attacker gains access to... Server A.
* **Scanning:** The attacker cannot take that public key and scan the internet (Shodan/Censys) to find your other 99 servers, because that key exists nowhere else.

### 4. Legacy Systems
Some older devices (Cisco routers, old Linux) only support deprecated algorithms (DSA, RSA-SHA1, CBC ciphers).
* **Risk:** Enabling these globally weakens your security posture.
* **Solution:** Use `ssh-new --legacy user@old-host`. This injects the insecure algorithms **only** into that specific host's config file (`host-uuid/<hash>/config`), leaving your default SSH configuration secure.

### 5. Hardware Tokens (YubiKey) & OpenPubKey
* `ssh-template generate-sk` creates FIDO2/U2F backed keys (`ed25519-sk`).
* `ssh-template generate-opk` integrates with OpenPubKey (OIDC). `ssh-new` will automatically validate your certificate and trigger `opkssh login` (optionally with a specific Issuer) if your session has expired. The script verifies that the credential file was actually updated before connecting.

## 🛠️ Commands

| Command | Description |
| :--- | :--- |
| `ssh-new` | Main tool. Scans host, creates keys/config, links everything. |
| `ssh-del` | Safely removes keys for a user. Cleans up host if empty. |
| `ssh-template` | Manage templates (standard, hardware, or OPK). |
| `ssh-conf` | Edit host-specific options (Port, Forwarding). |
| `ssh-history` | View operations log. |
| `ssh-backup` | Backup key store to archive. |
| `ssh-restore` | Restore keys from archive. |

## ⚙️ Configuration Structure

Your `~/.ssh/config` will look like this:

1.  `Include config-top.d/*` (User overrides)
2.  `Include by-key/%K` (Secure path)
3.  `Include by-host/%h` (Fallback path)
4.  `Include config-bottom.d/*` (Global defaults)

This ensures that specific secure lookups take precedence, but you can still apply global settings.
