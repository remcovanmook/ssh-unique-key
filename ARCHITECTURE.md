# Architecture

This document describes the design of `ssh-unique-key` in enough detail to audit it. It complements the high-level "Architecture" section in [README.md](README.md), which is intentionally brief.

The tool does not implement cryptography. It orchestrates `ssh-keygen`, `ssh-keyscan`, `ssh-copy-id`, OpenSSH itself, and (optionally) `opkssh`. The bespoke part — and therefore the part that must be airtight — is the *protocol around* those primitives: how identities are derived, where keys live on disk, how SSH is configured to find them, and how MITM detection works.

A second design pillar is **dependency minimisation.** Every external package is supply-chain surface. Python code targets stdlib only; JavaScript is vendored, version-pinned, and checksum-recorded; no `pip install` or remote fetch runs at install time or runtime.

---

## 1. Goals and non-goals

### Goals

1. **Anti-tracking.** A user's public key on host A must never appear on host B. No identifier shared across hosts.
2. **Blast radius reduction.** Compromise of one host yields one keypair; that keypair authenticates to nothing else.
3. **Zero-friction UX.** The user keeps typing `ssh user@host`. Provisioning, deployment, and config injection happen via `ssh-new`; everything else is invisible.
4. **MITM-resistant re-engagement.** After first contact, host identity is pinned and re-verified on every subsequent operation.
5. **Optional hardware-token and OpenPubKey paths.** YubiKey/FIDO2 and opkssh-issued certificates compose with the per-host model via templates. Hardware-bound keys also provide the only path to "private material that does not live under `$HOME`" — important when the X1 platform gate is unavailable.
6. **Minimal supply-chain surface.** Zero pip dependencies; vendored JavaScript with recorded checksums; no install-time or runtime network fetches for code. Every line of code shipped is either in the repo (and reviewable in `git log`) or in the system's `python3` / OpenSSH / bash distribution.

### Non-goals

- **Not a CA.** We do not sign certificates; opkssh does.
- **Not a key escrow.** Backups are explicit, user-driven, encrypted only at the user's discretion (`ssh-backup` produces a plain tarball).
- **Not a replacement for `ssh-agent`.** Keys live unencrypted on disk because they have to (legacy device support, hands-free provisioning). Users wanting passphrase-protected keys do not gain that from this tool.
- **Not a defence against same-user code with ordinary filesystem access.** See §2 X1. This is a deliberate platform gate, not a missing feature.
- **Not a generic web framework.** The web UI is stdlib Python + vendored JS. We will not grow it into anything that requires a dependency tree.

---

## 2. Threat model

| ID | Adversary | Capability | What we defend against |
| --- | --------- | ---------- | ---------------------- |
| A | Remote-server admin / partial server compromise | Read `authorized_keys` on one host they control | Cannot correlate the captured public key to any other host — per-host uniqueness makes the key worthless beyond that one server |
| B | Mass scanner (Shodan, Censys, internet-wide SSH probes) | Snapshot of public-facing SSH server keys and accepted auth | Cannot search by public key to find other servers belonging to the same user |
| C | On-path MITM during an existing host's reconnection | Substitute host keys | `ssh-new` and connect-time `%K`-based config lookup both pin to stored host keys; mismatch aborts the operation. Every connection `ssh-new`/`ssh-user-rotate` makes themselves (`ssh-copy-id`, key verification, the post-provision `ssh`) is pinned to the stored scan via `UserKnownHostsFile` + `StrictHostKeyChecking=yes` — never `accept-new`, which would both accept an unscanned key and write it into the default `known_hosts` |
| D | Local non-malicious footgun | User shares screenshot, runs a backup tool, `find` over `$HOME` | Keys are siloed under `~/.ssh/unique_keys/` (not the conventional `id_rsa`); 0700/0600 perms throughout |
| E | Web UI cross-origin attacker | Malicious page tries to drive the local UI server | Server binds to 127.0.0.1 only; random port; CORS pinned to the served port; auth via one-time URL token exchanged for HTTP-only `SameSite=Strict` cookie |
| F | Supply-chain attacker against our dependencies | Compromise pypi/unpkg/npm or our install-time download path | All Python = stdlib; all JS vendored at known versions with recorded SHA-384 checksums; no network fetch at install/runtime; CI verifies vendored files match recorded hashes |

