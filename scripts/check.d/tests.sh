#!/bin/bash
# Stage: tests — plain-bash tests always run; bats and python suites run
# when present (bats is optional tooling).
set -u
cd "$REPO_ROOT"

rc=0
ran=0

# Plain-bash tests: tests/bash/test_*.sh, each exits 0/non-0.
for t in tests/bash/test_*.sh; do
    [ -e "$t" ] || continue
    ran=1
    if bash "$t"; then
        echo "  ok  $t"
    else
        echo "  FAIL $t" >&2
        rc=1
    fi
done

# bats suite (Phase 5 grows this).
if ls tests/bash/*.bats >/dev/null 2>&1; then
    if command -v bats >/dev/null; then
        ran=1
        bats tests/bash/*.bats || rc=1
    else
        echo "[SKIP] tool 'bats' not installed"
    fi
fi

# Python suite (Phase 1+).
if [ -d tests/python ]; then
    ran=1
    python3 -m unittest discover -s tests/python -v || rc=1
fi

[ "$ran" -eq 0 ] && echo "  (no tests found)"
exit "$rc"
