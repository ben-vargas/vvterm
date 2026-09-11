#!/bin/bash
# Emit terminal events in the pane where this script runs. No server settings change.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./scripts/test_terminal_events.sh [all|progress|notify|clear|environment] [--tmux-depth N] [--delay SECONDS]

Run inside a VVTerm terminal, or copy this script to the remote host.
Default: all, direct output, two seconds between progress states.
For one tmux layer use --tmux-depth 1; for two layers use 2 (maximum 4).
Each tmux layer must allow passthrough. This script does not change its settings.

progress     Half-full bar, paused orange, error red, moving bar, full bar, remove.
notify       OSC 9 and OSC 777 notifications (enable permission in VVTerm settings).
clear        Remove the current pane's progress bar.
environment  Print only terminal capability variables.

Repeat in each split pane to check isolation. Switch tabs during progress.
SSH/ET should deliver events. Mosh currently cannot deliver these OSC events.
A quiet progress bar expires after 15 seconds. Notification delivery requires
VVTerm to receive the bytes; iOS suspension can delay it.
EOF
}
mode=all
depth=0
delay=2
while [ "$#" -gt 0 ]; do
    case "$1" in
        all|progress|notify|clear|environment) mode=$1; shift ;;
        --tmux-depth|--delay)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            if [ "$1" = --tmux-depth ]; then depth=$2; else delay=$2; fi
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
case "$depth" in 0|1|2|3|4) ;; *) echo 'Depth must be 0...4.' >&2; exit 2 ;; esac
case "$delay" in 0|1|2|3|4|5|10|15|16) ;; *) echo 'Delay must be 0...5, 10, 15, or 16 seconds.' >&2; exit 2 ;; esac
esc=$'\033'
emit() {
    local payload="${esc}]$1${esc}\\" level=0
    while [ "$level" -lt "$depth" ]; do
        payload="${esc}Ptmux;${payload//${esc}/${esc}${esc}}${esc}\\"
        level=$((level + 1))
    done
    printf '%s' "$payload"
}
clear_progress() { emit '9;4;0'; }
progress() {
    trap clear_progress EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    local state
    for state in '1;50' '4;50' '2;50' '3' '1;100'; do
        printf 'OSC progress: %s\n' "$state"
        emit "9;4;$state"
        sleep "$delay"
    done
    clear_progress
    trap - EXIT INT TERM
    printf 'Progress removed.\n'
}
notify() {
    emit '9;VVTerm OSC 9 test'
    sleep "$delay"
    emit '777;notify;VVTerm OSC 777 test;This message came from this terminal pane.'
    printf 'Two notification events sent.\n'
}
environment() {
    printf 'TERM=%s\nCOLORTERM=%s\nTERM_PROGRAM=%s\nTERM_PROGRAM_VERSION=%s\nSNACKS_SSH=%s\n' \
        "${TERM-<unset>}" "${COLORTERM-<unset>}" "${TERM_PROGRAM-<unset>}" \
        "${TERM_PROGRAM_VERSION-<unset>}" "${SNACKS_SSH-<unset>}"
}
case "$mode" in
    all) environment; progress; notify ;;
    progress) progress ;;
    notify) notify ;;
    clear) clear_progress ;;
    environment) environment ;;
esac