### Out-of-scope adversaries

| ID | Adversary | Why out of scope |
| --- | --------- | ---------------- |
| X1 | Local same-user code with ordinary filesystem access (including AI coding agents, well-meaning automation, accidental `tar` of `$HOME`) | A user-mode design that keeps private key files on disk cannot defend against arbitrary code running as the user. This is a **deliberate platform gate**, not an oversight — if it matters in your environment, the answer is platform-level isolation (separate user accounts, OS sandboxing) or hardware-bound keys via `ssh-keygen-sk` templates that push private material out of `$HOME` entirely. We do not attempt encryption-at-rest with in-filesystem unlock material; that approach trades one platform problem for a much larger orchestration surface. |
| X2 | TOFU bypass on first scan | We trust the very first `ssh-keyscan` result. A network-position attacker present at provision time can pin themselves as the "real" host. This is the same trust model OpenSSH gives users on first connect; we do not improve on it |
| X3 | Supply-chain compromise of `opkssh`, OpenSSH, the OS, or the system Python interpreter | Beyond our boundary; we trust the OS distribution |
| X4 | Sophisticated attacker who can read the repo and craft a poisoned vendored JS update | Mitigated by: vendored bumps go through code review, the diff is human-inspectable, and SHA-384 records change visibly in the commit |

### Known weaknesses (tracked for fix; details in `REFACTOR.md`)

- **W1: UUID stability under partial scans.** Host UUID is `sha256(best-key)` selected from a sort of the full `ssh-keyscan` output. If a scan returns a subset of the host's keys, the "best" key may differ and the UUID changes — appearing as a new identity. The diff check in `ssh-new` catches this and aborts loudly, but the design is brittle.
- **W2: Comment / config injection via `--comment`.** The `ssh-new --comment` text is interpolated into a `Match host %h exec "..."` line. Sanitisation strips single quotes and backslashes; the surface area is fragile and per-call. Should be replaced with a structured config writer that writes the text to a separate file and `cat`s it.
- **W3: Triple command-construction.** The same operations are assembled three times: bash CLI argv, Python `subprocess.run` argv, shell-script strings in `launch_terminal_script`. Three opportunities for inconsistent escaping.
- **W4: Inconsistent auth on web UI.** `before_request` enforces auth globally, but some endpoints re-check redundantly and `/deploy` does not; `url_for('login')` is called but no login route exists.
- **W5: Install-time network fetch with no integrity check.** [install.sh](install.sh) currently `curl`s `xterm@latest` / `socket.io-client@4` from unpkg with no version pin and no hash. This is the largest unmitigated supply-chain hole. Will be replaced by vendored copies committed to the repo.
- **W9: `ssh-rotate` and `ssh-template-rotate` reference undefined helpers** (`validate_hostname`, `CONFIG_DIR`, `validate_template`, `get_hosts_using_template`, `log`). The scripts are unrunnable as shipped. Rebuilt in Phase 5.

---

## 3. Trust boundaries

The tool inserts itself between three trust domains and must not weaken any of them.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                          USER'S MACHINE                                 │
│                                                                         │
│   ┌──────────┐    ┌──────────────────┐    ┌──────────────────────────┐  │
│   │ ssh(1)   │    │ ssh-unique-key   │    │ ~/.ssh/unique_keys/      │  │
│   │ (trusted)│◄──►│ (this tool)      │◄──►│ (filesystem state, 0700) │  │
│   └────┬─────┘    └────────┬─────────┘    └──────────────────────────┘  │
│        │                   │                                            │
└────────┼───────────────────┼────────────────────────────────────────────┘
         │                   │
         ▼                   ▼
    ┌─────────┐         ┌────────────┐
    │ remote  │         │ opkssh /   │
    │ sshd    │         │ OIDC IdP   │
    └─────────┘         └────────────┘
