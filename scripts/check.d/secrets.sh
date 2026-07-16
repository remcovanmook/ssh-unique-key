#!/bin/bash
# Stage: secrets — grep tracked files for accidentally committed credentials.
# Scans only git-tracked files; vendored JS is included on purpose.
set -u
cd "$REPO_ROOT"

rc=0

# Pattern set: private key blocks and well-known token prefixes.
PATTERNS=(
    'BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY'
    'AKIA[0-9A-Z]{16}'
    'ghp_[A-Za-z0-9]{36}'
    'github_pat_[A-Za-z0-9_]{22,}'
    'xox[baprs]-[A-Za-z0-9-]{10,}'
    'sk-[A-Za-z0-9]{32,}'
)

for p in "${PATTERNS[@]}"; do
    # grep -I skips binary files; exit 0 from grep means a hit.
    if git ls-files -z | xargs -0 grep -I -l -E "$p" 2>/dev/null; then
        echo "  possible secret matching /$p/ in the files above" >&2
        rc=1
    fi
done

exit "$rc"
