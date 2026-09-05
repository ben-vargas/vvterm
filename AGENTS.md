# VVTerm

iOS/macOS SSH terminal with iCloud sync and Keychain credential storage.
Support iOS 16.1+ and macOS 13.3+, arm64, with Xcode 16.0+.

## Scope and Completion

- Inspect current code, repository state, and relevant logs before choosing a fix.
- Review, diagnosis, and report requests are read-only unless the user also asks for changes.
- Choose the simplest design that meets the requested behavior and repository rules. Compare alternatives when they materially affect correctness, ownership, performance, or maintenance. Report material trade-offs.
- Fix the cause of a defect, not only its visible symptom. Do not hide failures with silent fallback paths.
- Keep unrelated findings separate. Do not add features, redesign screens, or broaden a refactor without authority.
- Before editing, identify the required behavior and relevant checks. After reviewing the diff and passing those checks, finish unless a specific unresolved risk needs more work. Repeat checks only after relevant changes, failures, or new evidence.
- Ask when a missing choice materially changes the result or needs new authority. Otherwise, proceed with a reasonable, reversible assumption.
- Commit, merge, push, open a PR, install on a device, or publish only when the user authorizes that action. A skill does not grant this authority.
- Preserve unrelated work. When committing, use atomic commits with one coherent intent each and verify the staged diff.
- Keep updates short. Report the result, exact checks, and remaining risks; distinguish passed, failed, skipped, and unavailable checks.

## Read the Relevant Instructions

Read scoped `AGENTS.md` files along the paths you will change, including when starting from the repository root. For tests, also read the production owner's rules. Root rules remain in force.

- [App](VVTerm/App/AGENTS.md): composition and app lifecycle.
- [Core](VVTerm/Core/AGENTS.md): shared infrastructure and links to its specific owners.
- [Features](VVTerm/Features/AGENTS.md): feature ownership and links to feature-specific rules.
- [Unit and integration tests](VVTermTests/AGENTS.md), [UI tests](VVTermUITests/AGENTS.md): test source organization.
- For any Apple UI change, also read [UI and platform rules](VVTerm/Core/UI/AGENTS.md).
- For remote startup, shell, or multiplexer changes in any feature, also read [SSH rules](VVTerm/Core/SSH/AGENTS.md).

Workflow skills, read only when relevant:

- [Device installation](.agents/skills/vvterm-device-install/SKILL.md): build and deliver to a physical iOS device through CLI.
- [ASC release work](.agents/skills/vvterm-asc-release/SKILL.md): inspect builds, prepare release notes, and perform authorized distribution through ASC CLI.

See [README.md](README.md) for the source layout, dependencies, and build setup. Use current source types and StoreKit/ASC data rather than copied model definitions, limits, or prices.

## Architecture

- `App` owns app entry, composition, root containers, localization preferences, and platform app shells.
- `Core` owns neutral shared infrastructure. It must not depend on feature models or policies.
- `Features/<FeatureName>` owns its product behavior. Do not reintroduce app-wide bucket folders.
- `Domain` holds pure types and rules; `Application` holds authoritative state and workflows; `Infrastructure` holds transport, persistence, and adapters; `UI` renders state and forwards intents.
- Map feature models at infrastructure boundaries. UI must not own transport, persistence, path policy, shell syntax, or long-lived workflows.
- Inject production dependencies from app or feature roots. Leaf types must not create them through `.shared`, default live arguments, or hidden service locators.
- Keep preview and test compositions free of live CloudKit, Keychain, network, StoreKit, and other external work unless a test explicitly targets that boundary.

## State and Type Ownership

