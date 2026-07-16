#!/bin/bash
# Regression test for REFACTOR.md Phase 0 task 6: ssh-new's usage text and
# arg parser each mention --comment exactly once (the parser previously
# carried duplicated usage lines, variable inits, and case arms).
set -u
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
SSH_NEW="$REPO_ROOT/bin/ssh-new"

rc=0

usage_mentions=$("$SSH_NEW" --help 2>&1 | grep -c -- "--comment \"text\"    Display")
if [ "$usage_mentions" -ne 1 ]; then
    echo "  expected exactly 1 --comment usage line, got $usage_mentions" >&2
    rc=1
fi

case_arms=$(grep -c -- '--comment) COMMENT_TEXT=' "$SSH_NEW")
if [ "$case_arms" -ne 1 ]; then
    echo "  expected exactly 1 --comment case arm in ssh-new, got $case_arms" >&2
    rc=1
fi

exit "$rc"
