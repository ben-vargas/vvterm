# Shared Terminal Support

- Own shared clipboard, paste, text/default helpers, and the libghostty bridge here.
- Session/tab state, runtime surfaces, and platform terminal screens belong in `Features/TerminalSessions`.
- VVTerm uses libghostty with Metal rendering. Keep changes in the owner of the defect; do not hide bridge or runtime defects in UI behavior.
- Read the root keyboard/input test policy for any terminal input change.
