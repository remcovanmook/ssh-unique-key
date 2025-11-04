# SSH Unique Key Project Guidelines

This project provides tools to manage SSH keys on a per-host basis, creating unique identities for each `[user@]host` combination.

## Architecture Overview

### Core Components

1. **Base Structure** (`~/.ssh/unique_keys/`):
   - `host-uuid/`: Stores canonical host identities based on public key hashes
   - `by-key/`: Symlinks to canonical host identities for quick access
   - `templates/`: Template SSH keys for reuse
   - `conf.d/`: Host-specific SSH config snippets

2. **Command Line Tools**:
   - `ssh-new`: Creates/links keys and configures SSH for a host
   - `ssh-del`: Removes host configurations and optionally deletes keys
   - `ssh-template`: Manages key templates (referenced in code but not yet implemented)

### Key Workflows

1. **Host Identity Management**:
   ```bash
   # Creating new host identity
   ssh-new [--template <name>] user@host
   
   # Removing host identity
   ssh-del user@host
   ```

2. **Template Usage**:
   - Templates allow reusing keys across multiple hosts
   - Templates must have compatible key types with target hosts
   - Priority order: ed25519 > ecdsa > rsa

## Development Patterns

1. **Shell Script Structure**:
   - Common utilities in `_ssh-unique-key.inc.sh`
   - Each command is a separate executable script
   - All scripts use `set -e` for immediate error exit

2. **Security Practices**:
   - Directory permissions strictly enforced (700)
   - Host key verification before key creation/linking
   - Public key storage with read-only permissions (644)

3. **Code Organization**:
   - Function-first approach with clear documentation
   - Consistent error handling through `err()` function
   - Modular design with shared includes

## Integration Points

1. **SSH System Integration**:
   - Works alongside standard SSH configuration
   - Generates per-host config snippets in `~/.ssh/unique_keys/conf.d/`
   - Uses standard SSH tools (ssh-keyscan, ssh-keygen)

2. **Host Key Verification**:
   - Scans and stores host keys on first connection
   - Verifies keys haven't changed on subsequent connections
   - Supports multiple key types (ed25519, ecdsa, rsa)

## Known Limitations

- No direct support for ssh-agent integration
- Manual key type selection not implemented
- Limited to single key per user@host combination

## Example Usage

```bash
# Create new identity with generated key
ssh-new alice@example.com

# Create identity using template
ssh-new --template work bob@server.com

# Remove host configuration
ssh-del example.com
```