```

- **OpenSSH ↔ this tool:** we communicate exclusively through `~/.ssh/config` `Include` directives and standard token expansion (`%K`, `%h`, `%r`). We never patch OpenSSH, never wrap `ssh`, never intercept its network traffic.
- **This tool ↔ filesystem:** every directory we own is `0700`, every private key `0600`, every public key/log `0644` or `0600`. We never `chmod` outside `~/.ssh/unique_keys/`. We rely on the OS to honour those permissions against other users; against the *same* user, see X1.
- **This tool ↔ remote sshd:** all network actions happen through `ssh-keyscan`, `ssh-copy-id`, and `ssh`. We never speak SSH wire protocol ourselves.
- **This tool ↔ third-party code:** Python = stdlib of the system interpreter. JavaScript = vendored files at `lib/ui/vendor/` with checksums recorded in `lib/ui/vendor/SHA384SUMS`. Nothing fetched at install or runtime.

---

## 4. On-disk schema (formal)

All paths are relative to `$BASE_DIR = ~/.ssh/unique_keys`. The base directory itself is `0700`.

```text
~/.ssh/unique_keys/
├── SCHEMA                              0644  single integer; current = 2
├── host-uuid/                          0700  parent of all host identities
│   └── <sha256>/                       0700  one host identity; <sha256> = §5
│       ├── known_host_keys             0644  sorted ssh-keyscan output (full key set)
│       ├── config                      0600  host-specific ssh_config snippet
│       ├── trusted.conf                0600  by-key-path ssh_config (StrictHostKeyChecking no)
│       ├── notice.txt                  0600  optional; ssh-new --comment payload (W2 fix)
│       └── <user>/                     0700  one per remote username
│           ├── identity                0600  private key OR symlink → templates/<name>/...
│           ├── identity.pub            0644  public key OR symlink (optional for cert-only)
│           └── identity-cert.pub       0644  OPK certificate symlink (OPK templates only)
├── by-key/                             0700  index by base64 host key
│   └── <base64>/ → ../host-uuid/<sha256>     symlink; key includes "/" → nested dirs
├── by-host/                            0700  index by hostname (fallback)
│   └── <hostname> → ../host-uuid/<sha256>    symlink
├── templates/                          0700  parent of all key templates
│   └── <name>/                         0700  one template
│       ├── config                      0600  template-wide ssh_config snippet
│       ├── id_ed25519, id_ecdsa, id_rsa       (standard templates)
│       ├── id_ed25519.pub, id_ecdsa.pub, id_rsa.pub
│       ├── id_ed25519_sk, id_ed25519_sk.pub   (hardware-key templates)
│       ├── identity, identity.pub, identity-cert.pub  (OPK templates)
│       ├── .type                       0600  literal "opk" for OPK templates; absent otherwise
│       └── .issuer                     0600  IdP URL for OPK templates (optional)
├── config-top.d/                       0700  user-supplied overrides, loaded first
├── config-bottom.d/                    0700  defaults, loaded last
└── history.jsonl                       0600  one JSON object per line (schema v2)
```

### File-format invariants

- `SCHEMA`: a single line containing the integer schema version. Bumped when on-disk layout changes. Absent file ⇒ legacy v1 (pre-refactor) install.
- `known_host_keys`: one key per line, format `<hostname> <key-type> <base64-key>`, sorted lexicographically. Comments (`#…`) excluded. The hostname column is informational for identity purposes — equality checks against new scans strip it (`awk '{$1=""; print}'`) — but it is refreshed to the most recent provisioning target on every successful re-verification, because the file doubles as the pinned `UserKnownHostsFile` for provisioning-time connections (see §7).
- `history.jsonl`: one JSON object per line, schema `{"ts": <ISO8601-UTC>, "user": <local-user>, "action": <verb>, "target": <target>, "details": <object|string>}`. Tolerates extra fields. (Replaces the pipe-separated `history.log` from schema v1; see W6 below for the migration story.)
- `.type`: the single literal string `opk` or the file is absent. No other values defined.

### Schema-level weaknesses (numbered for tracking)

- **W6: legacy `history.log` had no `|` escaping.** Resolved by moving to JSONL at schema v2.
- **W7: no schema version marker** in v1. Resolved by adding `SCHEMA` at v2; `ssh-doctor` validates.
- **W8: `<base64>` in `by-key/` may contain `/`.** Handled by nesting directories under `by-key/`, but produces a surprising tree on inspection. Not broken; documented here.

