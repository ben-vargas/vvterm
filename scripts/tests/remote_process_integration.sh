#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHON="$ROOT/.build/remote-process-tests/bin/python"
if [[ ! -x "$PYTHON" ]]; then
    echo 'Create .build/remote-process-tests with python3 -m venv, then install paramiko==4.0.0 there.' >&2
    exit 1
fi
RUN_DIR="$(mktemp -d)"
FIXTURE_PID=""
cleanup() {
    if [[ -n "$FIXTURE_PID" ]]; then
        kill "$FIXTURE_PID" 2>/dev/null || true
        wait "$FIXTURE_PID" 2>/dev/null || true
    fi
    rm -rf "$RUN_DIR"
}
trap cleanup EXIT
"$PYTHON" "$ROOT/scripts/tests/remote_process_fixture.py" --ready "$RUN_DIR/fixture.json" > "$RUN_DIR/server.log" 2>&1 &
FIXTURE_PID=$!
for attempt in {1..100}; do
    [[ -s "$RUN_DIR/fixture.json" ]] && break
    kill -0 "$FIXTURE_PID" 2>/dev/null || { cat "$RUN_DIR/server.log" >&2; exit 1; }
    sleep 0.1
done
[[ -s "$RUN_DIR/fixture.json" ]] || { echo 'SSH fixture did not start.' >&2; exit 1; }
cd "$ROOT"
TEST_RUNNER_VVTERM_REMOTE_PROCESS_FIXTURE="$RUN_DIR/fixture.json" \
    xcodebuild -project VVTerm.xcodeproj -scheme VVTerm \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:VVTermTests/RemoteProcessRendererTests \
    -only-testing:VVTermTests/RemoteProcessOutputBufferTests \
    -only-testing:VVTermTests/RemoteProcessFlowIntegrationTests \
    -only-testing:VVTermTests/DockerStatsCollectorParserTests test
