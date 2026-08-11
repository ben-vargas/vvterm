#!/bin/bash

set -euo pipefail

base_revision="${1:?Usage: scripts/validate_pr_changelog.sh BASE_REVISION}"
internal_marker="- [x] Internal-only; no changelog entry."

if git diff --name-only "${base_revision}...HEAD" | grep -Fxq "CHANGELOG.md"; then
  echo "Pull request has a changelog change"
  exit 0
fi

if grep -Fiq -- "$internal_marker" <<< "${VVTERM_PR_BODY:-}"; then
  echo "Pull request is classified as internal-only"
  exit 0
fi

echo "Add a CHANGELOG.md entry or check the internal-only PR declaration." >&2
exit 1