---

## 5. Identity derivation

### Host UUID

```text
UUID(host) = sha256("<key-type> <base64-key>" of awk_pick_best_key(ssh-keyscan host))
```

Where `awk_pick_best_key` picks in priority order: `ssh-ed25519`, `ecdsa-sha2-*`, `ssh-rsa`. The input to sha256 is `<key-type> <base64-key>` for the chosen key — the hostname column is stripped, so the identity is derived purely from key material.

**Properties:**

- Stable across hostname/IP changes (the UUID is derived from host keys, not naming).
- Stable across host-key reordering in scan output (we pick by type, not by position).
- **Unstable across partial scans** if the scan returns a strict subset of the host's keys — see W1.
- Collision-resistant under sha256.

### Per-user identity

Per-user identity is a directory `host-uuid/<sha256>/<user>/` containing `identity` and `identity.pub`. The private file is either a real key (generated locally) or a symlink into `templates/<name>/`. We never silently rotate; rotation is an explicit operation (`ssh-user-rotate`, `ssh-template-rotate`).

### Template indirection

Templates exist so that one logical credential (a YubiKey, an opkssh certificate) can authenticate many hosts. Per-user `identity` becomes a relative symlink into `templates/<name>/`. Standard templates use `id_<type>` filenames; OPK templates use `identity`/`identity.pub`/`identity-cert.pub` (because opkssh expects that naming). The `.type=opk` sidecar disambiguates.

---

## 6. SSH config integration

`install.sh` prepends the following block to `~/.ssh/config`:

```text
# --- SSH-UNIQUE-KEY START ---
Include ~/.ssh/unique_keys/config-top.d/*
Include ~/.ssh/unique_keys/by-key/%K/trusted.conf
IdentityFile ~/.ssh/unique_keys/by-key/%K/%r/identity
Include ~/.ssh/unique_keys/by-host/%h/config
IdentityFile ~/.ssh/unique_keys/by-host/%h/%r/identity
Include ~/.ssh/unique_keys/config-bottom.d/*
# --- SSH-UNIQUE-KEY END ---
```

### Token semantics

