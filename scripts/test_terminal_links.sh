#!/bin/bash
# Run on the host whose terminal output VVTerm displays.
set -euo pipefail

case "${1-}" in
    -h|--help)
        cat <<'EOF'
Usage: ./scripts/test_terminal_links.sh

Run inside VVTerm, or copy this script to the remote host and run it there.
Start outside tmux to check direct delivery of OSC 8 links.
Tap links on iOS; Command-click on macOS. Confirm the displayed destination.
Keep this script running while testing file links. Enter or Ctrl-C removes
its temporary files. No browser, email app, or network request starts here.
EOF
        exit 0 ;;
    '') [ "$#" -eq 0 ] || { echo 'Use --help for usage.' >&2; exit 2; } ;;
    *) echo 'Use --help for usage.' >&2; exit 2 ;;
esac

fixture=$(mktemp -d /tmp/vvterm-links.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'VVTerm link test: plain file.\n' > "$fixture/plain.txt"
printf 'VVTerm link test: filename with spaces.\n' > "$fixture/with spaces.txt"

link() {
    # OSC 8 with ST terminators. Always close the link before the next row.
    printf '\033]8;;%s\033\\%s\033]8;;\033\\\n' "$1" "$2"
}

cat <<'EOF'
VVTerm link checks
Tap on iOS; Command-click on macOS. Check Cancel and Open separately.
Web examples test the destination; paths may return a web error page.

Plain URLs: each should show an Open Link confirmation.
  https://example.com
  http://example.com
  https://example.com/search?q=hello%20world&lang=en#results
  https://example.com/path%20with%20spaces
  (https://example.com) -- the closing parenthesis is not part of the URL.

OSC 8: the confirmation must show the target, not just the visible label.
EOF
link 'https://example.com/actual' '  Friendly label -> https://example.com/actual'
link 'https://example.com/actual' '  https://example.org/displayed (different target)'
printf '\033]8;;https://example.com/bel\007  BEL-terminated link\033]8;;\007\n'
link 'mailto:terminal-test@example.com?subject=VVTerm%20link%20test' '  Email draft (do not send): terminal-test@example.com'

printf '\nFile links: confirm opening Files on the current server.\n'
printf '  Plain file URL: file://%s/plain.txt\n' "$fixture"
link "file://$fixture/plain.txt" '  Existing text file -> plain.txt'
link "file://$fixture/with%20spaces.txt" '  Existing file with spaces -> with spaces.txt'
link "file://$fixture/" '  Existing directory -> test folder'
link "file://$fixture/missing.txt" '  Missing file -> expect a Files error after confirmation'

printf '\nRejected targets: these must not open a destination or confirmation.\n'
link 'javascript:void(0)' '  Unsupported javascript scheme'
link 'ssh://example.com' '  Unsupported ssh scheme'
link 'https:///missing-host' '  HTTPS without a host'
link 'file:///tmp/example.txt?unexpected=query' '  File URL with a query'

cat <<'EOF'

Selection sample: alpha bravo charlie. Select, extend, and copy this sentence.
Repeat link and selection checks in Direct and Chat input modes, with the
keyboard shown and hidden. Compare the results between modes.
Remote mouse capture currently disables link activation.

Return here after testing file links. Press Enter to remove the test files.
EOF
IFS= read -r _ || true
