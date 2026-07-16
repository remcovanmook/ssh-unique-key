#!/bin/bash
# Stage: syntax — bash -n every shell script, py_compile every Python file.
set -u
cd "$REPO_ROOT"

rc=0

while IFS= read -r f; do
    if ! bash -n "$f"; then
        echo "  bash -n failed: $f" >&2
        rc=1
    fi
done < <(git ls-files 'bin/*' 'install.sh' 'scripts/*' 'scripts/check.d/*' 'tests/bash/*.sh' \
         | while IFS= read -r f; do
               # Shell files: everything in bin/ and scripts/ except known non-shell
               case "$f" in
                   *.py|*.md|*.yml|*.json|*.bats) ;;
                   *) head -1 "$f" | grep -q '^#!.*bash\|^#!/bin/sh' && echo "$f" ;;
               esac
           done)

while IFS= read -r f; do
    if ! python3 -m py_compile "$f"; then
        echo "  py_compile failed: $f" >&2
        rc=1
    fi
done < <(git ls-files '*.py')

exit "$rc"
