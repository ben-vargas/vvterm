#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
python3 scripts/check_localizations.py
localization_test_dir="$(mktemp -d)"
trap 'rm -rf "$localization_test_dir"' EXIT
swiftc VVTermShared/LocalizedFormat.swift scripts/tests/localized_format_test.swift -o "$localization_test_dir/localized-format-test"
"$localization_test_dir/localized-format-test"
