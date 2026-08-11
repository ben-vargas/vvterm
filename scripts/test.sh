#!/bin/bash

set -euo pipefail

suite="${1:-unit}"
if (( $# > 0 )); then
  shift
fi
destination="${VVTERM_TEST_DESTINATION:-platform=macOS,arch=arm64}"
project="VVTerm.xcodeproj"

run_tests() {
  xcodebuild test -quiet \
    -project "$project" \
    -destination "$destination" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    "$@"
}

case "$suite" in
  unit)
    run_tests -scheme VVTermUnitTests "$@"
    ;;
  integration)
    run_tests \
      -scheme VVTerm \
      -only-testing:VVTermTests/SSHStartupIntegrationTests \
      -only-testing:VVTermTests/SSHAddressConnectorIntegrationTests \
      -only-testing:VVTermTests/RemoteTmuxManagerLocalIntegrationTests \
      "$@"
    ;;
  performance)
    run_tests \
      -scheme VVTerm \
      -only-testing:VVTermTests/SSHSocketReadinessPollerTests/manySessionBenchmarkReportsBeforeAndAfterMedianAndTail \
      "$@"
    ;;
  ui)
    run_tests -scheme VVTerm -only-testing:VVTermUITests "$@"
    ;;
  *)
    echo "Usage: scripts/test.sh {unit|integration|performance|ui}" >&2
    exit 64
    ;;
esac
