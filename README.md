# SSH Unique Key Manager

A secure and organized approach to SSH key management, creating distinct identities for each `[user@]host` combination while maintaining security, traceability, and ease of use.

## Why Use This?

- **Organized**: No more messy `~/.ssh` directory with confusing key names
- **Secure**: Each host gets its own key, limiting the impact of compromised credentials
- **Traceable**: Complete history of key operations and changes
- **Flexible**: Use templates to share keys across related hosts when needed
- **Safe**: Automatic host key verification and backup features

## Quick Start

### Installation

```bash
./install.sh
```

### Basic Usage

```bash
# Create and deploy new key
ssh-new user@example.com

# Use template-based key
ssh-new --template work user@example.com

# Remove host configuration
ssh-del example.com

# Check key history
ssh-history keys example.com
```

## Core Features

### Key Management

- Unique SSH keys per host/user combination
- Template system for key reuse across similar hosts
- Automatic key type selection (ed25519 > ecdsa > rsa)
- Safe key removal with remote cleanup

### Key Operations

- Host key rotation with backup
- Template-based key updates
- Bulk operations through templates
- Secure permission management

### History and Audit

- Complete operation history in `~/.ssh_history`
- JSON-formatted logs for automation
- Searchable with date filtering
- Template usage tracking

## Directory Structure

```text
~/.ssh/unique_keys/
├── host-uuid/          # Host identities by key hash
│   └── <uuid>/
│       ├── known_host_keys
│       └── <user>/
│           ├── id_ed25519
│           └── id_ed25519.pub
├── by-key/            # Quick access symlinks
├── templates/         # Key templates
│   └── work/
│       ├── config
│       ├── id_ed25519
│       └── id_ed25519.pub
├── conf.d/           # Host configs
└── backups/         # Backup archives
```

## Advanced Usage

### Template Management

```bash
# Rotate template key
ssh-template-rotate -t ed25519 work

# List hosts using template
ssh-history templates work
```

### History and Auditing

```bash
# Recent operations
ssh-history list -n 10

# Template usage
ssh-history templates

# Date range search
ssh-history list --from 2025-10-01 --to 2025-11-01
```

### Backup and Restore

```bash
# Create backup
ssh-backup -o ~/ssh-backup.tar.gz

# Restore configuration
ssh-restore -i ~/ssh-backup.tar.gz
```

## Security Features

- **Strict Permissions**: 700 for directories, 600 for private keys
- **Host Verification**: Stores and validates host keys
- **Safe Updates**: Automatic backups before changes
- **Audit Trail**: Comprehensive operation logging
- **Key Isolation**: Compromised key affects single host

## Project Status

### Implemented

- Per-host key management
- Template system
- Key rotation
- History tracking
- Backup/restore
- Host key verification

### Planned Features

- SSH agent integration
- Password-protected key support
- Key expiration management
- Host groups
- Certificate authority integration

## Requirements

- Bash shell
- OpenSSH 7.0+
- Standard Unix tools (awk, sed, etc.)

## Contributing

Contributions welcome! Please see our contribution guidelines.

## License

Apache License 2.0 - See LICENSE file for details.