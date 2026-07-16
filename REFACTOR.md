# Refactor Plan

Companion to [ARCHITECTURE.md](ARCHITECTURE.md). Each phase has explicit entry/exit criteria. Phases are sequenced; do not start phase N+1 until phase N's exit gate is green. The refactor assumes pre-1.0 status — no on-disk backward compatibility is required.

Issues are referenced by the `W#` IDs from [ARCHITECTURE.md §2 and §4](ARCHITECTURE.md#2-threat-model).

---

## Phase 0 — Stop the bleeding, vendor JS, local check script (~1 week)

**Goal:** the repo no longer ships broken code or fetches code from the internet at install time. A single local check script is the validation entry point — used by developers, by a pre-push hook, and (later) by CI as a thin wrapper.

### Tasks (Phase 0)

1. **Vendor xterm.js into the repo.** (W5 closed.)
   - Create `lib/ui/vendor/`.
   - Pin specific versions (e.g. `xterm-5.5.0.js`, `xterm-5.5.0.css`, `xterm-addon-fit-0.10.0.js`). Filename includes the version so a bump is a file rename plus a `SHA384SUMS` edit — both visible in the diff.
   - Record SHA-384 hashes in `lib/ui/vendor/SHA384SUMS` (`<sha384>  <relpath>` per line — same format as `shasum -a 384`).
   - **Drop `socket.io-client` entirely.** Not vendored; not needed. (Phase 1 replaces `flask_socketio` with a hand-rolled WebSocket and switches the client to the browser-native `WebSocket` API.)
   - Update [`lib/ui/index.html`](lib/ui/index.html) and the install script's xterm block to reference the vendored paths.
   - Update `.gitignore` to *un*-ignore `lib/ui/xterm/` if needed, or move to `vendor/` and remove that gitignore line.
   - Remove the `download_latest` block and the `INSTALL_XTERM=ask` interactive prompt from [`install.sh`](install.sh).
2. **Build `scripts/check`.** A single bash entry point with subcommands:

   ```text
   scripts/check                # run all stages
   scripts/check syntax         # bash -n, python -m py_compile
   scripts/check lint           # shellcheck, ruff/pyflakes
   scripts/check vendor         # verify lib/ui/vendor/SHA384SUMS
   scripts/check tests          # bats + python tests (when they exist)
   scripts/check secrets        # grep for accidentally-committed secrets
   ```

   Stage modules live in `scripts/check.d/*.sh`. Each module:
   - Exits 0 if its checks pass.
   - Exits non-zero (≥1) on failure.
   - Skips with a `[SKIP] tool 'foo' not installed` line if an optional tool is absent (and *does not* fail the overall run).
   - Required tools: `bash`, `python3`, `shasum`/`sha384sum`. Optional: `shellcheck`, `ruff`, `bats`.
3. **Pre-push hook installer.** `scripts/install-hooks` writes `.git/hooks/pre-push` as a one-liner: `exec "$(git rev-parse --show-toplevel)/scripts/check"`. README mentions how to run it. The hook is opt-in (we never auto-install behind the user's back).
4. **Thin CI wrapper.** `.github/workflows/check.yml` does exactly one thing: install `shellcheck`/`ruff`/`bats` and run `scripts/check`. No duplicated lint logic in YAML. Anyone outside GitHub can run the same script locally and get the same result.
5. **Fix the broken bash scripts.** [`ssh-rotate`](bin/ssh-rotate) and [`ssh-template-rotate`](bin/ssh-template-rotate) reference undefined helpers. For Phase 0, choose one of:
   - **Remove them** with a stub script that prints "rebuilt in Phase 5" — preferred, keeps the codebase honest about what works.
   - Inline minimal `validate_hostname` / `validate_template_name` / `log` stubs in `_ssh-unique-key.inc.sh` so they at least syntax-check, while making it loud that they're untested.

   Document the decision in the commit. (W9 will be properly closed in Phase 5.)
6. **De-duplicate [`ssh-new`](bin/ssh-new) arg parsing.** Lines 13-14, 26-27, and 39-40 contain near-duplicate `--comment` blocks. One copy, one usage line. Add a test (under `tests/bash/`) that runs `ssh-new --help` and grep-asserts a single `--comment` mention.
7. **Bin `bin/__pycache__`.** Ensure it's gitignored; remove from the working tree.
8. **README updates.**
   - Replace the install xterm prompt section.
   - Add a "Development" section pointing at `scripts/check` and `scripts/install-hooks`.
9. **Pin provisioning-time connections to the stored scan.** *(Landed 2026-07-16, ahead of the phase.)* `ssh-new` and `ssh-user-rotate` previously connected with `StrictHostKeyChecking=accept-new`, which accepted whatever key was presented (not necessarily the scanned one) *and* wrote it into the default `~/.ssh/known_hosts` — silently trusting a provision-time MITM on the immediate follow-on connection. All connections these scripts make now use `-o UserKnownHostsFile=<host-uuid/UUID/known_host_keys> -o StrictHostKeyChecking=yes` (`ssh-user-rotate` rewrites the hostname column to the connect alias in a temp pin file). The remaining `accept-new` in `lib/ssh-ui.py:/api/deploy` is covered by the Phase 1 rewrite + Phase 4 `bin/ssh-deploy` (see Phase 4 task 4).
10. **UUID derivation over `<type> <base64>`.** *(Landed 2026-07-16, ahead of the phase.)* Previously the code hashed only the base64 column and ARCHITECTURE.md claimed the full `<host> <type> <base64>` line — both wrong. Now `sha256("<key-type> <base64-key>")` of the best key; hostname column stripped. Pre-1.0: existing `host-uuid/<sha256>` dirs no longer match the new derivation — re-provision (no migration shipped).

### Exit gate (Phase 0)

- `scripts/check` runs locally on a fresh clone and exits 0.
- `scripts/check vendor` succeeds against `lib/ui/vendor/SHA384SUMS`.
- `install.sh` makes zero network requests (verified by running it with `curl`/`wget` shadowed to fail).
- `git grep "validate_hostname\|CONFIG_DIR\|validate_template\|get_hosts_using_template" bin/` returns nothing OR returns only inside `_ssh-unique-key.inc.sh` (the stubs).
- `bash -n` clean on every `bin/*` script.
- `git grep "accept-new" bin/ install.sh` returns nothing (provisioning connections are pinned; task 9).

---

## Phase 1 — Drop Flask: stdlib rewrite (~2 weeks)

**Goal:** the web UI runs on the system `python3` with zero pip dependencies. `lib/requirements-ui.txt` is deleted. `lib/venv/` is no longer created.

The existing [`lib/ssh-ui.py`](lib/ssh-ui.py) is replaced wholesale by a stdlib-only implementation. Because the old code is monolithic anyway, this phase doubles as the Python module split — we build the new layout from the start rather than splitting an inherited monolith later.

### Target layout (Phase 1)

```text
lib/
├── ssh-ui.py                 ← entry point: starts the server
└── ssh_ui/
    ├── __init__.py
    ├── server.py             ← ThreadingHTTPServer + dispatch (~150 LOC)
    ├── auth.py               ← token gen, cookie set, @require_auth (~80 LOC)
    ├── ws.py                 ← RFC 6455 handshake + frame codec (~200 LOC)
    ├── pty_manager.py        ← spawn/reap, reader loop, grace timer (~150 LOC)
    ├── handlers.py           ← one function per route (~250 LOC)
    ├── identity_scan.py      ← FS walk → dict; the get_identities/get_templates_list logic (~120 LOC)
    ├── subprocess_runner.py  ← single wrapper around subprocess.run for bin/ssh-* (~60 LOC)
    └── validators.py         ← input validators (Phase 2 ties them to bash twins)
```

No file over ~250 lines. Each module has a `tests/python/test_<name>.py` companion (added in Phase 2 — Phase 1 ships the modules without exhaustive tests but with at least one smoke test per file).

### Tasks (Phase 1)

1. **Stdlib HTTP server.** `http.server.ThreadingHTTPServer` + a small dispatch table mapping `(method, path)` → handler function. Path params (`/api/templates/<name>`) handled by route regex compiled once at startup.
2. **Static SPA.** [`lib/ui/index.html`](lib/ui/index.html) becomes a static file served directly. Jinja2 references removed:
   - `{% if xterm_enabled %}` → JS feature-detects (or a `/api/capabilities` endpoint).
   - `{% for identity in identities %}` table → `app.js` renders into the table after `fetch('/api/identities')`.
   - `result_output` / `result_status` modal → replaced by client-side toast tied to API call results.
3. **Hand-rolled WebSocket.** `lib/ssh_ui/ws.py`:
   - Validates the `Upgrade: websocket` handshake, computes the `Sec-WebSocket-Accept` SHA-1 response (stdlib `hashlib`), sends the 101.
   - Implements RFC 6455 frame parsing and writing for text frames (opcode 0x1) and pings/pongs (0x9/0xA). Binary not used.
   - Enforces a max frame size (e.g. 64 KiB) to bound memory.
   - One thread per connection; reads via `select.select(...)` so both PTY-fd and websocket-fd can drive the loop.
   - Includes a small fuzz suite in `tests/python/test_ws.py` against malformed frames.
4. **Plain-WebSocket client.** [`lib/ui/app.js`](lib/ui/app.js) drops `io.connect(...)` and uses `new WebSocket(...)`. Message envelopes match [ARCHITECTURE.md §8 "WebSocket protocol"](ARCHITECTURE.md#websocket-protocol-hand-rolled).
5. **Auth.** `auth.py` provides:
   - `verify_request(handler) -> bool` (checks cookie via `hmac.compare_digest`).
   - `@require_auth` decorator on every handler.
   - Handshake path for the one-time URL token (same model as today).
   - WebSocket handshake calls `verify_request` *before* upgrading.
6. **Subprocess wrapper.** `subprocess_runner.py` exposes `run_cli(name, *args, json=True)` that:
   - Builds argv from `bin/<name>` + args (no shell, no string concat).
   - Captures stdout/stderr.
   - Parses stdout as JSON if `json=True`.
   - Returns a `result` dict the handler maps to an HTTP response.
   - Phase 4 adds the `--json` flag to the CLI scripts; until then `json=False`.
7. **Delete the unused.** Remove `flask`, `flask_socketio`, `gevent`, `eventlet`, `webbrowser` (?), `requirements-ui.txt`, the `venv/` bootstrap from [`bin/ssh-ui`](bin/ssh-ui). The new `ssh-ui` is one line: `exec python3 "$LIB_DIR/ssh-ui.py" "$@"`.
8. **CSP header.** Every response includes `Content-Security-Policy: default-src 'self'; script-src 'self'; img-src 'self' data:; style-src 'self'; connect-src 'self' ws://*:* ws://localhost:* ws://127.0.0.1:*`. No `'unsafe-inline'`; inline styles in `index.html` are moved to `style.css` as part of this phase.

### Exit gate (Phase 1)

- `python3 lib/ssh-ui.py` runs on macOS and Linux with system Python (≥ 3.10), no `pip install` of anything.
- `wc -l lib/ssh_ui/*.py` — no single file over ~250 lines.
- All current UI features work: list identities, create identity (xterm flow), connect (xterm flow), rotate user key, delete user, list/create/delete templates, view history. Manual smoke-test checklist documented in `tests/manual/phase-1.md`.
- `grep -r "flask\|jinja\|gevent\|eventlet\|socketio" lib/ ssh-ui.py install.sh` returns nothing.

---

## Phase 2 — Security hardening of the new surface (~1-2 weeks)

**Goal:** every input crossing a trust boundary goes through *one* validator per language. Bash and Python validators are tested against the same golden corpus.

### Tasks (Phase 2)

1. **`bin/_validators.inc.sh` + `lib/ssh_ui/validators.py`.** Paired modules exposing the same function set with identical semantics:
   - `validate_user_host`, `validate_hostname`, `validate_user`, `validate_template_name`, `validate_key_comment`, `validate_comment_text`, `validate_uuid`, `validate_key_type`.
   - Each function: takes a string, returns the string unchanged on success, `err`s (bash) or raises (Python) on failure. No silent transformation.
2. **Golden corpus.** `tests/validators/inputs.tsv` — `<validator>\t<input>\t<expect: accept|reject>` triples covering: nominal input, leading/trailing whitespace, embedded newlines, NUL bytes, shell metacharacters, very long strings, Unicode tricky cases (RTL override, zero-width joiner). Tests in both bash (`bats`) and Python (`unittest`) load the corpus and verify both languages agree.
3. **Route every endpoint through the validators.** Replace the ad-hoc `re.match` / `"".join(c for c in name if ...)` calls in `handlers.py`. Replace the per-script regex sanitisers in the bash CLI with `validate_*` calls.
4. **Structured config emitter for `--comment`** (W2 closed). Write the comment text to `host-uuid/UUID/notice.txt`; the config line becomes `Match host %h exec "cat ~/.ssh/unique_keys/host-uuid/UUID/notice.txt"`. No interpolation of user text.
5. **`hmac.compare_digest` everywhere a token is compared.** Currently `token == AUTH_TOKEN`; replace with constant-time compare. (Minor, but cheap.)
6. **`/deploy` password handling.** Move temp `SSH_ASKPASS` script creation into `$XDG_RUNTIME_DIR` when present (memory-backed on Linux), else into `~/.ssh/unique_keys/tmp` with 0700. `os.O_CREAT | os.O_EXCL | O_NOFOLLOW` to defeat races. Delete in a `finally` block, not after a bare success path.
7. **CSP, X-Content-Type-Options, X-Frame-Options.** Add `nosniff` and `DENY` headers to every response.
8. **WebSocket frame-size bound, per-IP rate limiting on `/ws`, message-rate limit per connection.** Defends against the trivial DoS where a malicious page on the user's machine repeatedly opens WSs to localhost.

### Exit gate (Phase 2)

- One validator per concept; `git grep "re.match\|^.join.*isalnum" lib/ssh_ui/` returns nothing.
- Golden corpus passes in both bash and Python.
- Three injection vectors (a `--comment` payload that escapes, a hostname containing `$(...)`, a template name with `../`) are encoded as regression tests; they fail without the validators and pass with them.

---

## Phase 3 — Formal schema + migrations (~1 week)

**Goal:** the on-disk layout is a versioned, validated artifact. `ssh-doctor` walks the tree and reports anomalies.

### Tasks (Phase 3)

1. **Introduce `$BASE_DIR/SCHEMA`.** Contains the integer `2`. `ensure_base_dirs` writes it on init. (W7 closed.)
2. **Migrate `history.log` → `history.jsonl`.** Phase 1 may temporarily keep both; this phase removes the legacy file. `ssh-history` reads JSONL; one-shot in-place rewrite of any existing v1 log. (W6 closed.)
3. **`bin/ssh-doctor`.** Walks `$BASE_DIR`, checks: perms (0700/0600/0644 as schemed), every symlink target is inside `$BASE_DIR`, every `known_host_keys` parses, every `identity` is either real-file or valid-symlink, no orphan `by-key`/`by-host` symlinks, SCHEMA matches expected. Reports anomalies; exits non-zero on any failure.
4. **CI fixtures.** A `tests/fixtures/` tree representing: clean install, after-provision, after-rotation, after-template-create. `scripts/check fixtures` runs `ssh-doctor` against each.
5. **Resolve W1 (UUID under partial scans).** Three options on the table:
   - **(a)** Refuse to create new identity if the scan returns fewer than N (e.g. 2) keys.
   - **(b)** Switch UUID derivation to `sha256(sorted(all-keys))` (over `<type> <base64>` lines, hostname column stripped — consistent with the Phase 0 task 10 derivation fix). Partial scans cannot collide with a previous full scan; the diff check in `ssh-new` already covers the rest.
   - **(c)** Keep current; document.

   Recommendation: **(b).** Cleanest, no thresholds to tune, no extra UX. Costs: a layout incompatibility — fine, we're pre-1.0. Decide and implement.

### Exit gate (Phase 3)

- `ssh-doctor` runs clean on every fixture tree in CI.
- Existing-install detection: running `ssh-doctor` against a v1 layout prints a clear "schema v1 detected; run `ssh-doctor --migrate` to upgrade or `rm -rf ~/.ssh/unique_keys` and re-provision" message.
- `cat $BASE_DIR/SCHEMA` returns `2` on a freshly installed tree.

---

## Phase 4 — Web UI ↔ CLI seam (~1-2 weeks)

**Goal:** every state mutation goes through a `bin/ssh-*` script with `--json` output. Python is pure orchestration.

### Tasks (Phase 4)

1. **Add `--json` mode to every state-mutating script.** Output an object per significant event to stdout; final line is the result object. Human-readable progress goes to stderr.
2. **Move standard-template key generation from `handlers.py` to `bin/ssh-template generate-keys --json`.** Today the Python `POST /api/templates` for `standard` type invokes `ssh-keygen` directly, bypassing `log_event`. After this, every state mutation passes through bash and lands in `history.jsonl`.
3. **Move `/api/user/delete`'s `shutil.rmtree`** to `bin/ssh-del --force --json`. Same rationale.
4. **Move `/api/deploy`'s direct `ssh-copy-id`** into a new `bin/ssh-deploy` that handles the `SSH_ASKPASS` setup and the post-run cleanup. Python becomes a thin caller. `ssh-deploy` must pin via `UserKnownHostsFile` + `StrictHostKeyChecking=yes` like `ssh-new` (Phase 0 task 9) — this retires the last `accept-new`, currently in `lib/ssh-ui.py`.
5. **Strict WebSocket message validation at handler entry.** Discriminated union on `op`; reject unknown ops; validate every field against the validators from Phase 2.

### Exit gate (Phase 4)

- `git grep "subprocess.run\|subprocess.Popen" lib/ssh_ui/` shows only calls into `bin/ssh-*`.
- `git grep "ssh-keygen\|ssh-keyscan\|ssh-copy-id" lib/ssh_ui/` returns nothing.
- Manually running `ssh-history` after a sequence of UI operations shows entries for every mutation.

---

## Phase 5 — Bash cleanup and rotation rebuild (~1 week)

**Goal:** every bash script is consistent, lint-clean, and tested.

### Tasks (Phase 5)

1. **Rebuild [`ssh-rotate`](bin/ssh-rotate)** from scratch against the current `_ssh-unique-key.inc.sh`. Use the symlink-updating logic from [`ssh-new`](bin/ssh-new) as the template. bats tests for: simple rotation, rotation when `by-key` symlinks include slashes, rotation refusing when keys haven't changed. (W9 closed.)
2. **Rebuild [`ssh-template-rotate`](bin/ssh-template-rotate)** using a new `get_hosts_using_template` helper that walks `host-uuid/*/<user>/identity` symlinks and filters by template name.
3. **Audit every script for `set -e` correctness.** Pipelines, `read` inside `while`, `grep | true`. Verify each script's intended behaviour on partial failures.
4. **Replace `sed -i.bak` patterns with structured config helpers.** `config-set <file> <key> <value>` that reads → parses → writes atomically. Defeats the regex-escape minefield in [`ssh-conf`](bin/ssh-conf).
5. **Convert `cat file | while read l` to `while read l < file`.** Avoids subshell-variable-scoping pitfall.
6. **Make every script honour `--json`.** From Phase 4 we need it on mutating scripts; in this phase finish the read-only ones (`ssh-history`, `ssh-template list`) too, for symmetry.

### Exit gate (Phase 5)

- `shellcheck` clean on every `bin/*` and `install.sh` with no excluded rules.
- `bats` suite (`tests/bash/`) covers: provision, re-provision (idempotence), delete, rotate, template rotate, backup+restore round trip, `--json` output well-formed.

---

## Phase 6 — Threat-model regression tests (~1 week)

**Goal:** every defended threat in [ARCHITECTURE.md §2](ARCHITECTURE.md#2-threat-model) has an automated test that *would* fail if the defence regressed.

### Tasks (Phase 6)

For each defended threat (A–F):

1. **A: per-host uniqueness.** Provision two fixture hosts. Assert that the two `identity.pub` files have distinct contents.
2. **B: no public-key correlation.** Same as A but also assert that no file under `$BASE_DIR/host-uuid/<host1>/` contains text equal to any file under `host-uuid/<host2>/`.
3. **C: MITM on re-engagement.** Provision a fake host (write a `known_host_keys` by hand). Run `ssh-new` against a script that emits *different* keys. Assert non-zero exit and that the original `known_host_keys` is untouched.
4. **D: filesystem permissions.** Walk `$BASE_DIR` after every operation in the bats suite; assert every dir is 0700, every `identity` is 0600, every `*.pub` is 0644.
5. **E: web UI auth.** Start the server, hit `/api/templates` without a cookie — expect 401. With a wrong token — 401. Right token — 200. Open a WebSocket without the cookie — fail handshake.
6. **F: supply chain.** `scripts/check vendor` is already part of the check script; add a test that mutates one byte of a vendored file and asserts `scripts/check vendor` exits non-zero.
7. **W1 regression.** Construct a `known_host_keys` with ed25519+ecdsa+rsa. Simulate a re-scan returning only `rsa`. Assert behaviour matches the Phase 3 decision (e.g. recompute-from-sorted-all-keys still matches → identity preserved).

### Exit gate (Phase 6)

- All threat tests pass in CI on every commit.
- A failure of any of them blocks merge.

---

## Sequencing summary

| Phase | Focus | Approx duration | Blocks |
| ----- | ----- | --------------- | ------ |
| 0 | Stop the bleeding, vendor JS, local check | 1 wk | everything |
| 1 | Drop Flask: stdlib rewrite + module split | 2 wk | Phase 2+ |
| 2 | Security hardening + paired validators | 1-2 wk | Phase 4 |
| 3 | Formal schema + ssh-doctor | 1 wk | Phase 4, 5 |
| 4 | UI/CLI seam (`--json` everywhere) | 1-2 wk | Phase 5 (loosely) |
| 5 | Bash cleanup + rotation rebuild | 1 wk | Phase 6 |
| 6 | Threat-model regression tests | 1 wk | — |

Total: ~8-9 weeks of focused work. Phase 3 and Phase 4 can overlap partially; Phase 5 can begin once Phase 4 has landed `--json` on the scripts it touches.

---

## What this plan does *not* address

Deliberate scope cuts; revisit post-1.0:

- **Multi-machine sync.** Sharing `unique_keys/` across machines. Workaround today: `ssh-backup` to encrypted store on Syncthing / iCloud / etc.
- **TOFU bypass on first scan.** (X2.) Pinning the very first scan to an out-of-band-verified key would require user workflow change.
- **Same-user code reading the store** (X1). Out of scope as a deliberate platform gate; if it matters, the answers are platform isolation or hardware-bound keys via `ssh-keygen-sk` templates. See ARCHITECTURE.md §2 for the rationale.
- **Agent forwarding policies.** Per-host config can do this via `ssh-conf` + `ForwardAgent`.
- **Non-OpenSSH clients.** PuTTY, mosh, etc.
- **Windows support.** The PTY path uses `pty.fork()` which is Unix-only.
- **Remote (non-localhost) web UI.** Would require TLS, real auth, CSRF tokens.