- Store only facts that cannot be derived safely from authoritative state. Model closed workflow and presentation states with enums rather than independent flags, revision counters, or closure payloads.
- The owner that starts a task also owns replacement, cancellation, stale-result rejection, and teardown.
- Check sizes, offsets, capacities, indices, and arithmetic for overflow and valid bounds.
- Use existing project patterns before adding a new abstraction. Each new concept must have a clear need.
- `Store`: authoritative observable state. `Coordinator`: an asynchronous workflow or lifecycle.
- `Client`: external-system boundary. `Repository`: persistence boundary. `Policy`: pure deterministic rule.
- `Projection`: narrow read-only observable state derived from an owner. `Runtime`: native resource lifecycle. `Composition`: dependency assembly.
- Keep `ObservableObject` for the supported OS versions. Do not start a whole-app Observation migration.
- Rename an ambiguous `Manager` only when its implementation already changes; avoid naming-only migrations.
- Prefer one stable dispatcher with typed command IDs for app and toolbar commands.

## Source Structure and Refactoring

- Prefer one primary type per file, with a matching filename.
- For one lifecycle owner with several capabilities, keep state, initialization, and lifecycle in `Type.swift`; use `Type+Capability.swift` for cohesive capabilities.
- Extract a separate type when it owns independent state or lifecycle. Do not use extensions to hide separate owners.
- Order files as inputs and owned state, initialization, public intents, then private helpers. Keep view-owned state private. Comments explain reasons and invariants.
- Review ownership above 600 lines; a file above 1,000 lines needs a clear reason. File size alone does not justify behavior changes.
- Preserve screens, entry points, interactions, visual behavior, and platform parity during refactors. Keep necessary correctness changes minimal and isolated.
- Do not add whole-app rewrites, generic reducer frameworks, unnecessary packages, mass renames, or a second dependency graph.
- Use direct cutovers. Do not add migration code for unreleased drafts or compatibility service locators. Preserve behavior required by supported OS versions, released data, and remote protocols.

## Testing and Regression Policy

- Every bug or regression fix needs automated coverage unless it is genuinely not automatable. Explain the blocker and manual validation when coverage is not added.
- Write or update a deterministic failing regression test first when feasible.
- Use unit tests for rules, parsers, state machines, focus policies, coordinators, and models; XCUITest for UI lifecycle, keyboard, navigation, accessibility, focus, and sheets; integration tests for SSH/session/rendering boundaries that can run locally or in simulator.
- Refactors must preserve passing tests. Add coverage before simplifying risky or untested behavior.
- Keyboard and terminal input changes require focused regression coverage: relevant policy/model unit tests and user-visible iOS XCUITest when keyboard, accessories, IME/preedit, backspace repeat, find UI, floating controls, focus, or tab/view switching is touched. Phone testing alone is not enough.
- Before finishing code changes, run the narrowest reliable build/test commands for the touched behavior. Report exact commands and any unavailable checks as residual risks.
- After platform UI splits, validate both iOS and macOS builds. Documentation-only changes need document and configuration checks, not app test runs.

## Build Storage

- Use Xcode's default Derived Data. Do not pass `-derivedDataPath` or put Derived Data in the repository, `.build`, `/tmp`, or `/private/tmp`.
- Reuse caches and run builds serially. Avoid redundant clean or full builds.
- Check disk space before large builds. Ask before using an isolated path.
- Reuse vendor binaries unless rebuilding them is part of the task. Build setup and vendor commands are in [README.md](README.md#building-from-source).

## Planning and Repository Documentation

- Keep product ideas, future specifications, roadmap, pricing strategy, and internal rollout plans in the VVTerm Linear project, not this repository.
- Search Linear before creating work. Reuse the issue that owns the scope. Create an issue before a large implementation and keep its decisions, criteria, and status current.
- Keep repo documentation limited to current architecture, build, test, security, contribution, protocol, and intentionally public user contracts. Enforce completed behavior through tests instead of retaining old implementation plans.
- Keep credentials, tokens, private keys, customer data, and production secrets out of the repository and Linear. Keep personal information out of agent instructions and skills. Resolve device, account, and build identifiers at run time.
- When adding instructions inside an Xcode synchronized source folder, exclude them from target membership so they do not enter app or test bundles.
