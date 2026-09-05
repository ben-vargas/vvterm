# Unit and Integration Tests

- Read the production owner's scoped rules before changing its tests.
- Mirror the production owner under `App`, `Core`, or `Features/<FeatureName>`; do not add unrelated tests at this root.
- Use Domain/Application/Infrastructure/UI subfolders in dense features when they identify real owners. Keep small single-owner folders flat.
- Place tests that cross owners and need external services in `Integration/<Boundary>`. Keep prerequisites and skip conditions explicit.
- Keep support beside its owner; top-level Support is only for real cross-feature use. Avoid generic Utils, Common, or broad Mocks folders.
- Name unit files `TypeTests.swift` and cross-boundary files `FlowIntegrationTests.swift`.
- Split suites by independent behavior or ownership, not extensions created only to reduce line count.
- Preserve serialized execution, actor isolation, reset hooks, environment gates, and test identifiers during moves. Compare the meaningful test inventory before and after a large test refactor.
- Do not combine test moves with a test-framework migration, new product behavior, or unrelated coverage work.
