---
name: vvterm-asc-release
description: Inspect VVTerm builds and prepare or distribute App Store and TestFlight releases through ASC CLI when requested. Not for device installation, pricing changes, or unrelated account administration.
---

# VVTerm ASC Release Work

Use `asc` throughout. Perform only the requested parts of this workflow. Checking a build does not authorize metadata edits, tester distribution, review submission, or public release.

## Resolve the Target

- Inspect `asc --help` and the relevant subcommand help; flags can change. Use `asc search` when the command is unclear. Do not run setup commands that install skills or rewrite repo configuration.
- Check authentication without printing secrets. If access is missing, request the required sign-in; do not change account or team configuration.
- Resolve the app from its current bundle identifier. Query the requested platform, marketing version, build number, and source commit or Xcode Cloud run when available. Do not substitute an unrelated latest build.
- Keep resolved app, version, build, and group IDs in task context, not repository files. If the exact target is ambiguous, stop before changes and ask.

## Wait for the Exact Build

- Use `asc builds info --build-id BUILD_ID` to inspect state. For requested monitoring, use `asc builds wait --build-id BUILD_ID --fail-on-invalid` with an explicit timeout, running it in a way that permits progress updates and user interruption.
- Confirm the build is valid, not expired, and matches the requested app, platform, and version before using it.
- Processing can take time. Do not upload again or switch builds because it is slow. Report failed/invalid states. If the wait limit is reached, report the current state; continue monitoring only within the requested scope.

## Apply Authorized Changes

- Recheck the target and the requested action before each write. Reuse existing versions, localizations, and group assignments rather than creating duplicates.
- Attach the exact build with `asc versions attach-build --version-id VERSION_ID --build-id BUILD_ID` only when requested. Check the destination's existing build first; do not replace a different build without authority.
- Keep App Store What's New separate from TestFlight What to Test. Use `asc localizations` for version metadata and `asc builds test-notes` for build test notes. Preserve exact text and locale scope supplied by the user. If drafting is requested, use verified changes since the previous release; exclude internal, personal, and secret information.
- For tester distribution, list all pages of `asc testflight groups list` and the existing `asc builds groups list` assignments. Add only missing requested groups with `asc builds add-groups`. If all groups were requested, include all compatible internal and external groups and report exclusions with reasons.
- A group assignment is not proof of tester access. Check beta-review and distribution state. Submit for beta review only when authorized by the requested distribution workflow; if new declarations or decisions are needed, ask instead of guessing.
- Do not notify testers, change release scheduling, submit for App Store review, or release publicly unless that action is authorized. TestFlight distribution does not authorize a public App Store release.

## Verify and Finish

- Read back the version's attached build, each edited localization, requested group assignments, and distribution/review state.
- If a write times out, inspect live state before retrying; it may already have completed. Retry only missing work.
- Report exact version/build, completed actions, and any waiting or blocked states. Stop once requested changes are verified. Do not add pricing, listing, or account cleanup work.
