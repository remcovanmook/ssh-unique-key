#!/bin/bash
# Stage: vendor — every file in lib/ui/vendor/ matches its recorded SHA-384.
# Fails on: hash mismatch, file listed but missing, js/css file present but
# not listed in SHA384SUMS.
set -u
VENDOR_DIR="$REPO_ROOT/lib/ui/vendor"
SUMS="$VENDOR_DIR/SHA384SUMS"

[ -d "$VENDOR_DIR" ] || { echo "  missing $VENDOR_DIR" >&2; exit 1; }
[ -f "$SUMS" ] || { echo "  missing $SUMS" >&2; exit 1; }

cd "$VENDOR_DIR"

if command -v shasum >/dev/null; then
    shasum -a 384 -c SHA384SUMS || exit 1
else
    sha384sum -c SHA384SUMS || exit 1
fi

rc=0
for f in *.js *.css; do
    [ -e "$f" ] || continue
    if ! grep -q "  $f\$" SHA384SUMS; then
        echo "  $f present in vendor/ but not recorded in SHA384SUMS" >&2
        rc=1
    fi
done

exit "$rc"
