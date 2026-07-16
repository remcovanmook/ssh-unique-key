#!/bin/bash
# Stage: lint — shellcheck on shell scripts, ruff on Python. Both optional.
#
# Phase 0 severity: shellcheck -S error, ruff limited to the runtime-error
# subset (E9/F63/F7/F82). Phase 5 tightens to full default severity with no
# exclusions (REFACTOR.md Phase 5 exit gate).
set -u
cd "$REPO_ROOT"

rc=0

if command -v shellcheck >/dev/null; then
    while IFS= read -r f; do
        head -1 "$f" | grep -q '^#!.*bash' || continue
        if ! shellcheck -S error "$f"; then
            rc=1
        fi
    done < <(git ls-files 'bin/*' 'install.sh' 'scripts/*' 'scripts/check.d/*' 'tests/bash/*.sh')
    # The sourced include has no shebang; lint it explicitly as bash.
    if ! shellcheck -S error -s bash bin/_ssh-unique-key.inc.sh; then
        rc=1
    fi
else
    echo "[SKIP] tool 'shellcheck' not installed"
fi

if command -v ruff >/dev/null; then
    if ! ruff check --select E9,F63,F7,F82 lib; then
        rc=1
    fi
else
    echo "[SKIP] tool 'ruff' not installed"
fi

exit "$rc"