- `%K` — the base64-encoded host public key OpenSSH has just verified. Only available *after* host-key verification, so anything `Include`d under `by-key/%K/` is keyed by a cryptographically attested identity.
- `%h` — the literal hostname/alias as typed by the user. Available before connection; used as a pre-verification fallback (and the only path on macOS's stock SSH, which lacks `%K`).
- `%r` — the remote username.

### Why `StrictHostKeyChecking no` is safe inside `trusted.conf`

The `by-key/<key>/` directory exists *only* if `ssh-new` previously stored `<key>` in `known_host_keys` for this host. Reaching that path means OpenSSH has already verified the server presented exactly that key. The `Include` only fires when verification has already succeeded, so `StrictHostKeyChecking no` is a no-op — the path itself *is* the check. `UserKnownHostsFile /dev/null` then suppresses the redundant warning OpenSSH would emit about an unrecorded host.

This is the single most important invariant in the design. If anything ever causes `by-key/<wrong-key>/trusted.conf` to exist for a host whose key has changed, the safety argument collapses. Currently enforced by:

1. `by-key/<base64>` is only created/refreshed by `ssh-new` after a successful scan-vs-stored diff.
2. `ssh-rotate` (when fixed; see W9) is the only path that updates `by-key/` symlinks for an existing host.

### Precedence

`config-top.d/*` wins (user overrides); then by-key (cryptographic); then by-host (TOFU); then `config-bottom.d/*` (defaults). OpenSSH applies the *first* value seen for any setting that isn't list-typed.

---

## 7. Control flow per operation

### `ssh-new user@host`

```text
 1. Parse args (template, legacy, comment, key-comment, no-connect)
 2. Pre-flight: probe publickey-auth support; warn-and-confirm if absent
 3. ssh-keyscan host  →  RAW_SCAN  →  sort  →  SCAN_SORTED
 4. UUID = sha256(best-key-in(SCAN_SORTED))
 5. If host-uuid/UUID/ exists:
       diff SCAN_SORTED against known_host_keys (modulo first column)
       mismatch → ABORT with security warning
       match    → rewrite known_host_keys with SCAN_SORTED (same keys;
                  refreshes the hostname column to the current target)
    Else:
       create host-uuid/UUID/ (0700); write known_host_keys
 6. Create host-uuid/UUID/<user>/ (0700)
 7. If <user>/identity absent:
       If --template:
          If template is OPK: validate cert; if expired, run `opkssh login`, re-validate
          Symlink identity/.pub/-cert.pub into templates/<name>/
       Else:
          ssh-keygen, picking type by host capability (ed25519 > ecdsa > rsa); rsa -b 4096
 8. Emit host-uuid/UUID/config (with template Include if applicable)
 9. If --legacy: append legacy KexAlgorithms/Ciphers stanza
10. If --comment: write text to host-uuid/UUID/notice.txt; emit
       Match host %h exec "cat ~/.ssh/unique_keys/host-uuid/UUID/notice.txt"
    No interpolation of user text into the config file (W2 fix).
11. Write trusted.conf (StrictHostKeyChecking no, Include config)
12. ssh-copy-id -o UserKnownHostsFile=host-uuid/UUID/known_host_keys
                -o StrictHostKeyChecking=yes
    (unless --no-connect or cert-only auth; pins the deployment connection
    to exactly the keys the UUID was derived from — a MITM appearing
    between the scan and the copy aborts here)
13. Symlink by-host/<host> → host-uuid/UUID
14. For each key in SCAN_SORTED: symlink by-key/<base64> → host-uuid/UUID
15. exec ssh user@host with the same UserKnownHostsFile pin   (unless --no-connect)
```

### `ssh user@host` (after provisioning)

```text
1. OpenSSH reads ~/.ssh/config; sees Include by-host/<host>/config
2. OpenSSH connects, performs host-key verification
3. After verification, OpenSSH re-evaluates Match-style includes with %K bound
4. Include by-key/%K/trusted.conf  →  IdentityFile by-key/%K/%r/identity
5. Authenticate with the unique per-host key
```

### `ssh-del [user@]host`

```text
1. ssh-keyscan host (allow failure; fall back to by-host symlink if unreachable)
2. Resolve UUID
3. Confirm-prompt; remove host-uuid/UUID/<user>/
4. If other users remain: stop
5. Else: remove by-host/<host> symlink and by-key/<each-stored-key> symlinks
        if no other aliases: confirm-prompt full delete
```

---

## 8. Web UI architecture

The web UI is **stdlib-only Python** (post-refactor) plus **vendored JavaScript** with no runtime dependencies.

### Process model

- One Python process. `python3 lib/ssh-ui.py` — no venv, no `pip install`, no first-run setup.
- HTTP server built on `http.server.ThreadingHTTPServer` (stdlib) with a hand-rolled router.
- WebSocket: a single ~200-LOC RFC 6455 handler we own, wired into the same `ThreadingHTTPServer` via HTTP `Upgrade`. No `socket.io`. No `gevent`/`eventlet`. Plain threads, one per WebSocket connection.
- PTY: `pty.fork()` + `select()` on the master FD, same as today, but the framing layer is ours, not flask_socketio's.
- Binds `127.0.0.1` on a random port. Single-process; no multi-worker model.

### Auth

- One-time auth token (`secrets.token_urlsafe(32)`) generated per process startup.
- First request with `?token=...` validates via `hmac.compare_digest`, sets an HTTP-only `SameSite=Strict` cookie, redirects to a clean URL.
- All subsequent requests authenticated by cookie.
- A `@require_auth` decorator wraps every handler; no global `before_request` hook to forget.
- WebSocket upgrade requests carry the same cookie and are validated before `pty.fork()`.

### Rendering

- `index.html` is **static**. The Python process serves it as a static file. No templating engine; no Jinja2.
- All dynamic data flows over JSON endpoints (`/api/identities`, `/api/templates`, `/api/history`). The browser fetches on load and renders client-side.
- This collapses the previous "SSR for dashboard, JSON for everything else" inconsistency into a single SPA pattern.

### Endpoints (post-refactor)

| Route | Method | Purpose |
| ----- | ------ | ------- |
| `/` | GET | Serve static `index.html` |
| `/assets/<path>` | GET | Static asset (CSS, JS, vendored xterm.js) |
| `/api/identities` | GET | List host identities + users (replaces SSR data) |
| `/api/templates` | GET / POST | List / create templates |
| `/api/templates/<name>` | DELETE | Remove template |
| `/api/history` | GET | Read `history.jsonl` (last N) |
| `/api/user/rotate` | POST | Shell out to `ssh-user-rotate --json` |
| `/api/user/delete` | POST | Shell out to `ssh-del --force --json` |
| `/api/deploy` | POST | Shell out to `ssh-copy-id` (no in-Python ssh-copy-id path) |
| `/ws` | GET (Upgrade) | WebSocket for PTY-backed flows |
| `/favicon.ico`, `/robots.txt` | GET | Trivial responses |

Every state-mutating endpoint shells out to a `bin/ssh-*` script and reads `--json` output. Python does not call `ssh-keygen`/`ssh-keyscan`/`ssh-copy-id` directly. This eliminates the duplicated command-construction logic (W3) and ensures every mutation passes through `log_event`.

### WebSocket protocol (hand-rolled)

The browser uses the native `WebSocket` API (no `socket.io-client`). Messages are JSON envelopes:

```text
client → server:  {"op": "spawn",  "cmd": "create"|"connect"|"template", "args": {...}}
client → server:  {"op": "input",  "data": "<utf-8 keystrokes>"}
client → server:  {"op": "resize", "cols": <int>, "rows": <int>}

server → client:  {"op": "output", "data": "<utf-8 bytes from PTY>"}
server → client:  {"op": "ended",  "exit_code": <int>}
server → client:  {"op": "error",  "message": "<string>"}
```

Each WebSocket connection owns one PTY. `spawn` is rejected if a PTY is already attached. Reconnection of a detached browser window targets a known `term_id` (carried in a query param on the WS URL) — only one reconnect within a 15-second grace window before the PTY is reaped.

### Attack surface inventory

Every place untrusted data enters the system. Post-refactor, every entry goes through `lib/ssh_ui/validators.py` (Python) which has a paired bash module `bin/_validators.inc.sh`. The two modules are tested against a shared golden corpus.

| # | Input | Validator | Notes |
| --- | ----- | --------- | ----- |
| 1 | `user_host` field | `validate_user_host` | regex `^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+$` |
| 2 | `template` name | `validate_template_name` | `^[a-zA-Z0-9_-]+$`, max 64 |
| 3 | `key_comment` | `validate_key_comment` | `^[a-zA-Z0-9 ._@-]+$`, max 128 |
| 4 | `comment` text (for `--comment`) | `validate_comment_text` | length-bounded; written to `notice.txt`, never interpolated (W2 fix) |
| 5 | `target_host` (deploy) | `validate_hostname` | `^[a-zA-Z0-9.-]+(:[0-9]+)?$` |
| 6 | `password` (deploy) | length-bounded | written to a `SSH_ASKPASS` script (0700, in `$XDG_RUNTIME_DIR` or `~/.ssh/unique_keys/tmp`), deleted post-run |
| 7 | `uuid` in API routes | `validate_uuid` | strict `^[a-f0-9]{64}$` (was `os.path.basename` only) |
| 8 | WebSocket payload fields | re-validated server-side at handler entry | Same validators as HTTP endpoints |
| 9 | Inbound URL `?token=...` | `hmac.compare_digest` | |
| 10 | `ssh-keyscan` output | `awk` + `sort` | Untrusted from a network MITM perspective; pinned on second use |
| 11 | `opkssh` stdout/stderr | not parsed; only side-effect on `identity-cert.pub` is checked via `check_cert_validity` | |

### Static asset supply chain (W5 fix)

All JS/CSS is vendored. The repo holds:

```text
lib/ui/vendor/
├── SHA384SUMS              ← one line per file: "<sha384>  <relpath>"
├── xterm-5.5.0.js
├── xterm-5.5.0.css
└── xterm-addon-fit-0.10.0.js
```

`scripts/check vendor` recomputes SHA-384 over every file in `vendor/` and compares to `SHA384SUMS`. CI runs the same check. Bumping a vendored file requires updating `SHA384SUMS` in the same commit — the diff is visible in code review.

`socket.io-client` is *removed* from the vendor set; xterm.js does not depend on it, and our hand-rolled WebSocket uses the browser's native `WebSocket` API.

`install.sh` no longer performs any network fetch.

---

## 9. Logging

Single stream, `history.jsonl`. Written by bash scripts via `log_event` (which JSON-encodes its arguments) and by the Python web UI through the same shell helpers (i.e. via shelled-out CLI calls — see [§8](#endpoints-post-refactor) note about every mutation passing through bash).

Python `logger` to stderr is kept for WebSocket lifecycle / PTY-spawn debug output only. Operational events do not go there.

---

## 10. Open questions / decisions deferred

- **UUID derivation under partial scans.** Three options on the table; see W1. Decision in `REFACTOR.md` Phase 3.
- **Where does `opkssh login` actually deposit the certificate?** The current OPK flow asks the user for the path because we don't know. Pinning this (or wrapping opkssh) would remove a sharp edge.
- **Should the web UI support remote (non-localhost) operation?** No, by current decision. Going remote would require TLS, real auth, CSRF tokens. Out of scope.

---

## 11. Quick reference: file layout map (post-refactor)

```text
ssh-unique-key/
├── ARCHITECTURE.md          ← this document
├── REFACTOR.md              ← phased refactor plan
├── README.md                ← short overview, install, usage
├── LICENSE
├── install.sh               ← installs symlinks into ~/bin, sets up ~/.ssh/config
├── scripts/
│   ├── check                ← local validation entry (lint/syntax/test/vendor)
│   └── install-hooks        ← installs .git/hooks/pre-push → scripts/check
├── bin/                     ← bash CLI
│   ├── _ssh-unique-key.inc.sh   shared sourced helpers
│   ├── _validators.inc.sh       input validation (paired with lib/ssh_ui/validators.py)
│   ├── ssh-new
│   ├── ssh-del
│   ├── ssh-conf
│   ├── ssh-template
│   ├── ssh-rotate               (rebuilt in Phase 5)
│   ├── ssh-user-rotate
│   ├── ssh-template-rotate      (rebuilt in Phase 5)
│   ├── ssh-backup
│   ├── ssh-restore
│   ├── ssh-history
│   ├── ssh-doctor               (new in Phase 3)
│   └── ssh-ui                   exec python3 lib/ssh-ui.py
├── lib/
│   ├── ssh-ui.py            ← entry point: `python3 ssh-ui.py`
│   └── ssh_ui/              ← stdlib-only package
│       ├── __init__.py
│       ├── server.py        ← ThreadingHTTPServer + router
│       ├── auth.py          ← token, cookie, @require_auth
│       ├── ws.py            ← RFC 6455 framing + handshake
│       ├── pty_manager.py   ← active terminals, lifecycle, reader loop
│       ├── handlers.py      ← HTTP handler functions per route
│       ├── identity_scan.py ← filesystem walk → JSON
│       ├── validators.py    ← input validation (paired with bin/_validators.inc.sh)
│       └── subprocess_runner.py ← single wrapper around subprocess.run for bin/ssh-*
├── lib/ui/
│   ├── index.html           ← static SPA shell
│   ├── app.js               ← native fetch + native WebSocket
│   ├── style.css
│   └── vendor/
│       ├── SHA384SUMS
│       ├── xterm-<ver>.js
│       ├── xterm-<ver>.css
│       └── xterm-addon-fit-<ver>.js
├── tests/
│   ├── bash/                ← bats suite
│   ├── python/              ← unittest / pytest
│   └── threat/              ← Phase 6 regression suite (per threat A–F)
└── .github/
    └── workflows/
        └── check.yml        ← thin wrapper: runs scripts/check
```

The `lib/requirements-ui.txt` file is **removed** in Phase 1. No pip dependencies.
